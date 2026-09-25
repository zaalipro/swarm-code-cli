defmodule SwarmCode.Daemon.Service.Settings.Tasks do
  @moduledoc """
  Settings tasks (pass 74, spec §3.3.8): the state a PersistedBackend keeps for
  the tasks its session started, as a value the backend holds and feeds its
  messages to.

  A task starts from a command's `{:task, spec, result}` (rule 1), at most 8 run
  at once and a new one with the same key replaces a cancellable old one (rule
  2). Its timer is a kill deadline when it is cancellable and a reporting
  deadline when it is not (rule 3). Progress is emitted at most every 250 ms
  per task (rule 5), every message and summary string is redacted (rule 6), the
  last result per key goes to the `TaskCache` (rule 7), and it stops by its kind
  (rule 8). Every function answers the new value and the `settings_task` delta
  bodies to emit; the owner turns them into deltas.

  The owner process receives `{:settings_task_progress, id, progress}`,
  `{:settings_task_emit, id}`, `{:settings_task_timeout, id, tag}`,
  `{:settings_task_purge, key, ref}` and the tasks' own `{ref, result}` and
  `:DOWN` messages; `handle/2` answers `:unknown` for anything else.
  """

  alias SwarmCode.Daemon.Service.Settings.{Error, ProbeRunner, TaskCache, TaskSpec, Wire}
  alias SwarmCode.Domain.LLM.HTTP
  alias SwarmCode.Settings.RecordKind

  require Logger

  @max_running 8
  @message_bytes 2_048
  @summary_bytes 16_384
  @emit_ms 250
  @purge_ms 600_000
  @page 200

  defstruct running: %{},
            refs: %{},
            cache: nil,
            owner: nil,
            supervisor: SwarmCode.Domain.TaskSupervisor,
            purge_ms: @purge_ms

  @type delta :: map()
  @type t :: %__MODULE__{}

  @doc """
  An empty task set owned by `owner` (the process that receives the tasks'
  messages). Options: `:supervisor`, `:purge_ms`, `:cache` (TaskCache options).
  """
  @spec new(pid(), keyword()) :: t()
  def new(owner, opts \\ []) do
    %__MODULE__{
      owner: owner,
      supervisor: Keyword.get(opts, :supervisor, SwarmCode.Domain.TaskSupervisor),
      purge_ms: Keyword.get(opts, :purge_ms, @purge_ms),
      cache: TaskCache.new(Keyword.get(opts, :cache, []))
    }
  end

  @doc "At most this many tasks run per session."
  @spec max_running() :: pos_integer()
  def max_running, do: @max_running

  @doc "The words of a ninth task."
  @spec busy_words() :: String.t()
  def busy_words, do: "Eight settings checks are already running; wait for one to finish."

  @doc "The words of a task whose key is taken by one that cannot be stopped."
  @spec still_running_words() :: String.t()
  def still_running_words, do: "That is still running; wait for it to finish."

  @doc "The words of a stop of a task that cannot be stopped."
  @spec cannot_stop_words() :: String.t()
  def cannot_stop_words, do: "this cannot be stopped once it started"

  @doc "The words of a task view whose entry is gone."
  @spec gone_words() :: String.t()
  def gone_words, do: "that result is gone; run it again"

  @doc "How many tasks run."
  @spec running_count(t()) :: non_neg_integer()
  def running_count(%__MODULE__{running: running}), do: map_size(running)

  @doc "The running tasks as `{id, action, cancellable?}` (quitting asks first, §4.8)."
  @spec running(t()) :: [{String.t(), String.t(), boolean()}]
  def running(%__MODULE__{running: running}),
    do: for({id, entry} <- running, do: {id, entry.spec.action, entry.spec.cancellable?})

  ## ------------------------------------------------------------------ start

  @doc """
  Start `spec` (rules 1–3). Answers the new set, the task id and the deltas (a
  replaced task's `cancelled` and the new one's `running`), or the refusal.
  """
  @spec start(t(), TaskSpec.t()) :: {:ok, t(), String.t(), [delta()]} | {:error, Error.t()}
  def start(%__MODULE__{} = tasks, %TaskSpec{} = spec) do
    key = cache_key(spec)

    case Enum.find(tasks.running, fn {_id, entry} -> entry.key == key end) do
      {_id, %{spec: %TaskSpec{cancellable?: false}}} ->
        {:error, Error.new(:busy, still_running_words())}

      found ->
        {tasks, replaced} =
          case found do
            {old, _entry} -> stop_as(tasks, old, "cancelled", nil)
            nil -> {tasks, []}
          end

        if running_count(tasks) >= @max_running do
          {:error, Error.new(:busy, busy_words())}
        else
          {tasks, id, started} = launch(tasks, spec, key)
          {:ok, tasks, id, replaced ++ started}
        end
    end
  end

  defp launch(tasks, spec, key) do
    id = Ecto.UUID.generate()
    now = now()
    task = run(spec, id, tasks.owner, tasks.supervisor)
    tag = make_ref()
    timer = Process.send_after(tasks.owner, {:settings_task_timeout, id, tag}, spec.timeout_ms)

    entry = %{
      id: id,
      key: key,
      spec: spec,
      task: task,
      tag: tag,
      timer: timer,
      started: now,
      state: "running",
      progress: nil,
      last_emit: now,
      emit_timer: nil,
      message: nil,
      summary: nil
    }

    tasks = %{
      tasks
      | running: Map.put(tasks.running, id, entry),
        refs: Map.put(tasks.refs, task.ref, id)
    }

    {tasks, id, [delta_body(entry, now)]}
  end

  @doc """
  Run `spec` under `supervisor` (rule 3), progress sent to `owner` as
  `{:settings_task_progress, id, progress}`. `swarmcode config` uses it too
  (rule 10).
  """
  @spec run(TaskSpec.t(), String.t(), pid(), GenServer.server()) :: Task.t()
  def run(%TaskSpec{} = spec, id, owner, supervisor) do
    report = fn progress ->
      send(owner, {:settings_task_progress, id, progress})
      :ok
    end

    case spec.kind do
      :probe -> ProbeRunner.start(supervisor, spec.run, report)
      _plain_or_file -> Task.Supervisor.async_nolink(supervisor, fn -> spec.run.(report) end)
    end
  end

  @doc "Stop a task by its kind (rule 8)."
  @spec stop(Task.t(), TaskSpec.t()) :: :ok
  def stop(%Task{} = task, %TaskSpec{kind: :probe}), do: ProbeRunner.stop(task)

  def stop(%Task{} = task, %TaskSpec{kind: :file}) do
    Task.shutdown(task, 2_000)
    :ok
  end

  def stop(%Task{} = task, %TaskSpec{}) do
    Task.shutdown(task, :brutal_kill)
    :ok
  end

  ## ---------------------------------------------------------------- messages

  @doc "Handle one of the tasks' messages; `:unknown` for anything else."
  @spec handle(t(), term()) :: {:ok, t(), [delta()]} | :unknown
  def handle(%__MODULE__{} = tasks, {:settings_task_progress, id, progress}) do
    case tasks.running[id] do
      nil ->
        {:ok, tasks, []}

      entry ->
        entry = %{entry | progress: progress}
        now = now()

        cond do
          now - entry.last_emit >= @emit_ms ->
            entry = %{entry | last_emit: now}
            {:ok, put_running(tasks, entry), [delta_body(entry, now)]}

          entry.emit_timer == nil ->
            wait = @emit_ms - (now - entry.last_emit)
            timer = Process.send_after(tasks.owner, {:settings_task_emit, id}, wait)
            {:ok, put_running(tasks, %{entry | emit_timer: timer}), []}

          true ->
            {:ok, put_running(tasks, entry), []}
        end
    end
  end

  def handle(%__MODULE__{} = tasks, {:settings_task_emit, id}) do
    case tasks.running[id] do
      nil ->
        {:ok, tasks, []}

      entry ->
        now = now()
        entry = %{entry | emit_timer: nil, last_emit: now}
        {:ok, put_running(tasks, entry), [delta_body(entry, now)]}
    end
  end

  def handle(%__MODULE__{} = tasks, {:settings_task_timeout, id, tag}) do
    case tasks.running[id] do
      %{tag: ^tag, spec: %TaskSpec{cancellable?: true} = spec} ->
        {tasks, deltas} = stop_as(tasks, id, "timeout", "no answer in #{seconds(spec)} s")
        {:ok, tasks, deltas}

      %{tag: ^tag, spec: spec} = entry ->
        # A reporting deadline (rule 3): say so, arm another, never kill.
        now = now()
        after_s = div(now - entry.started + 500, 1_000)

        timer =
          Process.send_after(tasks.owner, {:settings_task_timeout, id, tag}, spec.timeout_ms)

        entry = %{entry | timer: timer, message: "still running after #{after_s} s"}
        {:ok, put_running(tasks, entry), [delta_body(entry, now)]}

      _ ->
        {:ok, tasks, []}
    end
  end

  def handle(%__MODULE__{} = tasks, {:settings_task_purge, key, ref}),
    do: {:ok, %{tasks | cache: TaskCache.purge(tasks.cache, key, ref)}, []}

  def handle(%__MODULE__{refs: refs} = tasks, {ref, result})
      when is_reference(ref) and is_map_key(refs, ref) do
    Process.demonitor(ref, [:flush])
    {:ok, tasks, deltas} = finish(tasks, refs[ref], result)
    {:ok, tasks, deltas}
  end

  def handle(%__MODULE__{refs: refs} = tasks, {:DOWN, ref, :process, _pid, _reason})
      when is_map_key(refs, ref),
      do: finish(tasks, refs[ref], {:error, "the check stopped without an answer"})

  def handle(%__MODULE__{}, _message), do: :unknown

  ## ------------------------------------------------------------------ cancel

  @doc """
  `task.cancel` (rule 8): a running cancellable task stops (`cancelled`); one
  that is not cancellable is refused; an unknown or finished one is
  `:finished`.
  """
  @spec cancel(t(), term()) :: {:ok, t(), [delta()]} | :finished | {:error, Error.t()}
  def cancel(%__MODULE__{} = tasks, id) do
    case tasks.running[id] do
      nil ->
        :finished

      %{spec: %TaskSpec{cancellable?: false}} ->
        {:error, Error.new(:invalid, cannot_stop_words())}

      _entry ->
        {tasks, deltas} = stop_as(tasks, id, "cancelled", nil)
        {:ok, tasks, deltas}
    end
  end

  @doc """
  Stop every running task by its kind (the non-cancellable ones too, rule 9),
  cancel every timer, and forget the cache. Used by the owner's `terminate/2`.
  """
  @spec terminate(t()) :: :ok
  def terminate(%__MODULE__{} = tasks) do
    for {_id, entry} <- tasks.running do
      cancel_timers(entry)
      Process.demonitor(entry.task.ref, [:flush])
      stop(entry.task, entry.spec)
    end

    for {_key, timer} <- TaskCache.purge_timers(tasks.cache), do: Process.cancel_timer(timer)
    :ok
  end

  defp stop_as(tasks, id, state, message) do
    entry = tasks.running[id]
    cancel_timers(entry)
    Process.demonitor(entry.task.ref, [:flush])
    stop(entry.task, entry.spec)

    entry = %{entry | state: state, message: message}
    now = now()
    tasks = forget(tasks, entry)
    tasks = cache(tasks, entry, nil)
    {tasks, [delta_body(entry, now)]}
  end

  defp finish(tasks, id, result) do
    entry = tasks.running[id]
    cancel_timers(entry)
    secrets = entry.spec.redact || []

    {state, message, summary, kept} =
      case result do
        {:ok, value} ->
          {"done", nil, summary(entry.spec, value, secrets), value}

        {:error, words} ->
          {"failed", redact(words_of(words), secrets), nil, nil}

        _other ->
          {"failed", "the check stopped without an answer", nil, nil}
      end

    entry = %{entry | state: state, message: message, summary: summary}
    tasks = tasks |> forget(entry) |> cache(entry, kept)
    {:ok, tasks, [delta_body(entry, now())]}
  end

  defp words_of(words) when is_binary(words), do: words
  defp words_of(_words), do: "the check failed"

  defp forget(tasks, entry) do
    %{
      tasks
      | running: Map.delete(tasks.running, entry.id),
        refs: Map.delete(tasks.refs, entry.task.ref)
    }
  end

  defp put_running(tasks, entry), do: %{tasks | running: Map.put(tasks.running, entry.id, entry)}

  defp cancel_timers(entry) do
    Process.cancel_timer(entry.timer)
    if entry.emit_timer, do: Process.cancel_timer(entry.emit_timer)
    :ok
  end

  defp seconds(%TaskSpec{timeout_ms: ms}), do: max(div(ms + 999, 1_000), 1)

  ## ------------------------------------------------------------------- cache

  # Rule 7: the last result per key. A secrets-bearing entry keeps its result as
  # it is (an import draft applies it) and gets a purge timer; any other result
  # is redacted before it is kept.
  defp cache(tasks, entry, result) do
    spec = entry.spec
    secret? = spec.holds_secrets? == true
    {sessions, result} = sessions_of(spec.action, result)

    stored =
      %{
        task_id: entry.id,
        action: spec.action,
        target: spec.target,
        state: entry.state,
        at: DateTime.utc_now(),
        elapsed_ms: max(now() - entry.started, 0),
        summary: entry.summary,
        result: if(secret?, do: result, else: redact_all(result, spec.redact || [])),
        message: entry.message,
        secret?: secret?
      }

    timers = TaskCache.purge_timers(tasks.cache)
    {cache, evicted} = TaskCache.put(tasks.cache, entry.key, stored)
    cache = if sessions, do: elem(TaskCache.put_sessions(cache, sessions), 0), else: cache

    # The replaced entry's timer and the evicted entries' timers end here.
    for key <- [entry.key | evicted], timer = timers[key], do: Process.cancel_timer(timer)

    cache =
      if secret? do
        ref = make_ref()

        timer =
          Process.send_after(tasks.owner, {:settings_task_purge, entry.key, ref}, tasks.purge_ms)

        TaskCache.mark_purge(cache, entry.key, ref, timer)
      else
        cache
      end

    %{tasks | cache: cache}
  end

  # A storage measure's sessions go to the sessions store (rule 7b), not the LRU.
  defp sessions_of("storage.measure", %{} = result) do
    case Map.get(result, "sessions") || Map.get(result, :sessions) do
      rows when is_list(rows) -> {rows, Map.drop(result, ["sessions", :sessions])}
      _ -> {nil, result}
    end
  end

  defp sessions_of(_action, result), do: {nil, result}

  @doc """
  The cache entries a job may read (§3.3.2): for every `{action, :all}` the
  entries of that action as summaries (no result), for `{action, :target}` the
  entry of `target`, for `{action, {:param, name}}` the whole entry whose task
  id is the value of `name` in `params`; `{action, :sessions_store}` answers
  the sessions store as the second element.
  """
  @spec task_results(t(), list(), map(), map() | nil) :: {map(), list() | nil}
  def task_results(%__MODULE__{cache: cache}, declarations, params, target \\ nil) do
    Enum.reduce(declarations, {%{}, nil}, fn
      {action, :all}, {acc, store} ->
        entries =
          for {key, entry} <- TaskCache.entries_for(cache, action),
              into: %{},
              do: {key, Map.drop(entry, [:result, :purge_ref, :purge_timer, :used, :bytes])}

        {Map.merge(acc, entries), store}

      {action, :target}, {acc, store} ->
        case TaskCache.get(cache, {action, target}) do
          nil -> {acc, store}
          entry -> {Map.put(acc, {action, target}, public(entry)), store}
        end

      {action, {:param, name}}, {acc, store} ->
        with id when is_binary(id) <- param(params, name),
             {_key, %{action: ^action} = entry} <- TaskCache.find_task(cache, id) do
          {Map.put(acc, {action, id}, public(entry)), store}
        else
          _ -> {acc, store}
        end

      {_action, :sessions_store}, {acc, _store} ->
        {acc, TaskCache.sessions(cache)}

      _other, acc ->
        acc
    end)
  end

  defp public(entry), do: Map.drop(entry, [:purge_ref, :purge_timer, :used, :bytes])

  defp param(params, name) when is_map(params) do
    Map.get(params, name) ||
      get_in(params, ["attributes", name]) ||
      get_in(params, ["options", name]) ||
      case params["target"] do
        %{} = target -> Map.get(target, name)
        _ -> nil
      end
  end

  defp param(_params, _name), do: nil

  @doc "Whether the last storage measure had more sessions than the store keeps."
  @spec sessions_truncated?(t()) :: boolean()
  def sessions_truncated?(%__MODULE__{cache: cache}), do: TaskCache.sessions_truncated?(cache)

  ## -------------------------------------------------------------------- view

  @doc """
  The `task` view (§3.3.6): `id` is a task id this session started, or
  `options.action` + `options.target` names the last result of that key.
  Rows are paged 200 at a time; a gone entry is `not_found`.
  """
  @spec view(t(), map()) :: {:ok, map(), t()} | {:error, Error.t()}
  def view(%__MODULE__{} = tasks, params) do
    now = now()
    options = params["options"] || %{}

    found =
      cond do
        is_binary(params["id"]) and Map.has_key?(tasks.running, params["id"]) ->
          entry = tasks.running[params["id"]]

          {:running,
           %{
             task_id: entry.id,
             action: entry.spec.action,
             target: entry.spec.target,
             state: "running",
             elapsed_ms: max(now - entry.started, 0),
             message: entry.message,
             summary: nil,
             result: nil
           }}

        is_binary(params["id"]) ->
          TaskCache.find_task(tasks.cache, params["id"])

        is_binary(options["action"]) ->
          by_target(tasks.cache, options["action"], options["target"])

        true ->
          nil
      end

    case found do
      nil ->
        {:error, Error.new(:not_found, gone_words())}

      {:running, entry} ->
        {:ok, view_body(entry, params), tasks}

      {key, entry} ->
        {:ok, view_body(entry, params), %{tasks | cache: TaskCache.touch(tasks.cache, key)}}
    end
  end

  defp by_target(cache, action, target) do
    case TaskCache.get(cache, {action, target}) do
      nil ->
        cache
        |> TaskCache.entries_for(action)
        |> Enum.find(fn {_key, entry} -> Wire.json(entry.target) == target end)

      entry ->
        {{action, target}, entry}
    end
  end

  defp view_body(entry, params) do
    {rows, rest} = rows_of(entry.result)

    # The rest of a result is its summary, except for a result that holds
    # secrets (an MCP import's drafts): it shows only its rows and the
    # handler's own summary, which the delta carried already.
    summary = if Map.get(entry, :secret?) == true, do: entry.summary, else: rest || entry.summary
    size = min(positive(params["page_size"]) || @page, @page)
    start = cursor(params["cursor"])
    total = length(rows)
    slice = rows |> Enum.drop(start) |> Enum.take(size)
    next = if start + size < total, do: Integer.to_string(start + size)

    %{
      "task_id" => entry.task_id,
      "action" => entry.action,
      "target" => Wire.json(entry.target),
      "state" => entry.state,
      "elapsed_ms" => Map.get(entry, :elapsed_ms, 0),
      "message" => entry.message,
      "result" =>
        if entry.state == "running" do
          nil
        else
          %{
            "summary" => Wire.json(summary),
            "rows" => Wire.json(slice),
            "next_cursor" => next,
            "total" => total
          }
        end
    }
  end

  defp rows_of(%{"rows" => rows} = result) when is_list(rows),
    do: {rows, result |> Map.delete("rows") |> public_keys()}

  defp rows_of(%{rows: rows} = result) when is_list(rows),
    do: {rows, result |> Map.delete(:rows) |> public_keys()}

  defp rows_of(rows) when is_list(rows), do: {rows, nil}
  defp rows_of(%{} = result), do: {[], public_keys(result)}
  defp rows_of(_result), do: {[], nil}

  # A result key starting with "_" is the task's own (an import preview's
  # parsed file): kept for a later command, never shown.
  defp public_keys(result),
    do: Map.reject(result, fn {key, _} -> is_binary(key) and String.starts_with?(key, "_") end)

  defp positive(n) when is_integer(n) and n > 0, do: n
  defp positive(_), do: nil

  defp cursor(text) when is_binary(text) do
    case Integer.parse(text) do
      {n, ""} when n >= 0 -> n
      _ -> 0
    end
  end

  defp cursor(_), do: 0

  @doc "The row kind of an action's rows (docs and tests)."
  @spec row_kind(String.t()) :: String.t() | nil
  def row_kind(action), do: RecordKind.task_row_kind(action)

  ## ------------------------------------------------------------ delta bodies

  @doc "The `settings_task` delta body of a task (§3.4.4): never the result."
  @spec delta_body(map(), integer()) :: map()
  def delta_body(entry, now) do
    %{
      "task_id" => entry.id,
      "action" => entry.spec.action,
      "target" => Wire.json(entry.spec.target),
      "state" => entry.state,
      "elapsed_ms" => max(now - entry.started, 0),
      "progress" => progress(entry.progress),
      "summary" => entry.summary,
      "message" => entry.message
    }
  end

  defp progress(%{} = p) do
    %{
      "done" => count(field(p, :done)),
      "total" => count(field(p, :total)),
      "bytes" => count(field(p, :bytes)),
      "step" => step(field(p, :step))
    }
  end

  defp progress(_other), do: nil

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp count(n) when is_integer(n) and n >= 0, do: n
  defp count(_), do: nil
  defp step(text) when is_binary(text), do: cut(text, 200)
  defp step(_), do: nil

  ## --------------------------------------------------------------- redaction

  @doc """
  Redact `text` (rule 6): `HTTP.redact/2` with the secrets, then
  `HTTP.redact/1`, then exact removal of any secret shorter than 8 bytes (which
  `HTTP.redact/2` skips), cut to 2 048 bytes.
  """
  @spec redact(term(), [String.t()]) :: String.t() | nil
  def redact(nil, _secrets), do: nil
  def redact(text, secrets), do: text |> redact_text(secrets) |> cut(@message_bytes)

  @doc "Every string inside `value` redacted as `redact/2` does, uncut."
  @spec redact_all(term(), [String.t()]) :: term()
  def redact_all(value, secrets) when is_binary(value), do: redact_text(value, secrets)

  def redact_all(%{} = value, secrets) when not is_struct(value),
    do: Map.new(value, fn {k, v} -> {k, redact_all(v, secrets)} end)

  def redact_all(value, secrets) when is_list(value),
    do: Enum.map(value, &redact_all(&1, secrets))

  def redact_all(value, secrets) when is_tuple(value),
    do: value |> Tuple.to_list() |> redact_all(secrets) |> List.to_tuple()

  def redact_all(value, _secrets), do: value

  defp redact_text(text, secrets) do
    secrets = for s <- secrets || [], is_binary(s) and s != "", do: s

    text
    |> to_string()
    |> HTTP.redact(secrets)
    |> HTTP.redact()
    |> remove_short(secrets)
  end

  defp remove_short(text, secrets) do
    secrets
    |> Enum.filter(&(byte_size(&1) < 8))
    |> Enum.sort_by(&(-byte_size(&1)))
    |> Enum.reduce(text, fn secret, acc -> String.replace(acc, secret, "[REDACTED]") end)
  end

  @doc "The delta summary of a result: `spec.summary.(result)`, redacted, ≤ 16 KiB encoded, else nil."
  @spec summary(TaskSpec.t(), term(), [String.t()]) :: map() | nil
  def summary(%TaskSpec{summary: fun} = spec, result, secrets) when is_function(fun, 1) do
    with %{} = summary <- fun.(result),
         summary = summary |> Wire.json() |> redact_all(secrets),
         {:ok, json} <- Jason.encode(summary),
         true <- byte_size(json) <= @summary_bytes do
      summary
    else
      _ -> nil
    end
  rescue
    _ ->
      Logger.warning("settings task summary failed: #{spec.action}")
      nil
  end

  def summary(%TaskSpec{}, _result, _secrets), do: nil

  defp cut(text, bytes) when byte_size(text) <= bytes, do: text

  defp cut(text, bytes) do
    prefix = binary_part(text, 0, bytes)
    if String.valid?(prefix), do: prefix, else: cut(prefix, bytes - 1)
  end

  ## ------------------------------------------------------------------ keys

  @doc "The cache key of a spec: its key when it names the action, else `{action, key}`."
  @spec cache_key(TaskSpec.t()) :: TaskCache.key()
  def cache_key(%TaskSpec{action: action, key: {action, _} = key}), do: key
  def cache_key(%TaskSpec{action: action, key: key}), do: {action, key}

  defp now, do: System.monotonic_time(:millisecond)

  defimpl Inspect do
    def inspect(tasks, _opts) do
      "#SwarmCode.Daemon.Service.Settings.Tasks<running: #{map_size(tasks.running)} " <>
        "cache: #{Kernel.inspect(tasks.cache)}>"
    end
  end
end
