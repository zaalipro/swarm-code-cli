defmodule SwarmCode.Daemon.Test.OSProcess do
  @moduledoc false

  @default_timeout 5_000
  @owner_key {__MODULE__, :owner}

  @spec start_lease_probe!(Path.t()) :: port()
  def start_lease_probe!(dir), do: start_lease_probe!(dir, [])

  @spec start_lease_probe!(Path.t(), keyword()) :: port()
  def start_lease_probe!(dir, test_opts) when is_binary(dir) and is_list(test_opts) do
    test_process = self()
    start_ref = make_ref()
    timeout = Keyword.get(test_opts, :timeout, @default_timeout)
    executable = System.find_executable("elixir") || raise "elixir executable not found"
    probe_path = Path.expand("lease_probe.exs", __DIR__)
    encoded_opts = encode_opts!(dir, test_opts)

    owner_opts = %{
      lifecycle_observer: Keyword.get(test_opts, :lifecycle_observer),
      owner_exit_barrier: Keyword.get(test_opts, :owner_exit_barrier),
      port_opener: Keyword.get(test_opts, :port_opener, &Port.open/2)
    }

    {owner, owner_monitor} =
      spawn_monitor(fn ->
        open_and_own(test_process, start_ref, executable, probe_path, encoded_opts, owner_opts)
      end)

    receive do
      {^start_ref, ^owner, {:ok, port}} ->
        Process.demonitor(owner_monitor, [:flush])
        :persistent_term.put({@owner_key, port}, %{owner: owner, timeout: timeout})
        ExUnit.Callbacks.on_exit({__MODULE__, port}, fn -> close_and_reap!(port) end)
        port

      {^start_ref, ^owner, {:error, reason}} ->
        await_normal_down!(owner, owner_monitor, timeout)
        raise "could not start lease probe: #{Exception.format_exit(reason)}"

      {:DOWN, ^owner_monitor, :process, ^owner, reason} ->
        raise "lease probe owner exited during startup: #{inspect(reason)}"
    after
      timeout ->
        cancel_start_and_reap!(owner, owner_monitor)
        raise "timed out starting lease probe"
    end
  end

  @spec await_ready!(port()) :: pos_integer()
  def await_ready!(port) when is_port(port) do
    case await_message!(port, :ready) do
      "READY " <> pid_text ->
        case Integer.parse(pid_text) do
          {pid, ""} when pid > 0 -> pid
          _other -> raise "lease probe reported an invalid OS PID: #{inspect(pid_text)}"
        end

      line ->
        raise "lease probe emitted an unexpected ready line: #{inspect(line)}"
    end
  end

  @spec await_result!(port()) :: :acquired | :held
  def await_result!(port) when is_port(port) do
    case await_message!(port, :result) do
      "ACQUIRED" -> :acquired
      "HELD" -> :held
      line -> raise "lease probe emitted an unexpected result line: #{inspect(line)}"
    end
  end

  @spec await_exit!(port()) :: non_neg_integer()
  def await_exit!(port) when is_port(port) do
    timeout = timeout_for(port)

    receive do
      {^port, {:exit_status, status}} when is_integer(status) and status >= 0 ->
        finish_owner!(port, status)
        status

      {^port, {:data, data}} ->
        cleanup_then_raise!(
          port,
          "lease probe emitted output while awaiting exit: #{inspect(data)}"
        )
    after
      timeout ->
        cleanup_then_raise!(port, "timed out awaiting lease probe exit")
    end
  end

  @spec close_and_reap!(port()) :: :ok
  def close_and_reap!(port) when is_port(port) do
    case owner_handle(port) do
      nil ->
        :ok

      %{owner: owner} ->
        request_ref = make_ref()
        monitor = Process.monitor(owner)
        send(owner, {:cleanup, self(), request_ref})

        receive do
          {^request_ref, status} when is_integer(status) and status >= 0 -> :ok
          {:DOWN, ^monitor, :process, ^owner, reason} -> owner_down_before_ack!(port, reason)
        after
          @default_timeout ->
            Process.demonitor(monitor, [:flush])
            raise "timed out closing and reaping lease probe"
        end

        await_normal_down!(owner, monitor, @default_timeout)
        erase_owner(port)
        :ok
    end
  end

  defp await_message!(port, phase) do
    timeout = timeout_for(port)

    receive do
      {^port, {:data, {:eol, line}}} when is_binary(line) ->
        line

      {^port, {:data, data}} ->
        cleanup_then_raise!(
          port,
          "lease probe emitted an incomplete #{phase} line: #{inspect(data)}"
        )

      {^port, {:exit_status, status}} ->
        finish_owner!(port, status)
        raise "lease probe exited with status #{status} before #{phase}"
    after
      timeout ->
        cleanup_then_raise!(port, "timed out awaiting lease probe #{phase}")
    end
  end

  defp cleanup_then_raise!(port, message) do
    close_and_reap!(port)
    raise message
  end

  defp finish_owner!(port, status) do
    case owner_handle(port) do
      nil ->
        :ok

      %{owner: owner} ->
        request_ref = make_ref()
        monitor = Process.monitor(owner)
        send(owner, {:finish, self(), request_ref, status})

        receive do
          {^request_ref, :ok} -> :ok
          {:DOWN, ^monitor, :process, ^owner, reason} -> owner_down_before_ack!(port, reason)
        after
          @default_timeout ->
            Process.demonitor(monitor, [:flush])
            raise "timed out finalizing lease probe port"
        end

        await_normal_down!(owner, monitor, @default_timeout)
        erase_owner(port)
    end
  end

  defp cancel_start_and_reap!(owner, owner_monitor) do
    request_ref = make_ref()
    send(owner, {:cancel_start, self(), request_ref})

    receive do
      {^request_ref, status}
      when status == :no_port or (is_integer(status) and status >= 0) ->
        :ok

      {:DOWN, ^owner_monitor, :process, ^owner, reason} ->
        raise "lease probe owner exited before startup cleanup: #{inspect(reason)}"
    after
      @default_timeout ->
        Process.demonitor(owner_monitor, [:flush])
        raise "timed out cancelling lease probe startup"
    end

    await_normal_down!(owner, owner_monitor, @default_timeout)
  end

  defp await_normal_down!(owner, monitor, timeout) do
    receive do
      {:DOWN, ^monitor, :process, ^owner, :normal} ->
        :ok

      {:DOWN, ^monitor, :process, ^owner, reason} ->
        raise "lease probe owner exited unexpectedly: #{inspect(reason)}"
    after
      timeout ->
        Process.demonitor(monitor, [:flush])
        raise "timed out awaiting lease probe owner exit"
    end
  end

  defp owner_down_before_ack!(port, reason) do
    erase_owner(port)
    raise "lease probe owner exited before acknowledging cleanup: #{inspect(reason)}"
  end

  defp open_and_own(test_process, start_ref, executable, probe_path, encoded_opts, owner_opts) do
    test_monitor = Process.monitor(test_process)
    observers = List.wrap(owner_opts.lifecycle_observer)
    notify_observers(observers, {:owner_started, self()})
    open_ref = make_ref()
    owner = self()

    port_name = {:spawn_executable, executable}

    port_options = [
      :binary,
      :exit_status,
      {:line, 4096},
      args: code_path_args() ++ [probe_path, encoded_opts]
    ]

    {opener, opener_monitor} =
      spawn_monitor(fn ->
        run_opener(owner, open_ref, owner_opts.port_opener, port_name, port_options)
      end)

    await_open(%{
      adopted?: false,
      cancel_waiter: nil,
      open_error: nil,
      open_ref: open_ref,
      opener: opener,
      opener_monitor: opener_monitor,
      observers: observers,
      owner_exit_barrier: owner_opts.owner_exit_barrier,
      port: nil,
      port_os_pid: nil,
      reported_os_pid: nil,
      start_ref: start_ref,
      test_monitor: test_monitor,
      test_process: test_process
    })
  end

  defp run_opener(owner, open_ref, port_opener, port_name, port_options) do
    try do
      port = port_opener.(port_name, port_options)
      true = is_port(port)
      {:os_pid, port_os_pid} = Port.info(port, :os_pid)
      send(owner, {open_ref, :opened, self(), port, port_os_pid})
      await_port_adoption(owner, open_ref, port)
    rescue
      error -> send(owner, {open_ref, :open_error, self(), {:exception, error}})
    catch
      kind, reason -> send(owner, {open_ref, :open_error, self(), {kind, reason}})
    end
  end

  defp await_port_adoption(owner, open_ref, port) do
    receive do
      {^open_ref, :adopt} ->
        true = Port.connect(port, owner)
        send(owner, {open_ref, :adopted, self(), port})

      {^port, event} ->
        send(owner, {open_ref, :port_event, port, event})
        await_port_adoption(owner, open_ref, port)
    end
  end

  defp await_open(state) do
    receive do
      {open_ref, :opened, opener, port, port_os_pid}
      when open_ref == state.open_ref and opener == state.opener ->
        send(opener, {open_ref, :adopt})
        await_open(%{state | port: port, port_os_pid: port_os_pid})

      {open_ref, :adopted, opener, port}
      when open_ref == state.open_ref and opener == state.opener and port == state.port ->
        await_open(%{state | adopted?: true})

      {open_ref, :port_event, port, event}
      when open_ref == state.open_ref and port == state.port ->
        state = forward_opening_port_event(state, event)
        await_open(state)

      {open_ref, :open_error, opener, reason}
      when open_ref == state.open_ref and opener == state.opener ->
        await_open(%{state | open_error: reason})

      {:DOWN, monitor, :process, opener, reason}
      when monitor == state.opener_monitor and opener == state.opener ->
        opener_finished(state, reason)

      {:cancel_start, from, request_ref} ->
        Process.exit(state.opener, :kill)
        await_open(%{state | cancel_waiter: {from, request_ref}})

      {:DOWN, monitor, :process, process, _reason}
      when monitor == state.test_monitor and process == state.test_process ->
        Process.exit(state.opener, :kill)
        await_open(%{state | cancel_waiter: nil, test_process: nil})
    end
  end

  defp opener_finished(%{cancel_waiter: waiter} = state, _reason) when not is_nil(waiter) do
    cancel_after_opener_down(state, waiter)
  end

  defp opener_finished(%{test_process: nil} = state, _reason) do
    cancel_after_opener_down(state, nil)
  end

  defp opener_finished(%{open_error: reason} = state, :normal) when not is_nil(reason) do
    send(state.test_process, {state.start_ref, self(), {:error, reason}})
  end

  defp opener_finished(state, :normal) do
    if state.adopted? and port_connected_to_owner?(state.port) do
      finish_open(state)
    else
      send(state.test_process, {
        state.start_ref,
        self(),
        {:error, :port_adoption_incomplete}
      })
    end
  end

  defp opener_finished(state, reason) do
    if port_connected_to_owner?(state.port) do
      finish_open(state)
    else
      send(state.test_process, {state.start_ref, self(), {:error, {:opener_exit, reason}}})
    end
  end

  defp cancel_after_opener_down(state, waiter) do
    if port_connected_to_owner?(state.port) do
      begin_cleanup(owner_state(state, false), waiter)
    else
      acknowledge_no_port(waiter)
    end
  end

  defp acknowledge_no_port({from, request_ref}), do: send(from, {request_ref, :no_port})
  defp acknowledge_no_port(nil), do: :ok

  defp finish_open(state) do
    notify_observers(state.observers, {:opened, self(), state.port, state.port_os_pid})
    send(state.test_process, {state.start_ref, self(), {:ok, state.port}})
    owner_loop(owner_state(state, true))
  end

  defp owner_state(state, started?) do
    %{
      cleanup_waiter: nil,
      exit_status: nil,
      observers: state.observers,
      owner_exit_barrier: state.owner_exit_barrier,
      port: state.port,
      port_os_pid: state.port_os_pid,
      reported_os_pid: state.reported_os_pid,
      start_ref: state.start_ref,
      started?: started?,
      test_monitor: state.test_monitor,
      test_process: state.test_process
    }
  end

  defp forward_opening_port_event(state, {:data, {:eol, line}} = event) do
    send_if_present(state.test_process, {state.port, event})
    %{state | reported_os_pid: reported_pid(line) || state.reported_os_pid}
  end

  defp forward_opening_port_event(state, event) do
    send_if_present(state.test_process, {state.port, event})
    state
  end

  defp port_connected_to_owner?(port) when is_port(port) do
    Port.info(port, :connected) == {:connected, self()}
  end

  defp port_connected_to_owner?(_port), do: false

  defp owner_loop(state) do
    receive do
      {port, {:data, {:eol, line}} = event} when port == state.port ->
        send_if_present(state.test_process, {port, event})
        owner_loop(%{state | reported_os_pid: reported_pid(line) || state.reported_os_pid})

      {port, {:data, _data} = event} when port == state.port ->
        send_if_present(state.test_process, {port, event})
        owner_loop(state)

      {port, {:exit_status, status} = event} when port == state.port ->
        send_if_present(state.test_process, {port, event})
        notify_external_exit(state.observers, port, status)

        case state.cleanup_waiter do
          {from, request_ref} ->
            send(from, {request_ref, status})
            await_owner_exit_barrier(state)

          nil ->
            owner_loop(%{state | exit_status: status})
        end

      {:finish, from, request_ref, status} when status == state.exit_status ->
        send(from, {request_ref, :ok})
        await_owner_exit_barrier(state)

      {:finish, from, request_ref, reported_status} ->
        send(from, {request_ref, {:status_mismatch, state.exit_status, reported_status}})
        owner_loop(state)

      {:cleanup, from, request_ref} ->
        begin_cleanup(state, {from, request_ref})

      {:cancel_start, from, request_ref} ->
        begin_cleanup(state, {from, request_ref})

      {:DOWN, monitor, :process, process, _reason}
      when monitor == state.test_monitor and process == state.test_process ->
        if state.started? do
          owner_loop(%{state | test_monitor: nil, test_process: nil})
        else
          begin_cleanup(state, nil)
        end
    end
  end

  defp begin_cleanup(%{exit_status: status} = state, {from, request_ref})
       when is_integer(status) do
    send(from, {request_ref, status})
    await_owner_exit_barrier(state)
  end

  defp begin_cleanup(%{exit_status: status}, nil) when is_integer(status), do: :ok

  defp begin_cleanup(state, waiter) do
    exact_pid = state.reported_os_pid || state.port_os_pid
    _ = System.cmd("/bin/kill", ["-KILL", Integer.to_string(exact_pid)], stderr_to_stdout: true)
    owner_loop(%{state | cleanup_waiter: waiter})
  end

  defp notify_external_exit(observers, port, status) do
    notify_observers(observers, {:external_exit, port, status})
  end

  defp notify_observers(observers, event) do
    Enum.each(observers, fn {observer, observer_ref} ->
      send(observer, {observer_ref, event})
    end)
  end

  defp await_owner_exit_barrier(%{owner_exit_barrier: nil}), do: :ok

  defp await_owner_exit_barrier(state) do
    {observer, barrier_ref} = state.owner_exit_barrier
    send(observer, {barrier_ref, {:owner_exit_blocked, self()}})

    receive do
      {^barrier_ref, :continue} ->
        :ok

      {:DOWN, monitor, :process, process, _reason}
      when monitor == state.test_monitor and process == state.test_process ->
        :ok
    end
  end

  defp send_if_present(nil, _message), do: :ok
  defp send_if_present(process, message), do: send(process, message)

  defp reported_pid("READY " <> pid_text) do
    case Integer.parse(pid_text) do
      {pid, ""} when pid > 0 -> pid
      _other -> nil
    end
  end

  defp reported_pid(_line), do: nil

  defp code_path_args do
    :code.get_path()
    |> Enum.map(&List.to_string/1)
    |> Enum.reject(&(&1 == "."))
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
    |> Enum.flat_map(&["-pa", &1])
  end

  defp encode_opts!(dir, test_opts) do
    opts = %{
      "app_version" => "0.1.0-dev",
      "database_fingerprint" => "sha256:os-process-test",
      "lease_path" => Path.join(dir, "instance_lease.db"),
      "manifest_sha256" => "408afb8e6eb422c8df50fe65536a08f853475c162d584db45b4af708274fd1d0",
      "newest_migration" => 20_260_926_000_000,
      "owner_path" => Path.join(dir, "instance_owner.json"),
      "probe_mode" => test_opts |> Keyword.get(:probe_mode, :normal) |> Atom.to_string(),
      "schema_epoch" => 0,
      "socket_path" => Path.join(dir, "daemon.sock"),
      "uid" => File.lstat!(dir).uid
    }

    opts
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp timeout_for(port) do
    case owner_handle(port) do
      %{timeout: timeout} -> timeout
      nil -> @default_timeout
    end
  end

  defp owner_handle(port), do: :persistent_term.get({@owner_key, port}, nil)
  defp erase_owner(port), do: :persistent_term.erase({@owner_key, port})
end
