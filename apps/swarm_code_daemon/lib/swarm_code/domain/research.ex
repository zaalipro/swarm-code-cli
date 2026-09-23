defmodule SwarmCode.Domain.Research do
  @moduledoc """
  Deep research: the rows, the directories and the launch path (spec 24 §2.3).

  A research is standalone — it belongs to no conversation the user can see, and
  its integer id is the handle everything else uses (`/deep_research 2`, the
  directory name, the report file).
  """
  import Ecto.Query, warn: false, except: [update: 2, update: 3]

  alias SwarmCode.Domain.Repo
  alias SwarmCode.Domain.Research.{Events, Levels, Step}
  alias SwarmCode.Domain.Research.Research, as: Row

  require Logger

  @default_root "~/.swarmcode/research"

  # ------------------------------------------------------------------ paths

  @doc "Where every research directory lives. Overridable in tests."
  @spec root_dir() :: String.t()
  def root_dir do
    :swarm_code_daemon
    |> Application.get_env(:research_root, @default_root)
    |> Path.expand()
  end

  @spec dir(integer() | Row.t()) :: String.t()
  def dir(%Row{id: id}), do: dir(id)
  def dir(id), do: Path.join(root_dir(), to_string(id))

  @spec result_path(integer() | Row.t()) :: String.t()
  def result_path(research), do: Path.join(dir(research), "result.md")

  @spec sources_path(integer() | Row.t()) :: String.t()
  def sources_path(research), do: Path.join(dir(research), "sources.json")

  @spec report_path(integer() | Row.t()) :: String.t()
  def report_path(research), do: Path.join(dir(research), "report.html")

  @doc "Creates `<root>/<id>` and returns it."
  @spec ensure_dir!(integer() | Row.t()) :: String.t()
  def ensure_dir!(research) do
    path = dir(research)
    File.mkdir_p!(path)
    path
  end

  # ------------------------------------------------------------------ reads

  @doc """
  Researches, newest first. `:status` takes a name or a list of names,
  `:project_id` filters by tag, `:level` by level, `:limit` caps the rows.
  """
  @spec list(keyword()) :: [Row.t()]
  def list(opts \\ []) do
    Row
    |> filter_status(opts[:status])
    |> filter_project(opts[:project_id])
    |> filter_level(opts[:level])
    |> filter_design_state(opts[:design_state])
    # Spec 41 §1.0: pinned first. SQLite orders NULL below every value, so a
    # DESC sort puts the pinned rows (a timestamp) above the unpinned (NULL)
    # without a `NULLS LAST` clause, which older SQLite builds do not parse.
    |> order_by([r], desc: r.pinned_at, desc: r.inserted_at, desc: r.id)
    |> maybe_limit(opts[:limit])
    |> Repo.all()
  end

  defp filter_level(query, nil), do: query
  defp filter_level(query, level), do: where(query, [r], r.level == ^level)

  defp filter_status(query, nil), do: query
  defp filter_status(query, status) when is_binary(status), do: filter_status(query, [status])
  defp filter_status(query, statuses), do: where(query, [r], r.status in ^statuses)

  defp filter_project(query, nil), do: query
  defp filter_project(query, id), do: where(query, [r], r.project_id == ^id)

  # Spec 51 §4.6: the boot sweep asks for the rows still "designing".
  defp filter_design_state(query, nil), do: query
  defp filter_design_state(query, state), do: where(query, [r], r.design_state == ^state)

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, n), do: limit(query, ^n)

  @doc "A research by id; accepts the integer or the string a URL carries."
  @spec get(integer() | String.t() | nil) :: Row.t() | nil
  def get(nil), do: nil

  def get(id) when is_binary(id) do
    case Integer.parse(String.trim(id)) do
      {int, ""} -> get(int)
      _other -> nil
    end
  end

  def get(id) when is_integer(id), do: Repo.get(Row, id)
  def get(_id), do: nil

  @doc "How many researches are running right now (the rail badge)."
  @spec running_count() :: non_neg_integer()
  def running_count,
    do: Repo.aggregate(from(r in Row, where: r.status in ["queued", "running"]), :count)

  @doc "The steps of a research, in order."
  @spec steps(integer()) :: [Step.t()]
  def steps(research_id),
    do: Repo.all(from(s in Step, where: s.research_id == ^research_id, order_by: s.index))

  @doc "The steps of several researches at once, keyed by research id (one query)."
  @spec steps_for([integer()]) :: %{integer() => [Step.t()]}
  def steps_for([]), do: %{}

  def steps_for(ids) do
    from(s in Step, where: s.research_id in ^ids, order_by: [s.research_id, s.index])
    |> Repo.all()
    |> Enum.group_by(& &1.research_id)
  end

  @terminal ~w(done failed stopped)

  @doc """
  What a research has done so far, without its nodes (spec 39 §3.0): the
  current round, the planned and reported agents of that round, and a percent
  the list rows and the rail panel can draw.

  `percent` counts completed rounds plus the current round's reported share,
  over `steps_total`, up to 90; the report is the last ten. `phase` is
  `:queued`, `:planning` until the lead's tasks land, `:working` while agents
  are out, `:reporting` once the last round closed, `:done` for any terminal
  status.
  """
  @spec progress(Row.t(), [Step.t()], keyword()) :: %{
          round: non_neg_integer(),
          rounds: pos_integer(),
          planned: non_neg_integer(),
          reported: non_neg_integer(),
          percent: 0..100,
          phase: :queued | :planning | :working | :reporting | :done,
          alive: boolean()
        }
  def progress(%Row{} = research, steps, opts \\ []) do
    rounds = max(research.steps_total || 1, 1)
    round = research.step || 0
    current = Enum.find(steps, &(&1.index == round))
    planned = if current, do: length(current.tasks || []), else: 0
    reported = if current, do: length(current.notes || []), else: 0
    closed? = current != nil and current.status in ["done", "failed"]
    completed = steps |> Enum.count(&(&1.status in ["done", "failed"])) |> min(rounds)

    phase =
      cond do
        research.status == "queued" -> :queued
        research.status in @terminal -> :done
        closed? and round >= rounds -> :reporting
        closed? or planned == 0 -> :planning
        true -> :working
      end

    # Spec 40 §1.5: inside a round the bar also moves on the clock — up to
    # 60 % of a typical round — so ten quiet minutes never read as stuck.
    by_time =
      if closed? or planned == 0 or is_nil(current) or is_nil(current.started_at) do
        0
      else
        now = Keyword.get(opts, :now) || DateTime.utc_now()
        round_ms = Keyword.get(opts, :round_ms) || round_ms(research.level)
        elapsed = DateTime.diff(now, current.started_at, :millisecond)
        min(0.6, elapsed / max(round_ms, 1))
      end

    by_notes = if closed? or planned == 0, do: 0, else: reported / planned
    share = max(by_notes, by_time)

    percent =
      if research.status == "done",
        do: 100,
        else: ((completed + share) / rounds * 90) |> trunc() |> min(100)

    %{
      round: round,
      rounds: rounds,
      planned: planned,
      reported: reported,
      percent: percent,
      phase: phase,
      alive: by_time > by_notes
    }
  end

  # Spec 40 §1.5: the clock share needs a typical round. The history the level
  # cards already read (`estimate/1`) gives a whole research's median wall
  # time; a round is that over rounds + one for the report. No history: 3 min.
  @default_round_ms 180_000

  # Spec 47 §2.7: a Fastest round is a minute, not three. With the deep default
  # the bar would creep at a third of the real pace for the whole first run of
  # a level that is over before the estimate would have reached halfway.
  @fast_round_ms 60_000

  @doc "A typical round of a level in milliseconds, from the finished history (spec 40 §1.5)."
  @spec round_ms(String.t() | nil) :: pos_integer()
  def round_ms(level), do: round_ms_from_estimate(level, estimate(level))

  # spec 68 T33: factored out so round_ms_by_level can reuse a precomputed estimate map
  defp round_ms_from_estimate(level, est) do
    case est do
      %{ms: ms} when is_integer(ms) and ms > 0 -> max(div(ms, Levels.steps(level) + 1), 30_000)
      _other -> if Levels.fast?(level), do: @fast_round_ms, else: @default_round_ms
    end
  end

  @doc "Every level's typical round, for a page that draws many bars."
  @spec round_ms_by_level() :: %{String.t() => pos_integer()}
  def round_ms_by_level, do: round_ms_by_level(estimates())

  @doc "Derives round_ms from a precomputed estimates map (spec 68 T33)."
  @spec round_ms_by_level(map()) :: %{String.t() => pos_integer()}
  def round_ms_by_level(est_map) do
    Map.new(Levels.names(), fn level ->
      {level, round_ms_from_estimate(level, Map.get(est_map, level, %{runs: 0}))}
    end)
  end

  @doc """
  The median cost and wall time of the last eight finished researches of a
  level (spec 39 §3.1.1), or `%{runs: 0}` when there are none. A run with no
  cost is skipped for the cost, not for the count.
  """
  @spec estimate(String.t()) :: %{
          runs: non_neg_integer(),
          cost: float() | nil,
          ms: non_neg_integer() | nil
        }
  def estimate(level) do
    case list(status: "done", level: level, limit: 8) do
      [] ->
        %{runs: 0}

      rows ->
        costs = for %Row{cost_usd: cost} <- rows, is_number(cost), do: cost * 1.0

        times =
          for %Row{started_at: %DateTime{} = from, finished_at: %DateTime{} = to} <- rows,
              do: DateTime.diff(to, from, :millisecond)

        ms = if median = median(times), do: round(median)
        %{runs: length(rows), cost: median(costs), ms: ms}
    end
  end

  @doc "Every level's estimate, for the level cards."
  @spec estimates() :: %{String.t() => map()}
  def estimates, do: Map.new(Levels.names(), &{&1, estimate(&1)})

  # spec 68 T35: single public median/1, returning nil for []; Program uses || 0.
  @doc false
  def median([]), do: nil

  def median(values) do
    sorted = Enum.sort(values)
    n = length(sorted)

    if rem(n, 2) == 1,
      do: Enum.at(sorted, div(n, 2)),
      else: (Enum.at(sorted, div(n, 2) - 1) + Enum.at(sorted, div(n, 2))) / 2
  end

  # spec 68 T36: canonical quality/rating normalization (string/number/nil -> 0..5 int).
  # Delegates from Program, HtmlRender, ResearchLive and ResearchComponents.
  @doc false
  @spec rating(term()) :: 0..5
  def rating(q) when is_integer(q), do: q |> max(0) |> min(5)
  def rating(q) when is_float(q), do: rating(round(q))

  def rating(q) when is_binary(q) do
    case Integer.parse(q) do
      {int, _} -> rating(int)
      :error -> 0
    end
  end

  def rating(_q), do: 0

  @doc "`result.md`, or `{:error, reason}` when it is not there yet."
  @spec read_result(Row.t()) :: {:ok, String.t()} | {:error, String.t()}
  def read_result(%Row{} = research) do
    case File.read(research.result_path || result_path(research)) do
      {:ok, text} -> {:ok, text}
      {:error, reason} -> {:error, to_string(:file.format_error(reason))}
    end
  end

  # ------------------------------------------------------------------ writes

  @doc """
  Inserts a queued research and creates its directory. `steps_total` and
  `fanout` are frozen from the level here (see `Row.changeset/2`).
  """
  @spec create(map()) :: {:ok, Row.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    attrs = Map.put_new(attrs, "level", Levels.default())

    case %Row{} |> Row.changeset(attrs) |> Repo.insert() do
      {:ok, research} ->
        # Spec 39 §1.3: an id can be reused after a database reset, and a stale
        # result.md or report.html from the previous #<id> must never pass as
        # this research's output.
        remove_dir(research)
        path = ensure_dir!(research)

        {:ok, research} =
          research
          |> Row.changeset(%{dir: path, result_path: Path.join(path, "result.md")})
          |> Repo.update()

        Events.broadcast(research.id, {:research_updated, research})
        {:ok, research}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @spec update(Row.t(), map()) :: {:ok, Row.t()} | {:error, Ecto.Changeset.t()}
  def update(%Row{} = research, attrs) do
    case research |> Row.changeset(attrs) |> Repo.update() do
      {:ok, updated} ->
        # Spec 39 §1.7: a step or token write must not nudge every page's badge.
        status? = Map.has_key?(attrs, :status) or Map.has_key?(attrs, "status")
        Events.broadcast(updated.id, {:research_updated, updated}, ui: status?)
        {:ok, updated}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc "Updates by id, quietly doing nothing when the row is gone."
  @spec update_id(integer(), map()) :: {:ok, Row.t()} | :error
  def update_id(id, attrs) do
    case get(id) do
      nil -> :error
      research -> with {:ok, updated} <- update(research, attrs), do: {:ok, updated}
    end
  end

  @doc "Inserts or updates step `index` of a research and broadcasts it."
  @spec upsert_step(integer(), pos_integer(), map()) :: {:ok, Step.t()}
  def upsert_step(research_id, index, attrs) do
    step =
      Repo.one(from(s in Step, where: s.research_id == ^research_id and s.index == ^index)) ||
        %Step{}

    attrs = Map.merge(%{research_id: research_id, index: index}, atomize(attrs))

    {:ok, step} = step |> Step.changeset(attrs) |> Repo.insert_or_update()
    Events.broadcast(research_id, {:research_step, step}, ui: false)
    {:ok, step}
  end

  @doc """
  Appends one worker's note to step `index` and broadcasts the step (spec 40
  §1.5). Called from the Program process only, so the read-modify-write is
  serial.
  """
  @spec append_note(integer(), pos_integer(), map()) :: {:ok, Step.t()}
  def append_note(research_id, index, note) do
    # Spec 51 §5.15: one read, one UPDATE of `notes` — `upsert_step/3` read the
    # row a second time.
    step = Repo.one!(from(s in Step, where: s.research_id == ^research_id and s.index == ^index))
    write_step(step, %{notes: (step.notes || []) ++ [note]})
  end

  @doc "Step `index` of a research, or nil."
  @spec step(integer(), pos_integer()) :: Step.t() | nil
  def step(research_id, index),
    do: Repo.one(from(s in Step, where: s.research_id == ^research_id and s.index == ^index))

  defp write_step(%Step{} = step, attrs) do
    {:ok, step} = step |> Step.changeset(atomize(attrs)) |> Repo.update()
    Events.broadcast(step.research_id, {:research_step, step}, ui: false)
    {:ok, step}
  end

  defp atomize(attrs) do
    Map.new(attrs, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} -> {k, v}
    end)
  end

  # ------------------------------------------------------------------ lifecycle

  @doc """
  Starts a research: the supervisor owns it from here, and the row flips to
  `running` inside the server.
  """
  @spec start(Row.t()) :: {:ok, pid()} | {:error, term()}
  def start(%Row{} = research) do
    case SwarmCode.Domain.Research.Supervisor.start_research(research.id) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, reason} = error ->
        Logger.error("swarm_code could not start research #{research.id}: #{inspect(reason)}")

        update(research, %{
          status: "failed",
          error: "could not start: " <> String.slice(inspect(reason), 0, 200),
          finished_at: now()
        })

        error
    end
  end

  @doc """
  Runs the HTML pass again over the `result.md` already on disk (spec 26 §5.2).

  It borrows the same process tree in `:report` mode, so nothing about the row —
  status, step, run_id, timings — moves; only `report_path` can change.
  """
  @spec build_report(integer()) :: :ok | {:error, :no_result | :busy | term()}
  def build_report(id) do
    cond do
      SwarmCode.Domain.Research.Server.whereis(id) ->
        {:error, :busy}

      is_nil(get(id)) ->
        {:error, :no_result}

      not File.exists?(result_path(id)) ->
        {:error, :no_result}

      true ->
        case SwarmCode.Domain.Research.Supervisor.start_research(id, :report) do
          {:ok, _pid} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Whether a finished research of this level starts the designed HTML pass by
  itself (spec 48 §2). `"deep"` (the default) leaves Fastest manual.
  """
  @spec auto_design?(String.t() | nil, map() | nil) :: boolean()
  def auto_design?(level, settings) do
    case Map.get(settings || %{}, :research_auto_design, "deep") do
      "all" -> true
      "never" -> false
      _deep -> not Levels.fast?(level)
    end
  end

  @doc """
  Starts the designed HTML pass in the background over a research that has just
  finished (spec 48 §2).

  The research's own `Server` is stopping as this is called and the Registry
  name is per id, so the task waits for it to go before asking
  `build_report/1` — which is the same pass the "Build the designed report"
  button runs, on the same `result.md`, off the critical path.
  """
  @spec design_later(integer()) :: :ok
  def design_later(id) do
    Task.Supervisor.start_child(SwarmCode.Domain.TaskSupervisor, fn -> design_now(id) end)
    :ok
  end

  # 5 s of 50 ms polls: the server it is waiting for is already terminating.
  @design_wait_ms 5_000

  defp design_now(id, waited \\ 0) do
    cond do
      is_nil(SwarmCode.Domain.Research.Server.whereis(id)) ->
        # The row is marked `designing` only once the pass has actually started:
        # the server is registered by then, so a `Research.stop/1` between the
        # two finds it and can cancel the design (spec 48 §2).
        case build_report(id) do
          :ok ->
            update_id(id, %{design_state: "designing"})
            :ok

          {:error, reason} ->
            Logger.info(
              "swarm_code research #{id}: the designed pass did not start: #{inspect(reason)}"
            )

            update_id(id, %{design_state: "failed"})
            :ok
        end

      waited >= @design_wait_ms ->
        Logger.info("swarm_code research #{id}: gave up waiting to start the designed pass")
        :ok

      true ->
        Process.sleep(50)
        design_now(id, waited + 50)
    end
  end

  @doc "Creates and immediately starts a research."
  @spec launch(map()) :: {:ok, Row.t()} | {:error, Ecto.Changeset.t() | term()}
  def launch(attrs) do
    with {:ok, research} <- create(attrs),
         {:ok, _pid} <- start(research) do
      {:ok, get(research.id) || research}
    end
  end

  @doc """
  A new research with the same question, level and tag as an old one (spec 39
  §3.2.2). Spec 40 §1.2: `override` replaces the old row's model (`nil` keeps
  it; `:default` clears it back to Settings).
  """
  @spec retry(integer(), map() | nil | :default) :: {:ok, Row.t()} | {:error, term()}
  def retry(id, override \\ nil) do
    case get(id) do
      nil ->
        {:error, :not_found}

      %Row{} = old ->
        model =
          case override do
            :default ->
              %{"provider_id" => nil, "model" => nil, "effort" => nil}

            nil ->
              %{"provider_id" => old.provider_id, "model" => old.model, "effort" => old.effort}

            %{} = o ->
              %{"provider_id" => o[:provider_id], "model" => o[:model], "effort" => o[:effort]}
          end

        launch(
          Map.merge(
            %{"question" => old.question, "level" => old.level, "project_id" => old.project_id},
            model
          )
        )
    end
  end

  @doc """
  Pins an unpinned research, unpins a pinned one (spec 41 §1.0). The column is
  both the flag and the sort key, so `list/1` re-orders off the same write and
  every open page picks the row up from `{:research_updated, …}`.
  """
  @spec toggle_pin(integer() | String.t()) :: {:ok, Row.t()} | {:error, term()}
  def toggle_pin(id) do
    case get(id) do
      nil -> {:error, :not_found}
      %Row{} = r -> update(r, %{pinned_at: if(r.pinned_at, do: nil, else: now())})
    end
  end

  @doc """
  Stops a running research; a row with no live server is marked stopped and,
  spec 39 §1.2 (F13), its run — if one is still alive — is closed with it.
  """
  @spec stop(integer()) :: :ok
  def stop(id) do
    case SwarmCode.Domain.Research.Server.whereis(id) do
      nil ->
        case get(id) do
          %Row{status: status} = research when status in ["queued", "running"] ->
            if research.run_id, do: SwarmCode.Domain.Engine.stop_run(research.run_id)
            update(research, %{status: "stopped", finished_at: now()})
            :ok

          # Spec 48 §2: a finished research whose designed pass is gone without
          # having landed offers the button again rather than saying
          # "designing…" for ever.
          %Row{design_state: "designing"} = research ->
            restore_rendered(research)
            :ok

          _other ->
            :ok
        end

      _pid ->
        SwarmCode.Domain.Research.Server.stop(id)
    end
  end

  @doc "Stops the research, deletes the row (and its conversation) and removes the directory."
  @spec delete(integer()) :: :ok
  def delete(id) do
    stop(id)

    case get(id) do
      nil ->
        :ok

      research ->
        remove_dir(research)
        Repo.delete(research)
        Events.broadcast(id, {:research_deleted, id})
        :ok
    end
  end

  # The only `rm_rf` in the module, and it only ever removes `<root>/<id>`: a
  # misconfigured `:research_root` must not be able to delete anything else
  # (spec 39 §1.3).
  defp remove_dir(%Row{id: id} = research) do
    path = dir(research)

    if Path.dirname(path) == root_dir() and Path.basename(path) == Integer.to_string(id) do
      File.rm_rf(path)
    else
      Logger.warning("swarm_code research #{id}: refusing to remove #{path} (not <root>/<id>)")
    end

    :ok
  end

  @doc """
  Spec 51 §4.6: a research whose designed pass is gone keeps the report it had.
  The kept `rendered.html` goes back to `report_path/1` when no report is there,
  and the row reads `rendered` again — the button comes back, "designing…" does
  not outlive the pass.
  """
  @spec restore_rendered(Row.t()) :: {:ok, Row.t()} | {:error, Ecto.Changeset.t()}
  def restore_rendered(%Row{} = research) do
    restore_rendered_file(research)
    update(research, %{design_state: "rendered"})
  end

  # spec 60 T44: the file half on its own, for the Server's stop path — the
  # brutal-killed program task never reaches its own restore.
  @doc false
  @spec restore_rendered_file(Row.t()) :: :ok
  def restore_rendered_file(%Row{} = research) do
    path = report_path(research)
    kept = Path.join(dir(research), "rendered.html")

    if not File.exists?(path) and File.exists?(kept), do: File.rename(kept, path)
    :ok
  end

  @doc "Every research still marked running whose server is gone (boot sweep, spec 24 §3.5)."
  @spec orphans() :: [Row.t()]
  def orphans do
    for research <- list(status: ["queued", "running"]),
        is_nil(SwarmCode.Domain.Research.Server.whereis(research.id)),
        do: research
  end

  defdelegate subscribe(), to: Events
  defdelegate subscribe(id), to: Events

  # ------------------------------------------------------------------ helpers

  # Spec 25 §3.3: one report is capped, and the block of them is capped again —
  # attaching three ultra reports must not eat the whole context window.
  @report_cap 40_000
  @block_cap 100_000

  @doc """
  The context block a chat turn gets when researches are attached (spec 25 §3.3).

  Each is a header line and its `result.md`. Unknown ids and researches with no
  report are skipped silently — the composer already refused them.
  """
  @spec context_block([integer()]) :: String.t()
  def context_block([]), do: ""

  def context_block(ids) do
    ids
    |> Enum.uniq()
    |> Enum.map(&get/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&one_block/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n---\n\n")
    |> case do
      "" -> ""
      text -> cap("Attached deep research\n\n" <> text, @block_cap)
    end
  end

  defp one_block(research) do
    case read_result(research) do
      {:ok, markdown} ->
        date = research.finished_at || research.inserted_at

        header =
          "# Deep research ##{research.id} — #{research.title || fallback_title(research.question)}" <>
            " (#{research.level}, #{length(research.sources || [])} sources, #{Date.to_iso8601(DateTime.to_date(date))})"

        header <> "\n\n" <> cap(markdown, @report_cap)

      {:error, _reason} ->
        ""
    end
  end

  # spec 68 T34: byte_size pre-check is O(1); only fall through to String.slice
  # when the text might actually exceed the limit.
  defp cap(text, limit) do
    if byte_size(text) > limit do
      String.slice(text, 0, limit) <> "\n…[truncated]"
    else
      text
    end
  end

  @doc "True when a research has a report a chat can attach."
  @spec attachable?(term()) :: boolean()
  def attachable?(%Row{status: "done"} = research), do: File.regular?(result_path(research))
  def attachable?(_research), do: false

  @doc """
  Finished researches, for the composer's picker.

  spec 73 T83: filtered and ordered in SQL (`list/1`'s order: pinned first,
  then newest), paged to `@attachable_page` rows and only those are
  `stat`ed — the picker used to load 200 done rows and `File.regular?` each
  one on every keystroke inside the LiveView to keep twelve. The page is
  wider than the twelve the composer shows because rows whose `result.md`
  is gone drop out after the stat; the attach itself re-checks
  `attachable?/1`.
  """
  @attachable_page 24

  @spec attachable(String.t() | nil) :: [Row.t()]
  def attachable(query \\ nil) do
    filter = query |> to_string() |> String.trim() |> String.downcase()

    Row
    |> where([r], r.status == "done")
    |> filter_attachable(filter)
    |> order_by([r], desc: r.pinned_at, desc: r.inserted_at, desc: r.id)
    |> limit(@attachable_page)
    |> Repo.all()
    |> Enum.filter(&attachable?/1)
  end

  # The exact id, or a case-insensitive substring of the title or the
  # question — what `matches?/2` did in Elixir. `instr(lower(…))` rather than
  # LIKE, so a typed `%` or `_` is a character, not a wildcard.
  defp filter_attachable(query, ""), do: query

  defp filter_attachable(query, filter) do
    query =
      where(
        query,
        [r],
        fragment("instr(lower(?), ?) > 0", r.title, ^filter) or
          fragment("instr(lower(?), ?) > 0", r.question, ^filter)
      )

    case Integer.parse(filter) do
      {id, ""} -> or_where(query, [r], r.id == ^id)
      _other -> query
    end
  end

  @doc """
  A short title for a question, used until the planner names the research
  (pass 64). The first seven words with an ellipsis — the list shows the whole
  question on its second line, so the title never has to.
  """
  @spec fallback_title(String.t()) :: String.t()
  def fallback_title(question) do
    words =
      question
      |> to_string()
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
      |> String.split(" ", trim: true)

    case words do
      [] -> "Untitled research"
      words when length(words) <= 7 -> words |> Enum.join(" ") |> String.slice(0, 60)
      words -> (words |> Enum.take(7) |> Enum.join(" ") |> String.slice(0, 58)) <> "…"
    end
  end

  @doc """
  The planner's title clamped to a list entry (pass 64): at most six words and
  48 characters, no trailing full stop, surrounding quotes dropped; nil when
  the model gave nothing usable so the caller keeps what it has.
  """
  @spec short_title(String.t() | nil) :: String.t() | nil
  def short_title(text) do
    words =
      text
      |> to_string()
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
      |> String.trim("\"")
      |> String.trim_trailing(".")
      |> String.split(" ", trim: true)

    case words do
      [] -> nil
      words -> words |> Enum.take(6) |> Enum.join(" ") |> String.slice(0, 48) |> String.trim()
    end
  end

  @doc """
  A round headline, trimmed to at most ten words (spec 26 §4.1).

  The prompt asks for ten words in three places, and the host enforces it
  anyway: a model that answers with a sentence must not turn the collapsed round
  into two lines. Returns nil for anything empty, so the head falls through to
  the lead's plan title.
  """
  @spec headline(String.t() | nil) :: String.t() | nil
  def headline(text) do
    words =
      text
      |> to_string()
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
      |> String.trim_trailing(".")
      |> String.split(" ", trim: true)

    case words do
      [] -> nil
      words -> words |> Enum.take(10) |> Enum.join(" ")
    end
  end

  @doc """
  The model and effort for one tier of a research (spec 24 §3.3).

  Returns opts the `start_agent` worker branch understands: `:model_map` is an
  already-resolved `%{provider:, model:}` pair, so a research never falls into
  the *workflow* defaults on its way to the swarm ones.

  Spec 40 §1.0: `override` — `%{provider_id:, model:, effort:}` from the row,
  or nil — wins over every tier when its pair resolves; its effort (when set)
  wins over the tier's effort. An override whose provider is gone falls
  through to the tiers, and `setup/2` says so.
  """
  @spec model(:lead | :worker | :reporter, map(), map() | nil, map() | nil) :: keyword()
  def model(tier, settings, fallback \\ nil, override \\ nil) do
    {provider_id, model, effort} = tier_fields(tier, settings)

    forced = override && resolve(override[:provider_id], override[:model])

    map =
      forced ||
        resolve(provider_id, model) ||
        resolve(settings.default_swarm_provider_id, settings.default_swarm_model) ||
        fallback

    effort =
      (forced && override[:effort]) || effort || settings.default_swarm_effort || "medium"

    [model_map: map, effort: effort]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  @doc """
  What a research runs with, for chips and titles (spec 40 §1.3):
  `%{rounds:, fanout:, model:, effort:, tiers?:, gone?:}`. `model` is the row's
  override when it resolves, else the worker tier's model, else the swarm
  default; `tiers?` is true when the three tiers differ and no override
  applies; `gone?` when the override's provider was deleted.
  """
  @spec setup(Row.t(), map()) :: map()
  def setup(%Row{} = r, settings) do
    override = override(r)
    forced = override && resolve(override.provider_id, override.model)

    {model, effort} =
      if forced do
        {forced.model,
         override.effort || settings.research_worker_effort || settings.default_swarm_effort ||
           "medium"}
      else
        {settings.research_worker_model || settings.default_swarm_model || "default model",
         settings.research_worker_effort || settings.default_swarm_effort || "medium"}
      end

    tiers = [
      settings.research_lead_model,
      settings.research_worker_model,
      settings.research_reporter_model
    ]

    %{
      rounds: r.steps_total,
      fanout: r.fanout,
      model: model,
      effort: effort,
      tiers?: is_nil(forced) and length(Enum.uniq(tiers)) > 1,
      gone?: override != nil and is_nil(forced)
    }
  end

  @doc ~S'`"3 rounds × 4 agents · claude-sonnet-4 · high"` — one line for titles (spec 40 §1.3).'
  @spec setup_line(Row.t(), map()) :: String.t()
  def setup_line(%Row{} = r, settings), do: r |> setup(settings) |> setup_line()

  @doc "The same line from a `setup/2` map already at hand (spec 73 T84)."
  @spec setup_line(map()) :: String.t()
  def setup_line(%{rounds: _, fanout: _, model: _} = s) do
    model =
      s.model <>
        if(s.tiers?, do: " (+tiers)", else: "") <>
        if(s.gone?, do: " (model gone — using Settings)", else: "")

    "#{s.rounds} round#{if s.rounds == 1, do: "", else: "s"} × #{s.fanout} agents · #{model} · #{s.effort}"
  end

  @doc "The row's override as `model/4` reads it, or nil when the row has none."
  @spec override(Row.t()) :: map() | nil
  def override(%Row{provider_id: pid, model: model} = r) when is_binary(pid) and is_binary(model),
    do: %{provider_id: pid, model: model, effort: r.effort}

  def override(_research), do: nil

  defp tier_fields(:lead, s),
    do: {s.research_lead_provider_id, s.research_lead_model, s.research_lead_effort}

  defp tier_fields(:worker, s),
    do: {s.research_worker_provider_id, s.research_worker_model, s.research_worker_effort}

  defp tier_fields(:reporter, s),
    do: {s.research_reporter_provider_id, s.research_reporter_model, s.research_reporter_effort}

  # spec 73 T84: cached — this runs per list row per render tick (the list
  # re-renders each second while `@list_progress` moves); `Providers.broadcast/0`
  # drops the key on any provider write.
  defp resolve(provider_id, model) when is_binary(provider_id) and is_binary(model) do
    case SwarmCode.Domain.Providers.get_cached(provider_id) do
      nil -> nil
      provider -> %{provider: provider, model: model}
    end
  end

  defp resolve(_provider_id, _model), do: nil

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
