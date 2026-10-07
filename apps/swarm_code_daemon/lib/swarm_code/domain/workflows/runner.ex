defmodule SwarmCode.Domain.Workflows.Runner do
  @moduledoc """
  One process per workflow run: it steps the program (spec 09 §4.1).

  The script itself runs in a Task so the Runner never blocks; every host call
  comes back here as a `GenServer.call`, is looked up in the journal (replay) or
  started live, and is committed by the calling Task when it returns. Panels are
  charged against the agent budget as one unit before any slot launches.

  Definitions are plain Elixir scripts and are evaluated as such — deliberately,
  with no sandbox (spec 09, preamble): they are written by the user (or by the
  assistant during `/create-workflow`) and are as trusted as the app itself.
  """
  use GenServer, restart: :temporary
  require Logger

  alias SwarmCode.Domain.Engine.{Events, RunServer}
  alias SwarmCode.Domain.Workflows
  alias SwarmCode.Domain.Workflows.API

  @max_logs 500
  # spec 55 T10 (55a A3): the reply of a host call whose journal INSERT was refused.
  @journal_refused "journal write refused (database busy) — resume the run"

  def start_link(args),
    do: GenServer.start_link(__MODULE__, args, name: via(args.run_id), hibernate_after: 15_000)

  def via(run_id), do: {:via, Registry, {SwarmCode.Domain.Registry, {:workflow, run_id}}}

  @doc "Pauses the run: the script and every live worker stop, the journal stays."
  def pause(run_id), do: safe_call(run_id, :pause_run)

  @doc "The Runner pid of a run, if it is alive."
  def whereis(run_id) do
    case Registry.lookup(SwarmCode.Domain.Registry, {:workflow, run_id}) do
      [{pid, _}] -> pid
      _ -> nil
    end
  end

  defp safe_call(run_id, msg) do
    GenServer.call(via(run_id), msg, :infinity)
  catch
    :exit, _ -> {:error, :not_running}
  end

  # ------------------------------------------------------------------ boot

  @impl true
  def init(args) do
    # Spec 51 §4.4: a stop reaches this process as the supervisor's `:shutdown`,
    # and only a trapping process runs `terminate/2` for it — where the script
    # Task is killed. The catch-all `handle_info/2` swallows the `{:EXIT, _, _}`.
    Process.flag(:trap_exit, true)

    defaults = %{
      journal: %{},
      seq: 0,
      script: nil,
      finished?: false,
      pending: %{},
      phase: nil,
      answer: nil,
      last_error: nil,
      retried: MapSet.new(),
      infra_since: nil,
      panel_tasks: MapSet.new(),
      # Spec 54 §1.5 (54a E1): log lines accumulate here and reach the `logs`
      # JSON column at most once a second.
      pending_logs: [],
      logs_timer: nil,
      logs_written_at: 0,
      # spec 55 T10: attrs a busy write could not land; merged into the next one
      pending_wf: %{},
      # pass74 (spec 74) BUGS-57: top-level `budget()`/`last_error()` reads so
      # far at each seq — the next one takes slot -2 - count.
      reads: %{}
    }

    state = Map.merge(defaults, args)
    # spec 74 UI-SPEED-15: every log line carries a monotonic "n" (the
    # pipeline keys its rows by it); a resumed run continues after the lines
    # it already has.
    state = Map.put(state, :log_n, next_log_n(Map.get(state.wf, :logs)))
    # pass74 (spec 74) BUGS-58: set by "Retry failed" (`Run.retry_from_seq`).
    {:ok, Map.put(state, :retry_from, Map.get(state.wf, :retry_from_seq)), {:continue, :run}}
  end

  @impl true
  def handle_continue(:run, state) do
    journal =
      state.run_id
      |> Workflows.journal()
      |> Map.new(fn entry -> {{entry.seq, entry.slot}, entry} end)

    ctx = %{
      run_id: state.run_id,
      runner: self(),
      root: state.project.root_path,
      display_name: state.wf.display_name,
      panel: nil,
      calls: 0,
      agent_called?: false
    }

    runner = self()
    ast = state.ast
    bindings = [args: state.args, meta: state.meta]

    task =
      Task.Supervisor.async_nolink(SwarmCode.Domain.TaskSupervisor, fn ->
        API.bound_heap()
        API.put_context(ctx)
        send(runner, {:script_finished, eval(ast, bindings)})
        :ok
      end)

    {:noreply, %{state | journal: journal, script: task}}
  end

  def handle_continue(:shutdown, state), do: {:stop, :normal, state}

  @doc false
  def eval(ast, bindings) do
    ast = field_access_only(ast)

    wrapped =
      {:__block__, [],
       [quote(do: import(SwarmCode.Domain.Workflows.API, warn: false)), ast, quote(do: :ok)]}

    Code.eval_quoted(wrapped, bindings, file: "workflow.exs")
    {:complete, %{summary: "Finished."}}
  rescue
    e -> {:failed, format_error(e, __STACKTRACE__)}
  catch
    :throw, {:workflow, payload} -> payload
  end

  # spec 60 T33: a no-parens dot is a *call* when the target is an atom. Make it what Smoke
  # assumed: `Map.fetch!/2` behaves identically on maps and structs and raises BadMapError on an
  # atom. Literal aliases (`Enum.x`) and Erlang modules (`:os.x`) are calls to Smoke as well and
  # stay calls here — its allow-list already judged them.
  defp field_access_only(ast) do
    Macro.prewalk(ast, fn
      {{:., _, [target, key]}, meta, []} = node
      when is_atom(key) and not is_atom(target) and
             not (is_tuple(target) and elem(target, 0) == :__aliases__) ->
        if Keyword.get(meta, :no_parens, false) do
          line = Keyword.get(meta, :line, 1)
          quote(line: line, do: Map.fetch!(unquote(target), unquote(key)))
        else
          node
        end

      node ->
        node
    end)
  end

  @doc false
  # Public for `API.panel/2` (spec 51 §5.12): a slot's exception fails the run
  # with the same line the main script's would.
  def format_error(exception, stacktrace) do
    frame =
      Enum.find(stacktrace, fn
        {_m, _f, _a, info} -> Keyword.get(info, :file) in [~c"workflow.exs", "workflow.exs"]
        _ -> false
      end)

    Exception.format(:error, exception, if(frame, do: [frame], else: []))
  end

  # ------------------------------------------------------------------ calls

  @impl true
  def handle_call({:phase, title}, _from, state) do
    {:reply, :ok, %{update_wf(state, %{phase: title}) | phase: title}}
  end

  def handle_call({:log, text}, _from, state) do
    {:reply, :ok, log_line(state, text)}
  end

  def handle_call(:budget, _from, state) do
    spent = state.wf.agents_admitted

    # `panel_replay` is for `API.panel/2` only and is stripped before a script
    # ever sees it (spec 33 §2): it is the count the *next* call was already
    # admitted with, so a resumed panel reads the items it read the first time
    # instead of however many the charged-down budget would allow now.
    {:reply,
     %{
       total: state.wf.budget,
       spent: spent,
       remaining: state.wf.budget - spent,
       panel_replay: panel_replay_count(state)
     }, state}
  end

  def handle_call({:panel_admit, count}, _from, state) do
    seq = state.seq + 1
    state = %{state | seq: seq}
    fingerprint = :erlang.phash2({:panel, count})

    case state.journal[{seq, -1}] do
      # spec 74 UI-SPEED-5: the panel was paid for when it was first admitted,
      # and `agents_admitted` already counts it after a resume — bound its live
      # slots by the panel's own size, not by what is left of the budget.
      %{fingerprint: ^fingerprint} ->
        {:reply, {:replay, seq, max(min(state.wf.max_live, count), 1)}, state}

      %{} ->
        # pass74 (spec 74) BUGS-58: a retried result changed the panel's items.
        case rewrite(state, seq, :all) do
          {:ok, state} -> admit_panel(state, seq, count, fingerprint)
          :no -> {:reply, {:failed, mismatch_message(seq)}, state}
          {:error, :database_busy} -> {:reply, {:failed, @journal_refused}, state}
        end

      nil ->
        admit_panel(state, seq, count, fingerprint)
    end
  end

  def handle_call({:panel_task, pid}, _from, state) when is_pid(pid) do
    {:reply, :ok, %{state | panel_tasks: MapSet.put(state.panel_tasks, pid)}}
  end

  def handle_call({:host, kind, payload, opts, where}, from, state) do
    %{seq: seq0, slot: slot, panel: panel?} = where
    seq = seq0 || state.seq + 1
    state = if seq0, do: state, else: %{state | seq: seq}
    fingerprint = :erlang.phash2({kind, payload, opts})

    case state.journal[{seq, slot}] do
      %{fingerprint: ^fingerprint, result: result} = entry ->
        {:reply, {:replay, decode_result(result)},
         state |> restore_last_error(entry) |> consumed({seq, slot})}

      %{} ->
        # pass74 (spec 74) BUGS-58: after "Retry failed", a call a retried
        # result now feeds is re-run with everything after it.
        case rewrite(state, seq, slot) do
          {:ok, state} ->
            state = %{state | pending: Map.put(state.pending, {seq, slot}, fingerprint)}
            live(kind, payload, opts, seq, slot, panel?, from, state)

          :no ->
            {:reply, {:failed, mismatch_message(seq)}, state}

          {:error, :database_busy} ->
            {:reply, {:failed, @journal_refused}, state}
        end

      nil ->
        state = %{state | pending: Map.put(state.pending, {seq, slot}, fingerprint)}
        live(kind, payload, opts, seq, slot, panel?, from, state)
    end
  end

  def handle_call({:commit, seq, slot, kind, value}, _from, state) do
    fingerprint = Map.get(state.pending, {seq, slot}, :erlang.phash2({seq, slot}))
    state = %{state | pending: Map.delete(state.pending, {seq, slot})}
    # Anything that came back means the provider is reachable again.
    state = if is_nil(value), do: state, else: %{state | infra_since: nil}

    # pass74 (spec 74) BUGS-57: a failed agent's entry keeps the error, so a
    # replay of it restores `last_error()`.
    insert =
      if is_nil(value) and kind == "agent",
        do: journal_insert_failed(state, seq, slot, kind, fingerprint),
        else: journal_insert(state, seq, slot, kind, fingerprint, value)

    case insert do
      {:ok, state} ->
        {:reply, :ok, state}

      {:error, :database_busy} ->
        {:reply, {:failed, @journal_refused}, state}

      # spec 74 BUGS-16: the script fails with the reason; the Runner lives on.
      {:error, {:not_encodable, message}} ->
        {:reply, {:failed, "host result is not JSON-encodable: " <> message}, state}
    end
  end

  def handle_call(:last_error, _from, state), do: {:reply, state.last_error, state}

  # pass74 (spec 74) BUGS-57: a script's `budget()` / `last_error()`. The first
  # read is journaled (kind "read"), a replay returns what was read then.
  def handle_call({:read, what, where}, _from, state) when what in [:budget, :last_error] do
    {seq, slot, state} = read_key(state, where)
    fingerprint = :erlang.phash2({:read, what})

    case state.journal[{seq, slot}] do
      %{kind: "read", fingerprint: ^fingerprint, result: result} ->
        {:reply, {:value, read_value(what, decode_result(result))}, consumed(state, {seq, slot})}

      %{} ->
        case rewrite(state, seq, slot) do
          {:ok, state} -> live_read_reply(state, what, seq, slot, fingerprint)
          :no -> {:reply, {:failed, mismatch_message(seq)}, state}
          {:error, :database_busy} -> {:reply, {:failed, @journal_refused}, state}
        end

      nil ->
        live_read_reply(state, what, seq, slot, fingerprint)
    end
  end

  # A worker died. Infrastructure failures buy one fresh agent (spec 11 §7.4);
  # everything else (max_turns, a refusal, a denied tool) is the slot's answer.
  def handle_call({:retry_agent, seq, slot, prompt, opts, reason}, _from, state) do
    infra? = infrastructure?(reason)
    key = {seq, slot}

    state = %{
      state
      | last_error:
          reason &&
            reason |> to_string() |> SwarmCode.Domain.LLM.HTTP.redact() |> String.slice(0, 500),
        infra_since: if(infra?, do: state.infra_since || now_ms(), else: nil)
    }

    cond do
      state.finished? or not infra? ->
        {:reply, :no, state}

      infra_exhausted?(state) ->
        {:reply, :no, infra_pause(%{state | finished?: true}), {:continue, :shutdown}}

      # Spec 51 §5.10: the same slot failing twice on infrastructure is the
      # provider being down, whatever the clock says — park now; the Watchdog
      # brings the run back. (The transport already retried 5× over ~80 s, so
      # the second failure always lands inside the three-minute window.)
      MapSet.member?(state.retried, key) ->
        {:reply, :no, infra_pause(%{state | finished?: true}), {:continue, :shutdown}}

      true ->
        name = to_string(opts[:name] || "agent #{seq}.#{slot}")
        state = log_line(state, "retry #{name} (#{reason_word(reason)})")
        state = %{state | retried: MapSet.put(state.retried, key)}

        case start_worker(state, prompt, opts, seq, slot, slot_panel?(state, seq)) do
          {:ok, node_id, state} -> {:reply, {:agent, node_id}, state}
          {:error, state} -> {:reply, :no, state}
        end
    end
  end

  def handle_call(:pause_run, _from, state) do
    if state.finished? do
      {:reply, :ok, state}
    else
      # spec 60 T47: the flushed state travels on, so `terminate/2` writes no
      # second logs row from the stale one.
      state =
        state
        |> stop_work()
        |> finish("paused", %{
          pause_kind: "manual",
          pause_message: "Paused by the user"
        })

      {:reply, :ok, %{state | finished?: true}, {:continue, :shutdown}}
    end
  end

  @impl true
  def handle_cast({:panel_task_done, pid}, state) when is_pid(pid) do
    {:noreply, %{state | panel_tasks: MapSet.delete(state.panel_tasks, pid)}}
  end

  # A panel admission charged against what is left of the budget.
  defp admit_panel(state, seq, count, fingerprint) do
    remaining = state.wf.budget - state.wf.agents_admitted
    max_concurrency = max(min(state.wf.max_live, remaining), 1)

    if count > remaining do
      {:reply, {:pause, "budget", budget_message(count, remaining, state.wf.budget)}, state}
    else
      case journal_insert(state, seq, -1, "panel", fingerprint, count) do
        {:ok, state} -> {:reply, {:ok, seq, max_concurrency}, charge(state, count)}
        {:error, :database_busy} -> {:reply, {:failed, @journal_refused}, state}
      end
    end
  end

  # ------------------------------------------------------------ retry rewrite

  # pass74 (spec 74) BUGS-58: "Retry failed" deletes the failed agent entries
  # and resumes. A retried slot that now returns text changes the prompt of
  # every call that uses it, and each of those used to answer
  # `{:failed, mismatch}` — a done run became a failed one. At or after the
  # first deleted seq, the Runner (which owns the journal) deletes the changed
  # entry and every later one, refunds their admissions by re-deriving
  # `agents_admitted` from what is left, and the call runs live. `:all` takes
  # every slot at `seq` (a panel whose items changed).
  defp rewrite(%{retry_from: from} = state, seq, slot) when is_integer(from) and seq >= from do
    doomed =
      for {{s, sl} = key, entry} <- state.journal,
          s > seq or (s == seq and after_at_seq?(sl, slot)),
          do: {key, entry}

    case Workflows.delete_journal(state.run_id, Enum.map(doomed, fn {_key, e} -> e.id end)) do
      :ok ->
        journal = Map.drop(state.journal, Enum.map(doomed, &elem(&1, 0)))
        state = %{state | journal: journal}
        admitted = Workflows.admitted(Map.values(journal))

        state =
          state
          |> log_line("retry: call #{seq} changed — re-running it and what follows")
          |> update_wf(%{agents_admitted: admitted})

        {:ok, state}

      {:error, :database_busy} ->
        {:error, :database_busy}
    end
  end

  defp rewrite(_state, _seq, _slot), do: :no

  # Which entries at the changed call's own seq go with it. A top-level read
  # sits at the seq of the call before it (-2, -3, … in reading order); a
  # panel slot's reads sit far below (`API` reads from -1_000_000 down).
  defp after_at_seq?(_sl, :all), do: true
  # A single call: it and the top-level reads after it.
  defp after_at_seq?(sl, 0), do: sl == 0 or top_level_read?(sl)
  # A top-level read: it and the reads after it, never one already read.
  defp after_at_seq?(sl, slot) when slot <= -2 and slot > -1_000_000,
    do: top_level_read?(sl) and sl <= slot

  # A panel slot's call or read: that entry, and the reads after the panel.
  # The other slots keep theirs; a later call in the same slot that changed
  # too is re-run when it is reached.
  defp after_at_seq?(sl, slot), do: sl == slot or top_level_read?(sl)

  defp top_level_read?(slot), do: slot <= -2 and slot > -1_000_000

  # ------------------------------------------------------------------ reads

  # pass74 (spec 74) BUGS-57: where a read is journaled. A top-level read sits
  # at the seq of the call before it, below the panel marker: -2, -3, …
  defp read_key(state, nil) do
    seq = state.seq
    count = Map.get(state.reads, seq, 0)
    {seq, -2 - count, %{state | reads: Map.put(state.reads, seq, count + 1)}}
  end

  defp read_key(state, {seq, slot}), do: {seq, slot, state}

  defp live_read_reply(state, what, seq, slot, fingerprint) do
    value = live_read(what, state)

    case journal_insert(state, seq, slot, "read", fingerprint, %{"v" => value}) do
      {:ok, state} -> {:reply, {:value, value}, state}
      {:error, :database_busy} -> {:reply, {:failed, @journal_refused}, state}
      {:error, {:not_encodable, message}} -> {:reply, {:failed, message}, state}
    end
  end

  defp live_read(:last_error, state), do: state.last_error

  # A journal written before reads were journaled has no record to replay:
  # the budget is then what the journal proves was admitted *up to this
  # call*, which is what the script read the first time — not the
  # end-of-journal count a resume starts from.
  defp live_read(:budget, state) do
    spent =
      if replaying?(state) do
        state.journal
        |> Map.values()
        |> Enum.filter(&(&1.seq <= state.seq))
        |> Workflows.admitted()
      else
        state.wf.agents_admitted
      end

    %{total: state.wf.budget, spent: spent, remaining: state.wf.budget - spent}
  end

  defp replaying?(state),
    do: Enum.any?(state.journal, fn {{seq, _slot}, _e} -> seq > state.seq end)

  defp read_value(:budget, %{"v" => %{} = v}),
    do: %{total: v["total"], spent: v["spent"], remaining: v["remaining"]}

  defp read_value(_what, %{"v" => v}), do: v
  defp read_value(_what, _other), do: nil

  # A replayed failed agent entry puts its error back where `last_error()` reads.
  defp restore_last_error(state, %{kind: "agent", result: result}) when is_binary(result) do
    case Jason.decode(result) do
      {:ok, %{"ok" => false, "error" => error}} when is_binary(error) and error != "no result" ->
        %{state | last_error: error}

      _other ->
        state
    end
  end

  defp restore_last_error(state, _entry), do: state

  defp journal_insert_failed(state, seq, slot, kind, fingerprint) do
    case safe_json(%{"ok" => false, "error" => state.last_error || "no result"}) do
      {:ok, json} -> journal_insert_json(state, seq, slot, kind, fingerprint, json)
      {:error, _message} -> journal_insert(state, seq, slot, kind, fingerprint, nil)
    end
  end

  # ------------------------------------------------------------------ live calls

  defp live(:agent, prompt, opts, seq, slot, panel?, _from, state) do
    remaining = state.wf.budget - state.wf.agents_admitted

    if not panel? and remaining < 1 do
      {:reply, {:pause, "budget", budget_message(1, remaining, state.wf.budget)}, state}
    else
      state = if panel?, do: state, else: charge(state, 1)

      case start_worker(state, prompt, opts, seq, slot, panel?) do
        {:ok, node_id, state} -> {:reply, {:agent, node_id, seq}, state}
        {:error, state} -> {:reply, {:replay, nil}, state}
      end
    end
  end

  defp live(:await_user, question, opts, seq, slot, _panel?, _from, state) do
    case state.answer do
      answer when is_binary(answer) ->
        fingerprint = Map.get(state.pending, {seq, slot}, :erlang.phash2({seq, slot}))

        case journal_insert(state, seq, slot, "await_user", fingerprint, answer) do
          {:ok, state} -> {:reply, {:replay, answer}, %{state | answer: nil}}
          {:error, :database_busy} -> {:reply, {:failed, @journal_refused}, state}
        end

      _ ->
        _ = question
        {:reply, {:gate, question, Enum.map(opts[:options] || [], &to_string/1), seq}, state}
    end
  end

  defp live(_kind, _payload, _opts, seq, _slot, _panel?, _from, state) do
    {:reply, {:exec, seq}, state}
  end

  # A retry reuses the slot it replaces: no second charge against the budget.
  defp start_worker(state, prompt, opts, seq, slot, panel?) do
    attrs = %{
      parent_id: state.root_node_id,
      role: "worker",
      name: to_string(opts[:name] || default_name(seq, slot, panel?)),
      prompt: prompt,
      opts: opts,
      phase: state.phase,
      group: if(panel?, do: "p#{seq}", else: nil)
    }

    case RunServer.start_agent(state.run_id, attrs) do
      {:ok, node_id} -> {:ok, node_id, state}
      _other -> {:error, state}
    end
  end

  # Slots of a panel carry the panel's seq in the journal (kind "panel").
  defp slot_panel?(state, seq), do: match?(%{kind: "panel"}, state.journal[{seq, -1}])

  defp default_name(seq, slot, true), do: "#{seq}.#{slot}"
  defp default_name(seq, _slot, false), do: "agent #{seq}"

  defp panel_replay_count(state) do
    case state.journal[{state.seq + 1, -1}] do
      %{kind: "panel", result: result} ->
        case decode_result(result) do
          count when is_integer(count) and count >= 0 -> count
          _other -> nil
        end

      _other ->
        nil
    end
  end

  defp charge(state, n), do: update_wf(state, %{agents_admitted: state.wf.agents_admitted + n})

  defp budget_message(count, remaining, budget) do
    "Panel of #{count} agents needs more than the remaining #{remaining} of #{budget} slots. " <>
      "Resume with a higher budget."
  end

  # ---------------------------------------------------------- infrastructure

  @infra_markers [
    "request failed after",
    "stream interrupted",
    "connection",
    "econnrefused",
    "nxdomain",
    "closed",
    "tls",
    "socket",
    "overloaded",
    "rate limit",
    "too many requests",
    "could not start agent",
    "agent crashed"
  ]

  @infra_window_ms 180_000

  @doc "True when an agent failure looks like the provider/network, not the model."
  @spec infrastructure?(term()) :: boolean()
  def infrastructure?(reason) do
    text = reason |> to_string() |> String.downcase()

    text != "" and
      (Enum.any?(@infra_markers, &String.contains?(text, &1)) or
         Regex.match?(~r/\bhttp 5\d\d\b/, text) or String.contains?(text, "429"))
  end

  defp reason_word(reason) do
    text = reason |> to_string() |> String.downcase()

    cond do
      String.contains?(text, "429") or String.contains?(text, "rate limit") -> "rate limit"
      Regex.match?(~r/\bhttp 5\d\d\b/, text) or String.contains?(text, "overloaded") -> "server"
      true -> "network"
    end
  end

  defp infra_exhausted?(%{infra_since: nil}), do: false
  defp infra_exhausted?(%{infra_since: since}), do: now_ms() - since > @infra_window_ms

  # The provider stayed unreachable: park the run so the watchdog can bring it
  # back on its own (spec 11 §7.4).
  defp infra_pause(state) do
    state = stop_work(state)

    message =
      "The model provider has been unreachable for over three minutes" <>
        if(state.last_error, do: " (#{state.last_error})", else: "") <>
        ". ncode probes it every 30 s and resumes this run by itself."

    # spec 60 T47: the caller keeps the flushed state, not the pre-flush one.
    finish(state, "paused", %{pause_kind: "infrastructure", pause_message: message})
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  # Spec 54 §1.5 (54a E1): a `log`, a `phase` and every budget charge rewrote
  # the whole `logs` JSON column (up to 500 lines ≈ 30 KB) and broadcast the
  # whole `%Workflows.Run{}` — `workflow_runs` UPDATE averaged 41.8 ms of query
  # time in the burst, the slowest write class after `BEGIN`. The lines
  # accumulate in memory and the column is written at most once a second, and
  # on finish.
  @log_write_ms 1_000

  defp log_line(state, text) do
    line = %{
      "n" => state.log_n,
      "at" => DateTime.to_iso8601(DateTime.utc_now()),
      "text" => String.slice(text, 0, 500)
    }

    # spec 68 T31: prepend to avoid O(n^2) list append; reversed in write_logs
    %{state | pending_logs: [line | state.pending_logs], log_n: state.log_n + 1}
    |> maybe_write_logs()
  end

  # spec 74 UI-SPEED-15: the next number after the persisted lines; legacy
  # lines without "n" count by position.
  @doc false
  def next_log_n(logs) when is_list(logs) do
    numbered = for %{"n" => n} when is_integer(n) <- logs, do: n
    if numbered == [], do: length(logs) + 1, else: max(Enum.max(numbered), length(logs)) + 1
  end

  def next_log_n(_logs), do: 1

  # spec 68 T31: the empty-list clause is unreachable because log_line always
  # prepends before calling this; kept only in write_logs/1 which the timer hits.
  defp maybe_write_logs(state) do
    if now_ms() - state.logs_written_at >= @log_write_ms do
      write_logs(state)
    else
      if state.logs_timer,
        do: state,
        else: %{state | logs_timer: Process.send_after(self(), :flush_logs, @log_write_ms)}
    end
  end

  @doc false
  # `state.wf.logs` stays the value the row holds, so the changeset always has
  # something to write and the pending lines are what it adds.
  def write_logs(%{pending_logs: []} = state), do: cancel_log_timer(state)

  def write_logs(state) do
    # spec 68 T31: reverse the prepend-accumulated pending_logs before persisting
    logs = Enum.take(state.wf.logs ++ Enum.reverse(state.pending_logs), -@max_logs)

    state
    |> cancel_log_timer()
    |> Map.put(:pending_logs, [])
    |> Map.put(:logs_written_at, now_ms())
    |> update_wf(%{logs: logs})
  end

  defp cancel_log_timer(%{logs_timer: nil} = state), do: state

  defp cancel_log_timer(state) do
    Process.cancel_timer(state.logs_timer)
    %{state | logs_timer: nil}
  end

  defp mismatch_message(seq) do
    "journal mismatch at call #{seq} — the script or args changed; launch a new run"
  end

  # ------------------------------------------------------------------ script end

  @impl true
  def handle_info({:script_finished, outcome}, state), do: handle_outcome(outcome, state)

  # Spec 54 §1.5 (54a E1): the lines buffered since the last write.
  def handle_info(:flush_logs, state),
    do: {:noreply, state |> Map.put(:logs_timer, nil) |> write_logs()}

  def handle_info({ref, _value}, %{script: %Task{ref: ref}} = state), do: {:noreply, state}

  # Spec 51 §7.7 (M8): `API.bound_heap/0` killed the script at 512 MB. It is a
  # bounded failure of one run, not a crash worth an inspected reason.
  def handle_info({:DOWN, ref, :process, _pid, :killed}, %{script: %Task{ref: ref}} = state) do
    if state.finished?,
      do: {:noreply, state},
      else: handle_outcome({:failed, API.heap_error()}, state)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{script: %Task{ref: ref}} = state) do
    if state.finished? or reason == :normal do
      {:noreply, state}
    else
      handle_outcome({:failed, "the workflow script crashed: " <> inspect(reason)}, state)
    end
  end

  # Spec 51 §4.4: an exit signal from anything but the parent (which GenServer
  # answers itself) still ends the runner — through `terminate/2`, so the
  # script dies with it — instead of being swallowed as a message.
  def handle_info({:EXIT, _from, reason}, state) when reason != :normal,
    do: {:stop, reason, state}

  def handle_info(_other, state), do: {:noreply, state}

  defp handle_outcome(_outcome, %{finished?: true} = state), do: {:noreply, state}

  # spec 60 T47: every terminal clause keeps the state `finish/3` flushed.
  defp handle_outcome({:complete, value}, state) do
    case safe_encode(value) do
      {:ok, json} ->
        state = finish(state, "done", %{result: json})
        {:noreply, %{state | finished?: true}, {:continue, :shutdown}}

      {:error, message} ->
        handle_outcome({:failed, "the workflow result is not storable: " <> message}, state)
    end
  end

  defp handle_outcome({:pause, kind, message}, state) do
    state = stop_work(state)
    state = finish(state, "paused", %{pause_kind: kind, pause_message: message})
    {:noreply, %{state | finished?: true}, {:continue, :shutdown}}
  end

  defp handle_outcome({:await_user, question, options, _seq, _slot}, state) do
    state = stop_work(state)

    state =
      finish(state, "waiting_user", %{
        gate_question: question,
        gate_options: options,
        pause_kind: nil,
        pause_message: nil
      })

    {:noreply, %{state | finished?: true}, {:continue, :shutdown}}
  end

  defp handle_outcome({:failed, message}, state) do
    # Spec 51 §5.12: the failure is in the run's log too, not only in the
    # pause message the card shows.
    state =
      state |> stop_work() |> log_line("failed: " <> (message |> String.split("\n") |> hd()))

    state = finish(state, "failed", %{pause_message: message})
    {:noreply, %{state | finished?: true}, {:continue, :shutdown}}
  end

  defp stop_work(state) do
    if state.script, do: Task.shutdown(state.script, :brutal_kill)
    stop_panel_tasks(state.panel_tasks)
    RunServer.stop_workers(state.run_id)
    %{state | script: nil, panel_tasks: MapSet.new()}
  end

  @impl true
  def terminate(_reason, state) do
    # Spec 54 §1.5: whatever is still buffered belongs in the row.
    write_logs(state)
    # Spec 51 §4.4: a script mid-`Enum.reduce` never reaches a receive; a
    # second of grace is a wait for nothing.
    if state.script, do: Task.shutdown(state.script, :brutal_kill)
    stop_panel_tasks(state.panel_tasks)
    :ok
  end

  defp stop_panel_tasks(tasks) do
    Enum.each(tasks, fn pid ->
      case Task.Supervisor.terminate_child(SwarmCode.Domain.TaskSupervisor, pid) do
        :ok -> :ok
        {:error, :not_found} -> if Process.alive?(pid), do: Process.exit(pid, :kill)
      end
    end)
  end

  # spec 60 T47: returns the flushed state — `terminate/2` used to write the logs
  # again from the stale one, re-broadcasting a `running` wf after `done`.
  defp finish(state, status, attrs) do
    state = write_logs(state)
    # spec 74 BUGS-20: attrs a busy database deferred (`update_wf/2`) are
    # written in the finish transaction, not dropped.
    RunServer.workflow_finished(state.run_id, status, Map.merge(state.pending_wf, attrs))
    state
  end

  # ------------------------------------------------------------------ journal

  # spec 55 T10 (55a A3): `{:ok, state}` or `{:error, :database_busy}` — never a bang.
  # spec 74 BUGS-16: or `{:error, {:not_encodable, message}}`.
  defp journal_insert(state, seq, slot, kind, fingerprint, value) do
    case encode_result(value) do
      {:ok, json} -> journal_insert_json(state, seq, slot, kind, fingerprint, json)
      {:error, message} -> {:error, {:not_encodable, message}}
    end
  end

  defp journal_insert_json(state, seq, slot, kind, fingerprint, json) do
    case Workflows.insert_journal(%{
           run_id: state.run_id,
           seq: seq,
           slot: slot,
           kind: kind,
           fingerprint: fingerprint,
           result: json,
           inserted_at: DateTime.utc_now()
         }) do
      {:ok, entry} ->
        # spec 74 EFFICIENCY-49: a live entry is never replayed by this
        # Runner (the seq only moves on), so only what the journal is still
        # read for stays: kind, fingerprint and keys — and a panel's count.
        {:ok, %{state | journal: Map.put(state.journal, {seq, slot}, slim(entry))}}

      {:error, :database_busy} ->
        {:error, :database_busy}

      {:error, changeset} ->
        raise "journal changeset: #{inspect(changeset.errors)}"
    end
  end

  # The `result` blob goes once nothing reads it; the `panel` count stays
  # (`Workflows.admitted/1`, `panel_replay_count/1`).
  defp slim(%{kind: "panel"} = entry), do: entry
  defp slim(entry), do: %{entry | result: nil}

  # A replayed entry has handed its result to the script: keep the rest.
  defp consumed(state, key) do
    case state.journal do
      %{^key => entry} -> %{state | journal: Map.put(state.journal, key, slim(entry))}
      _none -> state
    end
  end

  defp encode_result(nil), do: {:ok, Jason.encode!(%{"ok" => false, "error" => "no result"})}
  defp encode_result(value), do: safe_json(%{"ok" => true, "value" => encodable(value)})

  defp decode_result(nil), do: nil

  defp decode_result(json) do
    case Jason.decode(json) do
      {:ok, %{"ok" => true, "value" => value}} -> value
      _ -> nil
    end
  end

  @doc false
  def encode(value), do: Jason.encode!(encodable(value))

  @doc """
  `encode/1` that never raises (spec 74 BUGS-16): `{:ok, json}` or
  `{:error, message}` for a value JSON cannot hold (a pid, a ref, a fun, a
  binary that is not valid UTF-8).
  """
  @spec safe_encode(term()) :: {:ok, String.t()} | {:error, String.t()}
  def safe_encode(value), do: safe_json(encodable(value))

  defp safe_json(value) do
    case Jason.encode(value) do
      {:ok, json} -> {:ok, json}
      {:error, e} -> {:error, Exception.message(e) |> String.slice(0, 300)}
    end
  rescue
    e in [Protocol.UndefinedError] -> {:error, Exception.message(e) |> String.slice(0, 300)}
  end

  @doc false
  def encodable(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: to_string(value)

  def encodable(value) when is_tuple(value), do: value |> Tuple.to_list() |> encodable()
  def encodable(value) when is_list(value), do: Enum.map(value, &encodable/1)
  def encodable(%{__struct__: _} = value), do: inspect(value)

  def encodable(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {to_string(k), encodable(v)} end)

  def encodable(value), do: value

  # ------------------------------------------------------------------ wf row

  defp update_wf(state, attrs) do
    attrs = Map.merge(state.pending_wf, attrs)

    case Workflows.update_run(state.wf, attrs) do
      {:ok, wf} ->
        # Spec 51 §5.9 (e): the lists hear about status transitions from
        # `finish_workflow/3` → `Workflows.broadcast/2`; a phase or an admission
        # reaches the open pages as `{:workflow_updated, wf}` and nothing else.
        # Spec 74 EFFICIENCY-47: without the script and its args, which never
        # change during a run (the subscribers keep the ones they hold).
        Events.broadcast(state.conversation_id, {:workflow_updated, Workflows.wire_row(wf)})
        %{state | wf: wf, pending_wf: %{}}

      # spec 55 T10 (55a A3): the attrs wait for the next write; the process lives.
      {:error, :database_busy} ->
        Logger.warning(
          "swarm_code: workflow #{state.run_id} row busy, #{map_size(attrs)} attrs deferred"
        )

        %{state | wf: struct(state.wf, attrs), pending_wf: attrs}

      {:error, changeset} ->
        Logger.error("swarm_code db write failed: #{inspect(changeset.errors)}")
        state
    end
  end
end
