defmodule SwarmCode.Domain.Research.Program do
  @moduledoc """
  The step pipeline of one deep research (spec 24 §3.2).

  Plain sequential Elixir, run inside a Task so the `Research.Server` never
  blocks on `await_agent/2`. Each round's lead reads every note gathered so far
  and plans against the gaps, which is what makes the rounds compound; the
  reporter then writes `result.md` itself.
  """

  alias SwarmCode.Domain.Conversations
  alias SwarmCode.Domain.Engine.RunServer
  alias SwarmCode.Domain.Research
  alias SwarmCode.Domain.Research.{HtmlRender, Levels, Prompts}
  alias SwarmCode.Domain.Skills

  require Logger

  @type ctx :: map()

  # A worker whose searches keep failing would otherwise think its way to
  # `max_agent_turns` (60 by default) — on ultra, forty times over. These caps
  # are the blast radius of a misconfigured search provider.
  @turns %{lead: 12, worker: 24, reporter: 8, html: 10, headline: 2}

  # Spec 47 §2: the Fastest pipeline's caps. A plan is one structured call; a
  # worker is search, search, fetch, fetch, answer; a reporter is one answer.
  # A turn here is one LLM call, so these are what keeps a fast round fast.
  @fast_turns %{lead: 2, worker: 6, reporter: 2}

  # Spec 47 §2.1: the Fastest clock, per tier. 45 + 90 + 120 ≈ 4.3 minutes worst
  # case, against the 600 s (reporters 1 200 s) every other level runs on.
  @fast_timeouts %{lead: 45_000, worker: 90_000, reporter: 120_000}

  # The one agent that has to emit a 40 000-character `write_file` call in a
  # single turn. Every other agent keeps `LLM.Request`'s 8 192 (spec 26 §5.3).
  @html_max_tokens 32_000

  # A report.html smaller than this is a truncated write, not a report: the
  # button stays hidden rather than opening a broken page (spec 25 §2.1).
  @min_report_bytes 2_000

  @doc "The per-tier turn caps, so a test can assert they stay under the global one."
  @spec turn_caps() :: %{lead: pos_integer(), worker: pos_integer(), reporter: pos_integer()}
  def turn_caps, do: @turns

  @doc "The Fastest turn caps (spec 47 §2)."
  @spec fast_turn_caps() :: %{lead: pos_integer(), worker: pos_integer(), reporter: pos_integer()}
  def fast_turn_caps, do: @fast_turns

  @doc "The Fastest per-tier wall clock in milliseconds (spec 47 §2.1)."
  @spec fast_timeouts() :: %{lead: pos_integer(), worker: pos_integer(), reporter: pos_integer()}
  def fast_timeouts, do: @fast_timeouts

  # Spec 47 §2: every branch of the fast pipeline asks the level, never the
  # string — a second fast level would only have to set `fast?: true`.
  defp fast?(ctx), do: Levels.fast?(ctx[:level])

  @doc """
  Runs every round and the report. Raises nothing: the Server reads the result.

  Spec 48 §3/§4: a round hands two things forward. The headline agent it started
  is settled while the *next* round is already planning, and any worker it left
  running is harvested before every later plan and awaited before the report —
  so no note is ever lost, only its place in the immediately next plan.
  """
  @spec run(ctx()) :: {:ok, map()} | {:error, String.t()}
  def run(ctx) do
    start = %{notes: [], headline: nil, stragglers: []}
    state = Enum.reduce(1..ctx.steps_total, start, &round(ctx, &1, &2))

    # The last round's stragglers are awaited here: the reporter reads every
    # note the research produced, whatever the schedule did with them.
    state = drain(ctx, state)

    if state.notes == [] do
      settle_headline(ctx, state.headline)
      {:error, "no research agent came back with anything"}
    else
      # The last round's headline runs beside the reporter and lands after it.
      result = report(ctx, state.notes)
      settle_headline(ctx, state.headline)
      result
    end
  end

  # ------------------------------------------------------------------ a round

  defp round(ctx, index, state) do
    Research.update_id(ctx.id, %{step: index})

    case plan(ctx, index, state.notes) do
      nil ->
        Research.upsert_step(ctx.id, index, %{
          status: "failed",
          title: "Round #{index}",
          started_at: now(),
          finished_at: now()
        })

        state

      {plan, lead_id} ->
        tasks = tasks(plan, ctx.fanout)

        Research.upsert_step(ctx.id, index, %{
          title: plan["step_title"] || "Round #{index}",
          tasks: tasks,
          status: "running",
          started_at: now()
        })

        # Pass 64: the planner names the research (3-6 words) so the list never
        # shows the question as the title; the reporter's H1 stays the report's.
        if index == 1 do
          attrs =
            %{}
            |> then(fn a ->
              if is_binary(plan["interpretation"]),
                do: Map.put(a, :interpretation, plan["interpretation"]),
                else: a
            end)
            |> then(fn a ->
              case Research.short_title(plan["title"]) do
                nil -> a
                title -> Map.put(a, :title, title)
              end
            end)

          if attrs != %{}, do: Research.update_id(ctx.id, attrs)
        end

        {notes, stragglers} = work(ctx, index, lead_id, tasks)

        # Spec 51 §5.15: every note was appended as it landed; the close
        # writes the notes again only when the order or the set differs.
        stored = Research.step(ctx.id, index)
        stored_positions = if stored, do: Enum.map(stored.notes || [], & &1["pos"]), else: []

        close =
          %{status: if(notes == [], do: "failed", else: "done"), finished_at: now()}
          |> then(fn attrs ->
            if stored_positions == Enum.map(notes, & &1["pos"]),
              do: attrs,
              else: Map.put(attrs, :notes, notes)
          end)

        Research.upsert_step(ctx.id, index, close)

        # Spec 48 §3: the previous round's ten words are collected now — they
        # were written while this round planned and worked — and this round's
        # headline agent starts, to be collected the same way.
        settle_headline(ctx, state.headline)

        # Spec 48 §4: a straggler that landed while this round ran compounds
        # into every later plan.
        %{
          harvest(ctx, %{state | stragglers: state.stragglers ++ stragglers})
          | headline: start_headline(ctx, index, notes)
        }
        |> Map.update!(:notes, &(&1 ++ notes))
    end
  end

  # Spec 26 §4.1: one small agent turns the round's notes into ten words. It is
  # wrapped in every direction — no notes, a failed call, a model that answers
  # with a paragraph — because a missing headline costs the round nothing and a
  # crashing one would cost it everything.
  #
  # Spec 48 §3: it no longer runs *in front of* the next round. The agent starts
  # when the round's notes are in and the ten words are written into the step row
  # when they arrive — by then the next round is already planning, or the
  # reporter is already writing.
  defp start_headline(_ctx, _index, []), do: nil

  # Spec 39 §2.3: the toggle in Settings, read from the snapshot taken at boot.
  defp start_headline(%{settings: %{research_headlines: false}}, _index, _notes), do: nil

  # Spec 47 §2.4: a Fastest round has no headline agent, whatever Settings say,
  # and `Levels.agents/2` has already stopped promising it.
  defp start_headline(ctx, index, notes) do
    if fast?(ctx) do
      nil
    else
      {index,
       Task.Supervisor.async_nolink(SwarmCode.Domain.TaskSupervisor, fn ->
         do_headline(ctx, index, notes)
       end)}
    end
  end

  # How long the program waits for a headline that should already be finished:
  # the agent runs on its own `timeout_ms(ctx, :lead)` clock, this is only the
  # grace after the phase it was hiding behind.
  @headline_grace_ms 30_000

  defp settle_headline(_ctx, nil), do: nil

  defp settle_headline(ctx, {index, task}) do
    case Task.yield(task, @headline_grace_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, text} when is_binary(text) and text != "" ->
        Research.upsert_step(ctx.id, index, %{headline: text})

      _other ->
        :ok
    end

    nil
  end

  defp do_headline(ctx, index, notes) do
    node_id =
      start(ctx, %{
        parent_id: ctx.root_id,
        name: "R#{index} headline",
        prompt: Prompts.headline(ctx.question, notes),
        phase: "Round #{index}",
        tier: :lead,
        turns: :headline,
        schema: Prompts.headline_schema(),
        capability: :read_only
      })

    case await_json(ctx, node_id, timeout_ms(ctx, :lead)) do
      {:ok, %{"headline" => text}} -> Research.headline(text)
      _other -> nil
    end
  rescue
    error ->
      Logger.info("swarm_code research #{ctx.id}: headline #{index} failed: #{inspect(error)}")
      nil
  catch
    # Spec 51 §4.5: the RunServer went away under the await — no headline.
    :exit, _reason -> nil
  end

  defp plan(ctx, index, gathered) do
    node_id =
      start(ctx, %{
        parent_id: ctx.root_id,
        name: "Round #{index} plan",
        prompt: Prompts.plan(ctx, index, gathered),
        phase: "Round #{index}",
        tier: :lead,
        schema: Prompts.plan_schema(),
        # Spec 47 §2.2: the Fastest plan gets `structured_output` and nothing
        # else. The deep prompt invites it to `web_search` "to sanity-check
        # that an angle exists", which is a minute spent before any agent has
        # started; a fast plan is one call from the question alone.
        capability: if(fast?(ctx), do: :none, else: :read_only)
      })

    # A timed-out lead fails the round like a bad plan does; no retry.
    case await_json(ctx, node_id, timeout_ms(ctx, :lead)) do
      {:ok, plan} -> {plan, node_id}
      _error -> nil
    end
  end

  # Exactly `fanout` tasks: a lead that over-plans is trimmed, one that
  # under-plans is left alone rather than padded with an invented angle.
  defp tasks(plan, fanout) do
    plan
    |> Map.get("tasks", [])
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.take(fanout)
  end

  # Spec 48 §4: a non-final round closes for *planning* purposes once three
  # quarters of it has reported and whatever is left is well past the pace the
  # round itself set. The stragglers keep running: their notes land in their own
  # step, in every later plan, and in the reporter's notes.
  @straggler_quorum 0.75
  @straggler_factor 1.5
  @straggler_grace_ms 30_000
  @poll_ms 250

  @doc """
  The early-close rule in force: `{quorum, factor, grace_ms}` (spec 48 §4).

  `Application.get_env(:swarm_code_daemon, :research_straggler_grace_ms)` is the test
  seam — the same shape as `:research_timeout_ms` (spec 40 §1.6) — so a test can
  watch a round close early in milliseconds instead of half a minute.
  """
  @spec straggler_rule() :: {float(), float(), pos_integer()}
  def straggler_rule, do: {@straggler_quorum, @straggler_factor, grace_ms()}

  defp grace_ms,
    do:
      Application.get_env(:swarm_code_daemon, :research_straggler_grace_ms) || @straggler_grace_ms

  defp work(ctx, index, lead_id, tasks) do
    # Every worker of the round is started before any is awaited; RunServer
    # queues whatever is past `research_max_live`.
    started =
      for {task, pos} <- Enum.with_index(tasks, 1),
          do: {pos, task, start_worker(ctx, index, lead_id, pos, task)}

    # Spec 40 §1.5: each worker is awaited by a task of its own, and its note is
    # appended to the step row the moment it lands — `reported` moves 1/4, 2/4 …
    # instead of 0 → 4. The tasks never write: two workers landing at once would
    # both read `step.notes` and one note would be lost. Every append happens
    # here, in the Program process, as the polls yield. A worker's await that
    # exits with the RunServer surfaces as `{:exit, reason}` and is re-raised so
    # `Server.run_gone?/1` still sees the original reason.
    running =
      for {pos, task, node_id} <- started do
        %{
          index: index,
          pos: pos,
          node_id: node_id,
          at: System.monotonic_time(:millisecond),
          # Spec 51 §4.5: linked, so a brutal kill of the Program takes its
          # awaits down with it.
          task:
            Task.Supervisor.async(SwarmCode.Domain.TaskSupervisor, fn ->
              # An exit (the RunServer went away under the await) is carried
              # back as a value rather than crashing the task — no crash report
              # per worker — and re-raised below with the same reason.
              try do
                {pos, await_note(ctx, index, lead_id, task, node_id)}
              catch
                :exit, reason -> {:exited, reason}
              end
            end)
        }
      end

    collect(ctx, running, [], [], %{total: length(running), early?: index < ctx.steps_total})
  end

  # `early?` is false on the **last** round: it always waits for everyone, so
  # the reporter never misses a note. `total` is the round's whole fan-out and
  # never the shrinking list — the quorum is three quarters of the round.
  defp collect(ctx, running, notes, durations, rule) do
    {landed, still} = poll(running)

    {notes, durations} =
      Enum.reduce(landed, {notes, durations}, fn {worker, result}, {notes, durations} ->
        {take_note(ctx, worker, result, notes), [age(worker) | durations]}
      end)

    # Spec 51 §5.9 (c), pulled forward for §4.5: a straggler's start time is
    # read once and kept, not once per 250 ms poll — a Program killed by its
    # server (`close/3`) mid-`get_node` took the connection down with it.
    still = Enum.map(still, &with_started_at/1)

    cond do
      still == [] ->
        {sorted(notes), []}

      # Spec 51 §5.9 (c): the quorum counts the workers that came back, with
      # or without a note — a nil note is a finished worker too.
      rule.early? and close_round?(rule.total, length(durations), durations, still) ->
        {sorted(notes), still}

      true ->
        collect(ctx, still, notes, durations, rule)
    end
  end

  defp with_started_at(%{started_at: %DateTime{}} = worker), do: worker

  defp with_started_at(worker) do
    case Conversations.get_node(worker.node_id) do
      %{started_at: %DateTime{} = at} -> Map.put(worker, :started_at, at)
      _other -> worker
    end
  end

  # One pass over the workers still out: `{[{worker, result}], [still running]}`.
  defp poll(running) do
    results = Task.yield_many(Enum.map(running, & &1.task), timeout: @poll_ms)

    Enum.zip(running, results)
    |> Enum.split_with(fn {_worker, {_task, result}} -> result != nil end)
    |> then(fn {landed, waiting} ->
      {Enum.map(landed, fn {worker, {_task, result}} -> {worker, result} end),
       Enum.map(waiting, &elem(&1, 0))}
    end)
  end

  defp take_note(_ctx, _worker, {:ok, {:exited, reason}}, _notes), do: exit(reason)
  defp take_note(_ctx, _worker, {:exit, reason}, _notes), do: exit(reason)
  defp take_note(_ctx, _worker, {:ok, {_pos, nil}}, notes), do: notes

  defp take_note(ctx, worker, {:ok, {pos, note}}, notes) do
    # Spec 41 §4.4: the note's own task position, so the page pairs it with
    # `step.tasks` without matching on the title. Spec 51 §5.14: and its round,
    # so a later lead can tier what it already knows.
    note = note |> Map.put("pos", pos) |> Map.put("round", worker.index)
    Research.append_note(ctx.id, worker.index, note)
    [{pos, note} | notes]
  end

  defp take_note(_ctx, _worker, _other, notes), do: notes

  defp sorted(notes), do: notes |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))

  defp age(worker), do: System.monotonic_time(:millisecond) - worker.at

  # Three quarters back, and the slowest of the rest is past
  # `1.5 × median(finished) + 30 s` of its **own** clock — a worker still queued
  # behind `research_max_live` has not started one, so it is never a straggler.
  defp close_round?(total, reported, durations, still) do
    reported >= ceil(@straggler_quorum * total) and durations != [] and
      slowest(still) > @straggler_factor * median(durations) + grace_ms()
  end

  defp slowest(running) do
    running
    |> Enum.map(fn
      %{started_at: %DateTime{} = at} -> DateTime.diff(DateTime.utc_now(), at, :millisecond)
      _not_started -> 0
    end)
    |> Enum.max(fn -> 0 end)
  end

  # spec 68 T35: delegate to the shared Research.median/1, defaulting nil to 0
  defp median(values), do: SwarmCode.Domain.Research.median(values) || 0

  # Spec 48 §4: what a straggler was still doing belongs to the research.
  # `harvest/2` takes whatever has landed without waiting, before a plan is
  # written; `drain/2` waits for the rest, before the report is written.
  defp harvest(ctx, state), do: gather(ctx, state, 0)
  defp drain(ctx, state), do: gather(ctx, state, :infinity)

  defp gather(_ctx, %{stragglers: []} = state, _timeout), do: state

  defp gather(ctx, state, timeout) do
    {landed, still} =
      state.stragglers
      |> Enum.map(&{&1, Task.yield(&1.task, if(timeout == 0, do: 0, else: :infinity))})
      |> Enum.split_with(fn {_worker, result} -> result != nil end)

    notes =
      Enum.reduce(landed, [], fn {worker, result}, acc -> take_note(ctx, worker, result, acc) end)

    %{
      state
      | notes: state.notes ++ sorted(notes),
        stragglers: Enum.map(still, &elem(&1, 0))
    }
  end

  defp start_worker(ctx, index, lead_id, position, task) do
    start(ctx, %{
      parent_id: lead_id,
      name: worker_name(index, position, task),
      prompt: Prompts.worker(ctx, task),
      phase: "Round #{index}",
      tier: :worker,
      schema: Prompts.note_schema(),
      capability: :read_only
    })
  end

  # Spec 40 §1.6: a worker that times out is stopped, its partial findings become
  # its note, and — when Settings allow — a fresh worker picks up from them.
  # `lead_id` is the round's lead: the retry hangs under it like the original
  # workers, so the pane's tree groups it with its round.
  defp await_note(ctx, index, lead_id, task, node_id, attempt \\ 0) do
    case await_json(ctx, node_id, timeout_ms(ctx, :worker)) do
      {:ok, note} when is_map(note) ->
        note
        |> Map.put("task", task["title"] || task["question"])
        # Spec 41 §4.4: which agent answered — the retry's node when retried.
        |> Map.put("node_id", node_id)
        |> then(&if(attempt > 0, do: Map.put(&1, "retried", attempt), else: &1))

      {:error, :timeout} ->
        partial = ctx |> partial_note(task, node_id, attempt) |> Map.put("node_id", node_id)
        Research.Events.broadcast(ctx.id, {:research_agent_timeout, node_id, attempt}, ui: false)

        # Spec 47 §2.3: Fastest never retries a timed-out worker whatever
        # Settings say — a retry is another 90 s on a four-minute budget, and
        # the partial note already carries every page the agent opened.
        if not fast?(ctx) and ctx[:retry?] != false and attempt < (ctx[:max_retries] || 0) do
          retry_id =
            start(ctx, %{
              parent_id: lead_id,
              name:
                "R#{index}·↻#{attempt + 1} " <>
                  String.slice(to_string(task["title"] || "task"), 0, 14),
              prompt: Prompts.worker(ctx, task, partial: partial),
              phase: "Round #{index}",
              tier: :worker,
              schema: Prompts.note_schema(),
              capability: :read_only
            })

          await_note(ctx, index, lead_id, task, retry_id, attempt + 1)
        else
          partial
        end

      :error ->
        # Spec 47 §2.3: a worker that spent its six turns without ever calling
        # `structured_output` used to contribute nothing at all. On Fastest
        # that is a quarter of the research thrown away with no retry to save
        # it, and the pages it opened are real sources — so its partial note
        # stands in, marked `partial` but not `timed_out`.
        if fast?(ctx) do
          ctx
          |> partial_note(task, node_id, attempt, :no_output)
          |> Map.put("node_id", node_id)
        end
    end
  end

  @doc """
  What the worker had when the clock ran out (spec 40 §1.6): its `web_fetch`
  pages as sources, its last written text as the summary. Never invents a
  fact; marked `partial` and `timed_out` for the lead, the reporter and the
  page.
  """
  @spec partial_note(map(), map(), String.t(), non_neg_integer()) :: map()
  def partial_note(ctx, task, node_id, attempt),
    do: partial_note(ctx, task, node_id, attempt, :timeout)

  @doc """
  The same note for a worker that never reported at all (spec 47 §2.3):
  `:timeout` when the clock ran out, `:no_output` when the turns did.
  """
  @spec partial_note(map(), map(), String.t(), non_neg_integer(), :timeout | :no_output) :: map()
  def partial_note(ctx, task, node_id, attempt, reason) do
    # spec 73 T86: the titles without the results (a deep worker's 24 turns
    # of fetched pages used to be pulled from SQLite per timeout only to be
    # dropped), and one query for the last llm result this keeps 1 500 of.
    ops = Conversations.child_ops_summary(ctx.run_id, node_id)

    pages =
      for op <- ops,
          op.op_type == "web_fetch",
          op.status == "done",
          url = url_of(op.title),
          do: url

    text =
      case Conversations.last_child_result(ctx.run_id, node_id, "llm") do
        nil ->
          nil

        result ->
          result |> String.replace(~r/\s+/, " ") |> String.trim() |> String.slice(0, 1_500)
      end

    %{
      "task" => task["title"] || task["question"],
      "summary" =>
        partial_reason(ctx, reason, attempt) <>
          (text || "It opened #{length(pages)} page(s) and reported nothing yet."),
      "facts" => [],
      "sources" =>
        for(
          url <- pages,
          do: %{"url" => url, "title" => URI.parse(url).host || url, "quality" => 2}
        ),
      "open_questions" => [task["question"] || ""],
      "partial" => true,
      "timed_out" => reason == :timeout,
      "attempt" => attempt
    }
  end

  defp partial_reason(ctx, :timeout, attempt) do
    "PARTIAL — this agent timed out after #{div(timeout_ms(ctx, :worker), 1000)} s" <>
      if(attempt > 0, do: " (retry #{attempt})", else: "") <> ". "
  end

  defp partial_reason(_ctx, :no_output, _attempt),
    do: "PARTIAL — this agent ran out of turns before it reported. "

  # An op title is `<tool> <first argument>` (spec 22 §3.2); for web_fetch the
  # argument is the URL.
  defp url_of(title) do
    case String.split(to_string(title), " ", parts: 2) do
      [_tool, url] -> if String.starts_with?(url, "http"), do: String.trim(url)
      _other -> nil
    end
  end

  @doc """
  One tier's whole wall clock (spec 47 §2.1).

  A deep level runs on `settings.research_agent_timeout_s` — 600 s — and gives
  the reporters twice that. Fastest runs on `@fast_timeouts` instead, so its
  worst case is 45 + 90 + 120 rather than 600 + 600 + 1 200.
  `Application.get_env(:swarm_code_daemon, :research_timeout_ms)` is the test seam and
  still wins over both: a test that sets it gets exactly what it asked for.
  """
  @spec timeout_ms(ctx(), :lead | :worker | :reporter) :: pos_integer()
  def timeout_ms(ctx, tier) do
    cond do
      ctx[:timeout_forced?] -> base_timeout(ctx) * if(tier == :reporter, do: 2, else: 1)
      # Spec 47 §2.6: "Build the designed report" runs the real HTML pass over
      # a finished research. It is off the critical path by definition, so it
      # gets the deep clock even on a Fastest row.
      fast?(ctx) and ctx[:rebuild?] != true -> @fast_timeouts[tier]
      # Spec 40 §1.6: the reporters get twice the agents' clock.
      tier == :reporter -> 2 * base_timeout(ctx)
      true -> base_timeout(ctx)
    end
  end

  defp base_timeout(ctx), do: ctx[:timeout_ms] || 600_000

  defp worker_name(index, position, task) do
    title = task["title"] || task["question"] || "task #{position}"
    "R#{index}·" <> String.slice(to_string(title), 0, 18)
  end

  # ------------------------------------------------------------------ report

  defp report(ctx, notes) do
    sources = sources(notes)
    # spec 73 T87: same-directory atomic replacement — this task is
    # `brutal_kill`ed by `Server.close/3` on stop or quit, and a truncated
    # sources.json or result.md was read back as the report.
    write_output(
      ctx,
      Research.sources_path(ctx.id),
      Jason.encode_to_iodata!(sources, pretty: true)
    )

    node_id =
      start(ctx, %{
        parent_id: ctx.root_id,
        name: "Report",
        prompt: Prompts.reporter(ctx, notes, sources),
        phase: "Report",
        tier: :reporter,
        # The reporter writes result.md itself; `project_root` is the research
        # directory, so `write_file` cannot reach anything else.
        #
        # Spec 47 §2.5: the Fastest reporter has no tools at all. Its answer
        # *is* the document — one turn, no `write_file` round trip.
        capability: if(fast?(ctx), do: :none, else: :read_write),
        schema: nil
      })

    # Spec 40 §1.6: the reporter gets twice the agents' clock.
    answer =
      case await_running(ctx, node_id, timeout_ms(ctx, :reporter)) do
        {:ok, text} ->
          text

        {:error, :timeout} ->
          RunServer.stop_agent(ctx.run_id, node_id)
          "The reporter timed out after #{div(timeout_ms(ctx, :reporter), 1000)} s."

        {:error, reason} ->
          "The reporter failed: " <> to_string(reason)
      end

    path = Research.result_path(ctx.id)

    if fast?(ctx) do
      # Spec 47 §2.5: nothing wrote the file, so this does — the answer
      # verbatim when it is already the document, the wrapper when it is not.
      write_output(ctx, path, fast_markdown(ctx, answer, sources))
    else
      # A reporter that answered but never called write_file still leaves a file.
      unless File.exists?(path),
        do: write_output(ctx, path, fallback_markdown(ctx, answer, sources))
    end

    # Spec 48 §2: **every** level renders its report here, in microseconds. The
    # designed pass used to run on this line — 52 s of a measured 259 s research
    # (#9004) for a document that carries no fact `result.md` does not — and now
    # runs in the background, off the clock the user is watching.
    report_path = if File.exists?(path), do: HtmlRender.write(ctx, path, sources)

    {:ok,
     %{
       summary: summary(answer),
       sources: sources,
       report_path: report_path,
       title: title_from(path) || Research.fallback_title(ctx.question),
       design_state: if(report_path, do: "rendered"),
       design?: auto_design?(ctx)
     }}
  end

  # spec 73 T87: every output of a research lands through `AtomicFile`,
  # confined to the research directory; a refused write is logged, as the
  # bare `File.write/2` result was ignored before.
  defp write_output(ctx, path, data) do
    case SwarmCode.Domain.AtomicFile.replace(Research.dir(ctx.id), path, data) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "swarm_code research #{ctx.id}: could not write #{Path.basename(path)}: " <>
            SwarmCode.Domain.AtomicFile.format_error(reason)
        )

        :error
    end
  end

  # Spec 48 §2: `research_auto_design` — "deep" designs medium/high/ultra and
  # leaves Fastest manual (spec 47 §3), "all" designs Fastest too, "never"
  # leaves the button as the only way in. The rule lives in `Research` because
  # Settings counts the same runs in its tier table.
  defp auto_design?(ctx), do: Research.auto_design?(ctx[:level], ctx[:settings])

  # Spec 47 §2.5: the fast reporter answers with the finished Markdown. A reply
  # that already starts with its `# heading` is the file, byte for byte; a
  # reply that does not (an apology, a timeout line) still gets the wrapper the
  # deep path has always used, so `result.md` is never a bare sentence.
  defp fast_markdown(ctx, answer, sources) do
    text = answer |> to_string() |> String.trim()

    if String.starts_with?(text, "#"),
      do: text <> "\n",
      else: fallback_markdown(ctx, answer, sources)
  end

  @doc """
  The HTML pass (spec 25 §2.1), a separate agent so a failed or ugly run never
  costs the Markdown — `result.md` is already on disk when this starts.

  Spec 26 §5.3: it gets **two** attempts. A measured `ultra` run came back from
  its one turn with no text, no tool calls and zero usage — an empty turn — and
  the whole pass produced nothing with nobody any the wiser.
  """
  @spec html_report(ctx(), String.t(), [map()]) :: String.t() | nil
  def html_report(ctx, markdown_path, sources) do
    # Spec 48 §2: the rendered report is the floor. Each attempt deletes
    # report.html before it writes (spec 39 §1.3), so the rendered one is kept
    # aside first and put back if the designed pass produces nothing — a failed
    # design must never leave a research with no report at all.
    #
    # spec 60 T44: bound before the `try`, so a raise anywhere in the pass puts
    # it back too instead of leaving "Open report" pointing at nothing.
    kept = keep_rendered(ctx)

    try do
      markdown = File.read!(markdown_path)

      result =
        Enum.reduce_while(1..2, nil, fn attempt, _acc ->
          case html_attempt(ctx, markdown, sources, attempt) do
            nil when attempt < 2 -> {:cont, nil}
            result -> {:halt, result}
          end
        end)

      if result, do: rm_kept(kept), else: restore_rendered(ctx, kept)
      result
    rescue
      error ->
        Logger.warning(
          "swarm_code research #{ctx.id} HTML pass failed: #{Exception.message(error)}"
        )

        restore_rendered(ctx, kept)
        nil
    end
  end

  # Only the report this research has actually adopted is kept: a `report.html`
  # the row does not point at is a stale file from a reused id, and spec 39 §1.3
  # says a failed pass must never adopt one.
  defp keep_rendered(ctx) do
    path = Research.report_path(ctx.id)
    kept = Path.join(Research.dir(ctx.id), "rendered.html")
    research = Research.get(ctx.id)

    if research && research.report_path == path && File.exists?(path) &&
         File.rename(path, kept) == :ok,
       do: kept
  end

  defp rm_kept(nil), do: :ok
  defp rm_kept(path), do: File.rm(path)

  defp restore_rendered(_ctx, nil), do: :ok
  defp restore_rendered(ctx, kept), do: File.rename(kept, Research.report_path(ctx.id))

  defp html_attempt(ctx, markdown, sources, attempt) do
    # Spec 39 §1.3: the size check below must only ever see what *this*
    # attempt wrote — never a report.html left by an earlier pass or rebuild.
    path = Research.report_path(ctx.id)
    File.rm(path)

    node_id =
      start(ctx, %{
        parent_id: ctx.root_id,
        name: if(attempt == 1, do: "Report (HTML)", else: "Report (HTML) retry"),
        prompt: Prompts.html_reporter(ctx, markdown, sources, attempt),
        phase: "Report",
        tier: :reporter,
        capability: :read_write,
        turns: :html,
        max_tokens: @html_max_tokens,
        skill: "html-report",
        schema: nil
      })

    case await_running(ctx, node_id, timeout_ms(ctx, :reporter)) do
      {:error, :timeout} -> RunServer.stop_agent(ctx.run_id, node_id)
      _other -> :ok
    end

    case File.stat(path) do
      {:ok, %{size: size}} when size >= @min_report_bytes ->
        path

      {:ok, %{size: size}} ->
        Logger.info(
          "swarm_code research #{ctx.id}: report.html was only #{size} bytes (attempt #{attempt})"
        )

        nil

      _other ->
        Logger.info(
          "swarm_code research #{ctx.id}: the HTML pass wrote no report (attempt #{attempt})"
        )

        nil
    end
  end

  @doc false
  def sources(notes) do
    notes
    |> Enum.flat_map(fn note -> note |> Map.get("sources") |> List.wrap() end)
    |> Enum.filter(&(is_map(&1) and is_binary(&1["url"]) and &1["url"] != ""))
    |> Enum.map(&Map.put(&1, "quality", quality(&1["quality"])))
    |> Enum.uniq_by(& &1["url"])
    |> Enum.sort_by(&(-&1["quality"]))
  end

  # A model that answers "4" or 4.0 must not crash the sort (spec 39 §1.3).
  # spec 68 T36: delegate to the shared Research.rating/1
  defp quality(q), do: SwarmCode.Domain.Research.rating(q)

  defp fallback_markdown(ctx, answer, sources) do
    list =
      sources
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {s, i} -> "#{i}. [#{s["title"]}](#{s["url"]})" end)

    """
    # #{Research.fallback_title(ctx.question)}

    > **Question** — #{ctx.question}

    ## Answer

    #{answer}

    ## Sources

    #{list}
    """
  end

  defp summary(text) do
    text
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 600)
  end

  # The reporter's own `# heading`, which reads better than the raw question.
  defp title_from(path) do
    with {:ok, text} <- File.read(path),
         [_full, title] <- Regex.run(~r/^#\s+(.+)$/m, text) do
      title |> String.trim() |> String.slice(0, 120)
    else
      _other -> nil
    end
  end

  # ------------------------------------------------------------------ agents

  defp start(ctx, attrs) do
    opts =
      [capability: attrs.capability, max_turns: turn_cap(ctx, attrs)] ++
        Research.model(attrs.tier, ctx.settings, ctx.fallback_model, ctx[:override]) ++
        if(attrs[:schema], do: [schema: attrs.schema], else: []) ++
        if(attrs[:max_tokens], do: [max_tokens: attrs.max_tokens], else: []) ++
        skill_opts(attrs[:skill])

    {:ok, node_id} =
      RunServer.start_agent(ctx.run_id, %{
        role: "worker",
        parent_id: attrs.parent_id,
        name: attrs.name,
        prompt: attrs.prompt,
        phase: attrs.phase,
        opts: opts
      })

    node_id
  end

  # Spec 47 §2: a Fastest agent's cap comes from `@fast_turns`; the deep table
  # is the fallback, so a fast level that ever started an HTML or headline
  # agent would still get a sane number rather than nil.
  defp turn_cap(ctx, attrs) do
    key = attrs[:turns] || attrs.tier
    if fast?(ctx), do: @fast_turns[key] || @turns[key], else: @turns[key]
  end

  # Spec 25 §1.3: the only place a skill is read today.
  defp skill_opts(nil), do: []

  defp skill_opts(name) do
    case Skills.prompt(Skills.get(nil, name)) do
      "" -> []
      text -> [system_extra: text]
    end
  end

  defp await_json(ctx, node_id, timeout) do
    case await_running(ctx, node_id, timeout) do
      {:ok, text} ->
        case Jason.decode(text) do
          {:ok, %{} = decoded} ->
            {:ok, decoded}

          _other ->
            Logger.info("swarm_code research #{ctx.id}: agent #{node_id} returned no JSON")
            :error
        end

      {:error, :timeout} ->
        Logger.info(
          "swarm_code research #{ctx.id}: agent #{node_id} timed out after #{timeout} ms"
        )

        RunServer.stop_agent(ctx.run_id, node_id)
        {:error, :timeout}

      {:error, reason} ->
        Logger.info("swarm_code research #{ctx.id}: agent #{node_id} failed: #{inspect(reason)}")
        :error
    end
  end

  # Spec 40 §1.6: the timeout is wall time *since the agent started*, never
  # since we began waiting — a worker queued behind `research_max_live` has
  # not used any of its clock. The bounded call is retried with what is left.
  @min_wait_ms 1_000

  defp await_running(ctx, node_id, timeout_ms) do
    case RunServer.await_agent(ctx.run_id, node_id, timeout_ms) do
      {:error, :timeout} ->
        case Conversations.get_node(node_id) do
          %{status: "queued"} ->
            await_running(ctx, node_id, timeout_ms)

          %{started_at: nil} ->
            await_running(ctx, node_id, timeout_ms)

          %{started_at: started} ->
            used = DateTime.diff(DateTime.utc_now(), started, :millisecond)

            if used < timeout_ms,
              do: await_running(ctx, node_id, max(timeout_ms - used, @min_wait_ms)),
              else: {:error, :timeout}

          nil ->
            {:error, :timeout}
        end

      other ->
        other
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
