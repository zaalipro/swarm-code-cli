defmodule SwarmCode.Domain.Workflows.API do
  @moduledoc """
  The functions a workflow program may call (spec 09 §3).

  Every one of them talks to the run's Runner through the process dictionary key
  `:swarm_code_workflow`, which the Runner sets in the script Task and in each
  panel slot Task. Calling them outside a run raises `SwarmCode.Domain.Workflows.Error`.

  `complete/1`, `await_user/2` and `pause/2` are terminal: they throw
  `{:workflow, …}`, which the Runner catches.
  """

  alias SwarmCode.Domain.Engine.RunServer
  alias SwarmCode.Domain.Workflows.{Error, Host, Schema}

  @pd :swarm_code_workflow
  # Panel slots are numbered 0..n-1; extra host calls inside a slot are pushed
  # far above any slot index so the (run_id, seq, slot) index stays unique.
  @slot_stride 1024

  # ---------------------------------------------------------------- context

  @doc false
  def context do
    case Process.get(@pd) do
      nil -> raise Error, message: "workflow API called outside a workflow run"
      ctx -> ctx
    end
  end

  @doc false
  def put_context(ctx), do: Process.put(@pd, ctx)

  # 64 M words ≈ 512 MB on 64-bit.
  @heap_words 64_000_000

  @doc """
  Bounds the calling process's heap (spec 51 §7.7, M8).

  A workflow script is model-authored and runs under a `:read` permission the
  policy auto-approves; the allow-list happily permits `List.duplicate(0,
  500_000_000)`, and the only bound was the smoke check's 5 s `Task.yield`. An
  accidental quadratic comprehension over `host(:files)` could therefore abort
  the VM and lose every running run. The script Task, the smoke Task and every
  panel slot Task call this first: the process is killed at 512 MB and its
  owner turns that into one failed run.
  """
  @spec bound_heap() :: :ok
  def bound_heap do
    Process.flag(:max_heap_size, %{size: @heap_words, kill: true, error_logger: true})
    :ok
  end

  @doc "What a run says when `bound_heap/0` killed its script."
  @spec heap_error() :: String.t()
  def heap_error, do: "the workflow script exceeded 512 MB of heap and was stopped"

  defp update_context(fun), do: Process.put(@pd, fun.(context()))

  defp in_panel?, do: context().panel != nil

  defp refuse_in_panel!(what) do
    if in_panel?(), do: raise(Error, message: "#{what} is not allowed inside a panel slot")
  end

  # ---------------------------------------------------------------- phases

  @doc "Marks the current phase. Not a host call — not journaled."
  def phase(title) do
    refuse_in_panel!("phase/1")
    ctx = context()
    GenServer.call(ctx.runner, {:phase, to_string(title)}, :infinity)
    :ok
  end

  @doc "Appends a line to the run log (capped at 500 lines)."
  def log(text) do
    ctx = context()
    GenServer.call(ctx.runner, {:log, to_string(text)}, :infinity)
    :ok
  end

  @doc "`%{total:, spent:, remaining:}` agent slots of this run."
  def budget do
    context() |> budget_reply() |> Map.take([:total, :spent, :remaining])
  end

  defp budget_reply(ctx), do: GenServer.call(ctx.runner, :budget, :infinity)

  @doc "`not is_nil(x)` — the guard every panel result should go through."
  def present?(x), do: not is_nil(x)

  # ---------------------------------------------------------------- agents

  @doc """
  Runs one child agent and returns its final text, the validated map when
  `schema:` is given, or `nil` when it failed.
  """
  def agent(prompt, opts \\ []) do
    opts = Enum.into(opts, [])
    ctx = context()

    if ctx.panel != nil do
      if ctx.agent_called?,
        do: raise(Error, message: "one agent per panel slot")

      update_context(&Map.put(&1, :agent_called?, true))
    end

    schema = opts[:schema]

    call(:agent, to_string(prompt), opts, fn value ->
      decode_agent(value, schema)
    end)
  end

  defp decode_agent(nil, _schema), do: nil

  defp decode_agent(value, nil), do: value

  defp decode_agent(value, schema) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> Schema.atomize(schema, decoded)
      _ -> nil
    end
  end

  defp decode_agent(value, schema) when is_map(value), do: Schema.atomize(schema, value)
  defp decode_agent(_value, _schema), do: nil

  # ---------------------------------------------------------------- panel

  @doc """
  The barrier: runs `fun` for every item concurrently and returns the results in
  item order (`nil` for a failed slot). The whole panel is charged against the
  agent budget before anything launches.
  """
  def panel(items, fun) when is_function(fun, 1) or is_function(fun, 2) do
    refuse_in_panel!("panel/2")
    ctx = context()
    items = Enum.take(items, panel_bound(ctx) + 1)
    count = length(items)

    {seq, max_concurrency, track_tasks?} =
      case GenServer.call(ctx.runner, {:panel_admit, count}, :infinity) do
        {:ok, seq, max_concurrency} -> {seq, max_concurrency, true}
        {:replay, seq, max_concurrency} -> {seq, max_concurrency, true}
        # Canned runners from older persisted previews do not own live tasks.
        {:ok, seq} -> {seq, max(count, 1), false}
        {:replay, seq} -> {seq, max(count, 1), false}
        {:pause, kind, message} -> throw({:workflow, {:pause, kind, message}})
      end

    parent = %{ctx | panel: nil}

    Task.Supervisor.async_stream_nolink(
      SwarmCode.Domain.TaskSupervisor,
      Enum.with_index(items),
      fn {item, index} ->
        bound_heap()
        if track_tasks?, do: GenServer.call(ctx.runner, {:panel_task, self()}, :infinity)

        try do
          put_context(%{parent | panel: %{seq: seq, slot: index}, calls: 0, agent_called?: false})

          if is_function(fun, 1), do: fun.(item), else: fun.(item, index)
        after
          if track_tasks?, do: GenServer.cast(ctx.runner, {:panel_task_done, self()})
        end
      end,
      max_concurrency: max_concurrency,
      ordered: true,
      timeout: :infinity,
      on_timeout: :kill_task,
      shutdown: 1_000
    )
    |> Stream.with_index()
    |> Enum.map(fn
      {{:ok, value}, _index} ->
        value

      # Spec 51 §5.12: an exception in a slot fails the run — a nil for it
      # used to read as "no findings". The task's exit reason is the raw error
      # (`{:badkey, :x}` for `Map.fetch!/2`, a struct only for `raise`), so it
      # is normalised first. The closure ran in its own task and the evaluator
      # leaves no `workflow.exs` frame in its stacktrace, so the message names
      # the file and the slot instead of a line. A kill (the heap bound, a
      # stop) has no stacktrace and stays a nil.
      {{:exit, {reason, stacktrace}}, index} when is_list(stacktrace) ->
        exception = Exception.normalize(:error, reason, stacktrace)

        message =
          SwarmCode.Domain.Workflows.Runner.format_error(exception, stacktrace) <>
            "\n    workflow.exs: in panel slot #{index + 1}"

        throw({:workflow, {:failed, message}})

      {{:exit, _killed_or_shutdown}, _index} ->
        nil
    end)
  end

  # How many items this panel may read, plus the one overflow sentinel the
  # caller adds. A panel that has already been admitted (a resume after a gate
  # or a pause) is bounded by *its own* recorded count: the budget was charged
  # for it on the first pass, so bounding by what is left of the budget now
  # truncated the list and turned every such resume into a journal mismatch
  # (spec 33 §2). A canned runner answers without the key and takes the live
  # path, as before.
  defp panel_bound(ctx) do
    case budget_reply(ctx) do
      %{panel_replay: count} when is_integer(count) and count >= 0 -> count
      %{remaining: remaining} -> max(remaining, 0)
    end
  end

  # ---------------------------------------------------------------- host

  @doc "Deterministic, journaled host helpers (see `SwarmCode.Domain.Workflows.Host`)."
  def host(op, opts \\ []) when is_atom(op) do
    unless op in Host.ops(),
      do: raise(Error, message: "unknown host op #{inspect(op)}")

    opts = Enum.into(opts, [])
    ctx = context()

    call(:host, op, opts, &Host.normalize(op, &1), fn -> Host.run(op, opts, ctx.root) end)
  end

  @doc """
  A stable 16-hex fingerprint of any value (spec 11 §R.2) — the blessed way to
  dedup findings (`fingerprint(file <> "::" <> issue)`) or to detect a round
  that added nothing new.
  """
  @spec fingerprint(term()) :: String.t()
  def fingerprint(value) do
    :crypto.hash(:sha256, stable(value)) |> Base.encode16(case: :lower) |> String.slice(0, 16)
  end

  defp stable(value) when is_binary(value), do: value
  defp stable(value), do: json_encode(value)

  @doc "The value as compact JSON (atoms, tuples and structs included)."
  @spec json_encode(term()) :: String.t()
  def json_encode(value), do: Jason.encode!(SwarmCode.Domain.Workflows.Runner.encodable(value))

  @doc """
  Reads a report back from the run's scratch space (or any project-relative
  path). Journaled like every other host read; missing files come back as nil.
  """
  @spec read_report(String.t()) :: String.t() | nil
  def read_report(filename) do
    ctx = context()
    name = to_string(filename)

    call(:read_report, name, [], & &1, fn ->
      # Sakana task 5: a name with a slash used to be expanded straight against
      # the root, so `../../secret` or an absolute path read any host file. It
      # now goes through the one confinement primitive; anything outside the
      # project — including a symlink target and a link cycle — reads as nil,
      # which is the contract workflows already handle.
      #
      # spec 60 T35: the basename form used to join raw, so a symlink planted in
      # the run directory followed out of the root. Both forms resolve.
      rel =
        if String.contains?(name, "/") do
          name
        else
          Path.join([
            ".swarm_code",
            "workflows",
            "runs",
            to_string(ctx.display_name),
            Path.basename(name)
          ])
        end

      with {:ok, abs} <- SwarmCode.Domain.Tools.Path.resolve(ctx.root, rel),
           {:ok, text} <- File.read(abs) do
        String.slice(text, 0, 200_000)
      else
        _ -> nil
      end
    end)
  end

  @doc """
  The error text of the most recent failed agent call of this run, or nil
  (spec 11 §R.3) — for `log("retrying \#{name}: \#{last_error()}")`.
  """
  @spec last_error() :: String.t() | nil
  def last_error, do: GenServer.call(context().runner, :last_error, :infinity)

  @doc """
  Writes a report into the run's scratch space and returns its path relative to
  the project root.
  """
  def write_report(filename, text) do
    ctx = context()
    name = filename |> to_string() |> Path.basename()

    call(:write_report, name, [], & &1, fn ->
      # spec 60 T35: a mkdir/resolve/write failure fails the run (nothing is
      # journaled, so a resume re-executes the call) instead of reporting a path
      # that holds nothing.
      rel = Path.join([".swarm_code", "workflows", "runs", to_string(ctx.display_name), name])

      with {:ok, abs} <- SwarmCode.Domain.Tools.Path.resolve(ctx.root, rel),
           :ok <- File.mkdir_p(Path.dirname(abs)),
           :ok <- File.write(abs, to_string(text)) do
        rel
      else
        {:error, reason} when is_binary(reason) ->
          raise Error, message: "write_report #{name}: #{reason}"

        {:error, reason} ->
          raise Error, message: "write_report #{name}: #{:file.format_error(reason)}"
      end
    end)
  end

  @doc """
  Merges the branch of an isolated worker back into the project. Takes the
  worker's own report (its text ends with `[Changes on branch …]`), a branch
  name or a node id.
  """
  def integrate(agent_result_or_node_id) do
    ctx = context()
    id = branch_of(agent_result_or_node_id)

    result =
      call(:host, {:integrate, id}, [], & &1, fn ->
        case SwarmCode.Domain.Conversations.list_nodes(ctx.run_id)
             |> Enum.find(&(&1.id == id or &1.branch == id)) do
          %{branch: branch} = node when is_binary(branch) ->
            # Spec 32 §4: the node this run owns is what gets merged and cleaned
            # up — never a branch name looked up again across the database.
            case SwarmCode.Domain.Tools.IntegrateAgent.validate_node(ctx.root, node) do
              :ok ->
                case SwarmCode.Domain.Git.merge(ctx.root, branch) do
                  {:ok, _} ->
                    SwarmCode.Domain.Tools.IntegrateAgent.cleanup(ctx.root, node)
                    "ok"

                  {:error, reason} ->
                    "error: " <> inspect(reason)
                end

              {:error, reason} ->
                "error: " <> reason
            end

          _ ->
            "error: no branch for " <> id
        end
      end)

    case result do
      "ok" -> :ok
      other -> {:error, to_string(other)}
    end
  end

  defp branch_of(value) when is_map(value),
    do: to_string(Map.get(value, :branch) || Map.get(value, "branch") || "")

  defp branch_of(value) when is_binary(value) do
    case Regex.run(~r/branch\s+(\S+)/, value) do
      [_, branch] -> String.trim_trailing(branch, ")")
      _ -> value
    end
  end

  defp branch_of(value), do: to_string(value)

  # ---------------------------------------------------------------- gates

  @doc "Human gate: pauses the run with a question and returns the answer on resume."
  def await_user(question, opts \\ []) do
    refuse_in_panel!("await_user/2")
    opts = Enum.into(opts, [])

    call(:await_user, to_string(question), opts, & &1)
  end

  @doc "Ends the step: the run pauses with a reason a resume cannot invent away."
  def pause(kind, message) do
    refuse_in_panel!("pause/2")

    unless kind in [:missing_input, :blocked, :infrastructure, :no_progress],
      do: raise(Error, message: "unknown pause kind #{inspect(kind)}")

    throw({:workflow, {:pause, to_string(kind), to_string(message)}})
  end

  @doc "Ends the run successfully with `value` as its result."
  def complete(value) do
    refuse_in_panel!("complete/1")
    throw({:workflow, {:complete, value}})
  end

  # ---------------------------------------------------------------- plumbing

  defp call(kind, payload, opts, decode, exec \\ nil) do
    ctx = context()
    {seq0, slot} = next_slot(ctx)

    request =
      {:host, kind, payload, sanitize(opts), %{seq: seq0, slot: slot, panel: ctx.panel != nil}}

    case GenServer.call(ctx.runner, request, :infinity) do
      {:replay, value} ->
        decode.(value)

      {:agent, node_id, seq} ->
        value =
          ctx.run_id
          |> await_agent(node_id)
          |> retry_once(ctx, payload, opts, seq, slot)

        commit(ctx, kind, seq, slot, value)
        decode.(value)

      {:exec, seq} ->
        value = exec.()
        commit(ctx, kind, seq, slot, value)
        decode.(value)

      {:gate, question, options, seq} ->
        throw({:workflow, {:await_user, question, options, seq, slot}})

      {:pause, pause_kind, message} ->
        throw({:workflow, {:pause, pause_kind, message}})

      {:failed, message} ->
        throw({:workflow, {:failed, message}})
    end
  end

  # A pause or a stop takes the RunServer down while slots are still waiting;
  # that is an ordinary "no result", not a crash.
  defp await_agent(run_id, node_id) do
    RunServer.await_agent(run_id, node_id)
  catch
    :exit, _ -> {:error, "the run stopped"}
  end

  # One fresh agent for a worker that died of an infrastructure failure
  # (spec 11 §7.4); the Runner decides — it owns the budget and the 3 minute
  # window after which the whole run parks itself instead.
  defp retry_once({:ok, text}, _ctx, _payload, _opts, _seq, _slot), do: text

  defp retry_once({:error, reason}, ctx, payload, opts, seq, slot) do
    request = {:retry_agent, seq, slot, payload, sanitize(opts), reason}

    case GenServer.call(ctx.runner, request, :infinity) do
      {:agent, node_id} ->
        case await_agent(ctx.run_id, node_id) do
          {:ok, text} -> text
          {:error, reason} -> note_failure(ctx, seq, slot, reason)
        end

      _no ->
        nil
    end
  catch
    :exit, _ -> nil
  end

  defp retry_once(_other, _ctx, _payload, _opts, _seq, _slot), do: nil

  # The second failure only updates `last_error/0`; the slot stays empty.
  defp note_failure(ctx, seq, slot, reason) do
    GenServer.call(ctx.runner, {:retry_agent, seq, slot, "", [], reason}, :infinity)
    nil
  catch
    :exit, _ -> nil
  end

  defp commit(ctx, kind, seq, slot, value) do
    case GenServer.call(ctx.runner, {:commit, seq, slot, to_string(kind), value}, :infinity) do
      :ok -> :ok
      # spec 55 T10: a refused journal write fails this call, never the process.
      {:failed, message} -> throw({:workflow, {:failed, message}})
    end
  end

  # Single calls sit at slot 0; the first journaled call of a panel slot uses the
  # slot index itself (so the journal reads like the spec), later ones are pushed
  # into the space above every possible slot index.
  defp next_slot(%{panel: nil}), do: {nil, 0}

  defp next_slot(%{panel: %{seq: seq, slot: index}, calls: calls}) do
    update_context(&Map.put(&1, :calls, calls + 1))

    if calls == 0,
      do: {seq, index},
      else: {seq, (index + 1) * @slot_stride + calls}
  end

  @doc false
  def sanitize(opts) do
    opts
    |> Enum.reject(fn {_k, v} -> is_function(v) or is_pid(v) end)
    |> Enum.sort()
  end
end
