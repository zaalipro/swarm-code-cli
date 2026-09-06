defmodule SwarmCodeCLI.Demo.ApplicationFence do
  @moduledoc "Owns only the trusted CLI application's temporary startup and teardown."
  @closure Enum.sort([
             :compiler,
             :crypto,
             :elixir,
             :jason,
             :kernel,
             :logger,
             :stdlib,
             :swarm_code_cli,
             :swarm_code_core
           ])
  @forbidden [
    :swarm_code_daemon,
    :ecto,
    :ecto_sql,
    :ecto_sqlite3,
    :exqlite,
    :ex_ratatui,
    :rustler,
    :crossterm
  ]
  @prefixes [
    "Elixir.SwarmCode.Daemon",
    "Elixir.SwarmCode.Repo",
    "Elixir.Ecto",
    "Elixir.Exqlite",
    "Elixir.ExRatatui",
    "Elixir.Rustler"
  ]
  @tracking {__MODULE__, :trees}
  @owner {__MODULE__, :owner}
  @process_limit 4096
  @type audit :: map()

  def run(callback) when is_function(callback, 0) do
    audit_descriptor!()
    if Process.get(@tracking), do: raise("demo fence is already active")
    before = snapshot()
    assert_clean!(before)
    load_cli!()
    declared = read_closure([:swarm_code_cli], MapSet.new()) |> Enum.sort()
    unless declared == @closure, do: raise("unexpected demo application closure")
    Process.put(@tracking, [])

    try do
      case Application.ensure_all_started(:swarm_code_cli, :temporary) do
        {:ok, newly} -> owned_run(callback, before, declared, newly)
        {:error, _} -> raise("demo application start failed")
      end
    after
      Process.delete(@tracking)
      Process.delete({__MODULE__, :after})
    end
  end

  @doc "Registers an owned demo supervisor before its driver begins."
  def track_tree(pid) when is_pid(pid) do
    case Process.get(@tracking) do
      nil ->
        case Process.get(@owner) do
          {owner, token} ->
            send(owner, {token, :tree, pid, self()})

            receive do
              {^token, :tracked} -> :ok
            after
              5000 -> raise("demo tree tracking failed")
            end

          nil ->
            :ok
        end

      trees ->
        {previous, others} = Enum.split_with(trees, fn {root, _, _} -> root == pid end)

        existing =
          case previous do
            [{_, monitors, _}] -> Map.new(monitors)
            [] -> %{}
          end

        existing =
          if Map.has_key?(existing, pid),
            do: existing,
            else: Map.put(existing, pid, Process.monitor(pid))

        # Register the root before traversal so an oversized tree is still owned on failure.
        Process.put(@tracking, [{pid, Map.to_list(existing), nil} | others])
        members = tree_members(pid, MapSet.new()) |> MapSet.to_list()

        monitors =
          Enum.reduce(members, existing, fn member, acc ->
            if Map.has_key?(acc, member),
              do: acc,
              else: Map.put(acc, member, Process.monitor(member))
          end)
          |> Map.to_list()

        Process.put(@tracking, [{pid, monitors, nil} | others])
        captured = snapshot()
        assert_clean!(captured)
        Process.put(@tracking, [{pid, monitors, captured} | others])

        :ok
    end
  end

  def maybe_write_fd3(audit) do
    case audit_descriptor!() do
      nil ->
        :ok

      "3" ->
        record = canonical(audit) |> Jason.encode!()
        if byte_size(record) + 1 > 32_768, do: raise("demo audit exceeds bound")

        case :file.open(~c"/dev/fd/3", [:write, :raw, :binary]) do
          {:ok, device} ->
            try do
              :ok = :file.write(device, record <> "\n")
            after
              :ok = :file.close(device)
            end

          {:error, _} ->
            raise("demo audit descriptor unavailable")
        end
    end
  end

  defp owned_run(callback, before, declared, newly) do
    try do
      during = snapshot()
      assert_clean!(during)

      unless Enum.all?(newly, &(&1 in @closure)) and during.closure_started == names(@closure),
        do: raise("demo application startup escaped closure")

      result = run_callback(callback)
      latest = snapshot()
      assert_clean!(latest)
      trees = Process.get(@tracking)

      during =
        case trees do
          [{_, _, captured} | _] -> captured
          [] -> during
        end

      {result,
       %{
         declared_closure: names(declared),
         before: before,
         during: during,
         newly_started: names(newly)
       }}
    after
      try do
        close_trees!()
      after
        stop_apps!(newly)
      end

      after_state = snapshot()
      assert_clean!(after_state)

      unless after_state.started_applications == before.started_applications and
               after_state.demo_children == before.demo_children,
             do: raise("demo application baseline was not restored")

      Process.put({__MODULE__, :after}, after_state)
    end
    |> then(fn {result, audit} ->
      {result, Map.put(audit, :after, Process.delete({__MODULE__, :after}))}
    end)
  end

  defp run_callback(callback) do
    owner = self()
    token = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.put(@owner, {owner, token})

        result =
          try do
            {:ok, callback.()}
          catch
            kind, reason -> {:raise, kind, reason, __STACKTRACE__}
          end

        send(owner, {token, :result, result})
      end)

    deadline = System.monotonic_time(:millisecond) + 5000

    try do
      await_callback(pid, monitor, token, deadline)
    after
      unless Process.delete({__MODULE__, :callback_down, token}) do
        if Process.alive?(pid), do: Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _} -> :ok
        after
          1000 -> raise("demo callback did not terminate")
        end
      end
    end
  end

  defp await_callback(pid, monitor, token, deadline) do
    receive do
      {^token, :tree, root, ^pid} ->
        track_tree(root)
        send(pid, {token, :tracked})
        await_callback(pid, monitor, token, deadline)

      {^token, :result, result} ->
        receive do
          {:DOWN, ^monitor, :process, ^pid, _} ->
            Process.put({__MODULE__, :callback_down, token}, true)
        after
          1000 -> raise("demo callback did not terminate")
        end

        case result do
          {:ok, value} -> value
          {:raise, kind, reason, stack} -> :erlang.raise(kind, reason, stack)
        end

      {:DOWN, ^monitor, :process, ^pid, _} ->
        Process.put({__MODULE__, :callback_down, token}, true)
        raise("demo callback process failed")
    after
      max(0, deadline - System.monotonic_time(:millisecond)) ->
        raise("demo callback deadline exceeded")
    end
  end

  defp stop_apps!(newly) do
    level = :logger.get_primary_config().level

    try do
      :ok = :logger.set_primary_config(:level, :warning)

      errors =
        Enum.flat_map(Enum.reverse(newly), fn app ->
          case Application.stop(app) do
            :ok -> []
            error -> [{app, error}]
          end
        end)

      # OTP's :logger has no flush/0; Elixir exposes the supported synchronous flush.
      :ok = Logger.flush()
      if errors != [], do: raise("demo application stop failed: #{inspect(errors)}")
    after
      :ok = :logger.set_primary_config(:level, level)
    end
  end

  defp close_trees! do
    Enum.each(Process.get(@tracking, []), fn {root, monitors, _} ->
      if Process.alive?(root) do
        try do
          Supervisor.stop(root, :normal, 5000)
        catch
          :exit, {:noproc, _} -> :ok
          :exit, {:normal, _} -> :ok
        end
      end

      Enum.each(monitors, fn {pid, monitor} ->
        receive do
          {:DOWN, ^monitor, :process, ^pid, _} -> :ok
        after
          5000 -> raise("demo child did not terminate")
        end
      end)
    end)
  end

  defp tree_members(pid, seen) do
    if MapSet.member?(seen, pid) or MapSet.size(seen) >= 64 do
      if MapSet.size(seen) >= 64, do: raise("demo child bound exceeded")
      seen
    else
      seen = MapSet.put(seen, pid)

      Enum.reduce(Supervisor.which_children(pid), seen, fn
        {_, child, :supervisor, _}, acc when is_pid(child) ->
          tree_members(child, acc)

        {_, child, _, _}, acc when is_pid(child) ->
          if MapSet.size(acc) >= 64 and not MapSet.member?(acc, child),
            do: raise("demo child bound exceeded")

          MapSet.put(acc, child)

        _, acc ->
          acc
      end)
    end
  end

  defp snapshot do
    apps = Application.started_applications() |> Enum.map(&elem(&1, 0))

    if :erlang.system_info(:process_count) > @process_limit,
      do: raise("demo process scan exceeds bound")

    pids = Process.list()
    if length(pids) > @process_limit, do: raise("demo process scan exceeds bound")
    findings = Enum.flat_map(pids, &process_findings/1) |> Enum.uniq() |> Enum.sort()

    children =
      Process.get(@tracking, [])
      |> Enum.flat_map(fn {_, monitors, _} -> Enum.map(monitors, &elem(&1, 0)) end)
      |> Enum.uniq()
      |> Enum.count(&Process.alive?/1)

    %{
      started_applications: names(apps),
      closure_started: names(Enum.filter(apps, &(&1 in @closure))),
      forbidden_applications: names(Enum.filter(apps, &(&1 in @forbidden))),
      forbidden_processes: findings,
      demo_children: children
    }
  end

  defp process_findings(pid) do
    case Process.info(pid, [:registered_name, :initial_call, :current_function]) do
      nil ->
        []

      info ->
        translated =
          try do
            :proc_lib.translate_initial_call(pid)
          catch
            _, _ -> nil
          end

        [
          Keyword.get(info, :registered_name),
          call_module(Keyword.get(info, :initial_call)),
          call_module(Keyword.get(info, :current_function)),
          call_module(translated)
        ]
        |> Enum.filter(&is_atom/1)
        |> Enum.map(&Atom.to_string/1)
        |> Enum.filter(fn name ->
          name in names(@forbidden) or Enum.any?(@prefixes, &String.starts_with?(name, &1))
        end)
    end
  end

  defp call_module({module, _, _}), do: module
  defp call_module(_), do: nil

  defp assert_clean!(%{forbidden_applications: apps, forbidden_processes: processes}) do
    if apps != [], do: raise("forbidden application is running")
    if processes != [], do: raise("forbidden process is running")
  end

  defp load_cli! do
    case Application.load(:swarm_code_cli) do
      :ok -> :ok
      {:error, {:already_loaded, :swarm_code_cli}} -> :ok
      _ -> raise("demo application load failed")
    end
  end

  defp read_closure([], seen), do: MapSet.to_list(seen)

  defp read_closure([app | rest], seen) do
    cond do
      app not in @closure ->
        raise("unexpected demo application closure")

      MapSet.member?(seen, app) ->
        read_closure(rest, seen)

      true ->
        path =
          case :code.lib_dir(app) do
            path when is_list(path) ->
              :filename.join([path, ~c"ebin", Atom.to_charlist(app) ++ ~c".app"])

            _ ->
              raise("missing trusted application specification")
          end

        case :file.consult(path) do
          {:ok, [{:application, ^app, spec}]} when is_list(spec) ->
            validate_loaded_spec!(app, spec)
            optional = Keyword.get(spec, :optional_applications, [])

            dependencies =
              Keyword.get(spec, :applications, []) ++
                Keyword.get(spec, :included_applications, [])

            unless is_list(dependencies) and length(dependencies) <= length(@closure) and
                     Enum.all?(dependencies, &is_atom/1),
                   do: raise("invalid trusted application specification")

            # OTP skips optional dependencies whose application specification is absent.
            dependencies =
              Enum.reject(
                dependencies,
                &(&1 in optional and :code.lib_dir(&1) == {:error, :bad_name})
              )

            read_closure(dependencies ++ rest, MapSet.put(seen, app))

          _ ->
            raise("invalid trusted application specification")
        end
    end
  end

  defp validate_loaded_spec!(app, trusted) do
    case Application.spec(app) do
      nil ->
        :ok

      loaded ->
        unless Enum.all?(
                 [:applications, :included_applications, :optional_applications, :mod],
                 fn key ->
                   Keyword.get(loaded, key, []) == Keyword.get(trusted, key, [])
                 end
               ),
               do: raise("loaded demo application differs from trusted specification")
    end
  end

  defp audit_descriptor! do
    case System.get_env("SWARM_CODE_DEMO_AUDIT_FD") do
      value when value in [nil, "3"] -> value
      _ -> raise ArgumentError, "invalid demo audit descriptor"
    end
  end

  defp names(apps), do: apps |> Enum.map(&Atom.to_string/1) |> Enum.sort()

  defp canonical(value) when is_map(value),
    do:
      Jason.OrderedObject.new(
        value
        |> Enum.map(fn {key, value} -> {to_string(key), canonical(value)} end)
        |> Enum.sort_by(&elem(&1, 0))
      )

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value
end
