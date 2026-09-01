defmodule SwarmCode.Daemon.Test.OSProcess do
  @moduledoc false

  @default_timeout 5_000
  @owner_key {__MODULE__, :owner}
  @candidate_owned 1

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
      activate_after_first_event?: Keyword.get(test_opts, :activate_after_first_event, false),
      activation_barrier: Keyword.get(test_opts, :activation_barrier),
      candidate_registration_barrier: Keyword.get(test_opts, :candidate_registration_barrier),
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
        cleanup_then_raise!(
          port,
          "lease probe emitted an unexpected ready line: #{inspect(line)}"
        )
    end
  end

  @spec await_result!(port()) :: :acquired | :held
  def await_result!(port) when is_port(port) do
    case await_message!(port, :result) do
      "ACQUIRED" ->
        :acquired

      "HELD" ->
        :held

      line ->
        cleanup_then_raise!(
          port,
          "lease probe emitted an unexpected result line: #{inspect(line)}"
        )
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
      timeout -> cleanup_then_raise!(port, "timed out awaiting lease probe exit")
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
      timeout -> cleanup_then_raise!(port, "timed out awaiting lease probe #{phase}")
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

  defp open_and_own(test_process, start_ref, executable, probe_path, encoded_opts, opts) do
    test_monitor = Process.monitor(test_process)
    observers = List.wrap(opts.lifecycle_observer)
    notify_observers(observers, {:owner_started, self()})
    owner = self()
    open_ref = make_ref()
    open_phase = :atomics.new(1, [])
    port_name = {:spawn_executable, executable}

    port_options = [
      :binary,
      :exit_status,
      {:line, 4096},
      args: code_path_args() ++ [probe_path, encoded_opts]
    ]

    {worker, worker_monitor} =
      spawn_monitor(fn ->
        port_worker(
          owner,
          open_ref,
          open_phase,
          opts.candidate_registration_barrier,
          opts.port_opener,
          port_name,
          port_options
        )
      end)

    opening_loop(%{
      activate_after_first_event?: opts.activate_after_first_event?,
      activation_barrier: opts.activation_barrier,
      activation_sent?: false,
      candidate_registration_barrier: opts.candidate_registration_barrier,
      cleanup_status: nil,
      exit_status: nil,
      finish_ack?: false,
      observers: observers,
      open_error: nil,
      open_phase: open_phase,
      open_ref: open_ref,
      owner_exit_barrier: opts.owner_exit_barrier,
      port: nil,
      port_down?: false,
      port_monitor: nil,
      port_os_pid: nil,
      reported_os_pid: nil,
      start_ref: start_ref,
      test_monitor: test_monitor,
      test_process: test_process,
      termination: nil,
      worker: worker,
      worker_down?: false,
      worker_exit_reason: nil,
      worker_monitor: worker_monitor
    })
  end

  defp port_worker(
         owner,
         open_ref,
         open_phase,
         candidate_registration_barrier,
         port_opener,
         port_name,
         port_options
       ) do
    try do
      port = port_opener.(port_name, port_options)
      true = is_port(port)
      {:os_pid, os_pid} = Port.info(port, :os_pid)
      :atomics.put(open_phase, 1, @candidate_owned)
      send(owner, {open_ref, :candidate, self(), port, os_pid})

      if candidate_registration_barrier do
        send(owner, {open_ref, :candidate_published, self(), port, os_pid})
      end

      port_worker_loop(%{
        active?: false,
        exit_status: nil,
        open_ref: open_ref,
        owner: owner,
        os_pid: os_pid,
        port: port
      })
    rescue
      error -> send(owner, {open_ref, :open_error, self(), {:exception, error}})
    catch
      kind, reason -> send(owner, {open_ref, :open_error, self(), {kind, reason}})
    end
  end

  defp port_worker_loop(state) do
    receive do
      {port, {:data, _data} = event} when port == state.port ->
        send(state.owner, {state.open_ref, :port_event, port, event})
        port_worker_loop(state)

      {port, {:exit_status, status} = event} when port == state.port ->
        send(state.owner, {state.open_ref, :port_event, port, event})
        port_worker_loop(%{state | exit_status: status})

      {open_ref, :activate} when open_ref == state.open_ref ->
        send(state.owner, {open_ref, :active, self(), state.port})
        port_worker_loop(%{state | active?: true})

      {open_ref, :cleanup, cleanup_ref} when open_ref == state.open_ref ->
        cleanup_port_worker(state, cleanup_ref)

      {open_ref, :finish, finish_ref, status}
      when open_ref == state.open_ref and status == state.exit_status ->
        send(state.owner, {open_ref, :worker_finished, finish_ref, self()})
    end
  end

  defp cleanup_port_worker(%{exit_status: status} = state, cleanup_ref) when is_integer(status) do
    send(state.owner, {state.open_ref, :cleanup_complete, cleanup_ref, status, self()})
  end

  defp cleanup_port_worker(state, cleanup_ref) do
    _ =
      System.cmd("/bin/kill", ["-KILL", Integer.to_string(state.os_pid)], stderr_to_stdout: true)

    await_cleanup_exit(state, cleanup_ref)
  end

  defp await_cleanup_exit(state, cleanup_ref) do
    receive do
      {port, {:data, _data} = event} when port == state.port ->
        send(state.owner, {state.open_ref, :port_event, port, event})
        await_cleanup_exit(state, cleanup_ref)

      {port, {:exit_status, status} = event} when port == state.port ->
        send(state.owner, {state.open_ref, :port_event, port, event})
        send(state.owner, {state.open_ref, :cleanup_complete, cleanup_ref, status, self()})
    end
  end

  defp opening_loop(state) do
    receive do
      {open_ref, :candidate, worker, port, os_pid}
      when open_ref == state.open_ref and worker == state.worker and
             is_nil(state.candidate_registration_barrier) ->
        state
        |> register_candidate(worker, port, os_pid)
        |> maybe_activate()
        |> opening_loop()

      {open_ref, :candidate_published, worker, port, os_pid}
      when open_ref == state.open_ref and worker == state.worker and
             not is_nil(state.candidate_registration_barrier) ->
        await_candidate_registration(state, worker, port, os_pid)

      {open_ref, :port_event, port, event}
      when open_ref == state.open_ref and port == state.port ->
        state = forward_port_event(state, event)
        opening_loop(maybe_activate_after_event(state))

      {open_ref, :active, worker, port}
      when open_ref == state.open_ref and worker == state.worker and port == state.port ->
        notify_observers(state.observers, {:activated, self(), worker, port, state.port_os_pid})
        notify_observers(state.observers, {:opened, self(), port, state.port_os_pid})
        send(state.test_process, {state.start_ref, self(), {:ok, port}})
        runtime_loop(state)

      {open_ref, :open_error, worker, reason}
      when open_ref == state.open_ref and worker == state.worker ->
        opening_loop(%{state | open_error: reason})

      {:DOWN, monitor, :process, worker, reason}
      when monitor == state.worker_monitor and worker == state.worker ->
        opening_worker_down(state, reason)

      {:DOWN, monitor, :port, port, _reason}
      when monitor == state.port_monitor and port == state.port ->
        opening_loop(%{state | port_down?: true})

      {barrier_ref, :activate}
      when not is_nil(state.activation_barrier) and
             barrier_ref == elem(state.activation_barrier, 1) ->
        opening_loop(send_activate(state))

      {:cancel_start, from, request_ref} ->
        cancel_opening(state, {from, request_ref})

      {:DOWN, monitor, :process, process, _reason}
      when monitor == state.test_monitor and process == state.test_process ->
        cancel_opening(%{state | test_process: nil}, nil)
    end
  end

  defp maybe_activate(%{activation_barrier: barrier} = state) when not is_nil(barrier), do: state
  defp maybe_activate(%{activate_after_first_event?: true} = state), do: state
  defp maybe_activate(state), do: send_activate(state)

  defp maybe_activate_after_event(%{activate_after_first_event?: true} = state),
    do: send_activate(state)

  defp maybe_activate_after_event(state), do: state

  defp send_activate(%{activation_sent?: true} = state), do: state

  defp send_activate(state) do
    send(state.worker, {state.open_ref, :activate})
    %{state | activation_sent?: true}
  end

  defp opening_worker_down(%{open_error: reason} = state, :normal) when not is_nil(reason) do
    send(state.test_process, {state.start_ref, self(), {:error, reason}})
  end

  defp opening_worker_down(state, reason) do
    send(state.test_process, {state.start_ref, self(), {:error, {:port_worker_exit, reason}}})
  end

  defp await_candidate_registration(state, worker, port, os_pid) do
    {barrier_process, barrier_ref} = state.candidate_registration_barrier

    notify_observers(
      state.observers,
      {:candidate_awaiting_registration, self(), worker, port, os_pid}
    )

    send(
      barrier_process,
      {barrier_ref, {:candidate_registration_blocked, self(), worker, port, os_pid}}
    )

    candidate_registration_loop(state, barrier_ref)
  end

  defp candidate_registration_loop(state, barrier_ref) do
    receive do
      {^barrier_ref, :continue} ->
        opening_loop(%{state | candidate_registration_barrier: nil})

      {:cancel_start, from, request_ref} ->
        cancel_opening(state, {from, request_ref})

      {:DOWN, monitor, :process, process, _reason}
      when monitor == state.test_monitor and process == state.test_process ->
        cancel_opening(%{state | test_process: nil}, nil)
    end
  end

  defp register_candidate(state, worker, port, os_pid) do
    port_monitor = Port.monitor(port)
    notify_observers(state.observers, {:candidate_opened, self(), worker, port, os_pid})
    %{state | port: port, port_monitor: port_monitor, port_os_pid: os_pid}
  end

  defp cancel_opening(%{port: nil} = state, waiter) do
    case suspend_opening_worker(state) do
      :blocked_without_port ->
        Process.exit(state.worker, :kill)
        cancel_without_candidate_loop(state, waiter)

      :candidate_owned ->
        cleanup_ref = make_ref()
        send(state.worker, {state.open_ref, :cleanup, cleanup_ref})
        true = :erlang.resume_process(state.worker)

        await_candidate_for_cancellation(%{
          state
          | termination: {:cleanup, waiter, cleanup_ref},
            worker_down?: false
        })
    end
  end

  defp cancel_opening(state, waiter) do
    cleanup_ref = make_ref()
    send(state.worker, {state.open_ref, :cleanup, cleanup_ref})
    termination_loop(%{state | termination: {:cleanup, waiter, cleanup_ref}, worker_down?: false})
  end

  defp suspend_opening_worker(state) do
    true = :erlang.suspend_process(state.worker, [:unless_suspending])

    if :atomics.get(state.open_phase, 1) == @candidate_owned or
         worker_has_open_port?(state.worker) do
      :candidate_owned
    else
      :blocked_without_port
    end
  end

  defp worker_has_open_port?(worker) do
    case Process.info(worker, :links) do
      {:links, links} -> Enum.any?(links, &is_port/1)
      nil -> false
    end
  end

  defp await_candidate_for_cancellation(state) do
    receive do
      {open_ref, :candidate, worker, port, os_pid}
      when open_ref == state.open_ref and worker == state.worker ->
        state
        |> register_candidate_for_cancellation(worker, port, os_pid)
        |> termination_loop()
    end
  end

  defp register_candidate_for_cancellation(state, worker, port, os_pid) do
    port_monitor = Port.monitor(port)

    notify_observers(
      state.observers,
      {:candidate_cleanup_registered, self(), worker, port, os_pid}
    )

    %{state | port: port, port_monitor: port_monitor, port_os_pid: os_pid}
  end

  defp cancel_without_candidate_loop(state, waiter) do
    receive do
      {open_ref, :candidate, worker, port, os_pid}
      when open_ref == state.open_ref and worker == state.worker ->
        port_monitor = Port.monitor(port)
        notify_observers(state.observers, {:candidate_opened, self(), worker, port, os_pid})

        cancel_without_candidate_loop(
          %{state | port: port, port_monitor: port_monitor, port_os_pid: os_pid},
          waiter
        )

      {:DOWN, monitor, :port, port, _reason}
      when monitor == state.port_monitor and port == state.port ->
        cancel_without_candidate_loop(%{state | port_down?: true}, waiter)

      {:DOWN, monitor, :process, worker, _reason}
      when monitor == state.worker_monitor and worker == state.worker ->
        if is_nil(state.port) or state.port_down? do
          acknowledge_waiter(waiter, :no_port)
        else
          await_killed_candidate_port(%{state | worker_down?: true}, waiter)
        end
    end
  end

  defp await_killed_candidate_port(state, waiter) do
    receive do
      {:DOWN, monitor, :port, port, _reason}
      when monitor == state.port_monitor and port == state.port ->
        acknowledge_waiter(waiter, :no_port)
    end
  end

  defp runtime_loop(state) do
    receive do
      {open_ref, :port_event, port, event}
      when open_ref == state.open_ref and port == state.port ->
        runtime_loop(forward_port_event(state, event))

      {:DOWN, monitor, :port, port, _reason}
      when monitor == state.port_monitor and port == state.port ->
        runtime_loop(%{state | port_down?: true})

      {:DOWN, monitor, :process, worker, reason}
      when monitor == state.worker_monitor and worker == state.worker ->
        runtime_loop(%{state | worker_down?: true, worker_exit_reason: reason})

      {:cleanup, from, request_ref} ->
        cleanup_ref = make_ref()
        send(state.worker, {state.open_ref, :cleanup, cleanup_ref})
        termination_loop(%{state | termination: {:cleanup, {from, request_ref}, cleanup_ref}})

      {:finish, from, request_ref, status} when status == state.exit_status ->
        finish_ref = make_ref()
        send(state.worker, {state.open_ref, :finish, finish_ref, status})
        termination_loop(%{state | termination: {:finish, {from, request_ref}, finish_ref}})

      {:DOWN, monitor, :process, process, _reason}
      when monitor == state.test_monitor and process == state.test_process ->
        cleanup_ref = make_ref()
        send(state.worker, {state.open_ref, :cleanup, cleanup_ref})
        termination_loop(%{state | test_process: nil, termination: {:cleanup, nil, cleanup_ref}})
    end
  end

  defp termination_loop(state) do
    if termination_complete?(state) do
      complete_termination(state)
    else
      receive do
        {open_ref, :port_event, port, event}
        when open_ref == state.open_ref and port == state.port ->
          termination_loop(forward_port_event(state, event))

        {open_ref, :cleanup_complete, cleanup_ref, status, worker}
        when open_ref == state.open_ref and worker == state.worker ->
          case state.termination do
            {:cleanup, waiter, ^cleanup_ref} ->
              termination_loop(%{
                state
                | cleanup_status: status,
                  termination: {:cleanup, waiter, cleanup_ref}
              })

            _other ->
              termination_loop(state)
          end

        {open_ref, :worker_finished, finish_ref, worker}
        when open_ref == state.open_ref and worker == state.worker ->
          case state.termination do
            {:finish, waiter, ^finish_ref} ->
              termination_loop(%{
                state
                | finish_ack?: true,
                  termination: {:finish, waiter, finish_ref}
              })

            _other ->
              termination_loop(state)
          end

        {:DOWN, monitor, :port, port, _reason}
        when monitor == state.port_monitor and port == state.port ->
          termination_loop(%{state | port_down?: true})

        {:DOWN, monitor, :process, worker, reason}
        when monitor == state.worker_monitor and worker == state.worker ->
          termination_loop(%{state | worker_down?: true, worker_exit_reason: reason})
      end
    end
  end

  defp termination_complete?(state) do
    state.port_down? and state.worker_down? and
      case state.termination do
        {:cleanup, _waiter, _ref} -> is_integer(Map.get(state, :cleanup_status))
        {:finish, _waiter, _ref} -> Map.get(state, :finish_ack?, false)
      end
  end

  defp complete_termination(state) do
    case state.termination do
      {:cleanup, waiter, _ref} -> acknowledge_waiter(waiter, state.cleanup_status)
      {:finish, {from, request_ref}, _ref} -> send(from, {request_ref, :ok})
    end

    await_owner_exit_barrier(state)
  end

  defp acknowledge_waiter({from, request_ref}, result), do: send(from, {request_ref, result})
  defp acknowledge_waiter(nil, _result), do: :ok

  defp forward_port_event(state, {:data, {:eol, line}} = event) do
    send_if_present(state.test_process, {state.port, event})
    notify_observers(state.observers, {:port_event, state.port, event})
    %{state | reported_os_pid: reported_pid(line) || state.reported_os_pid}
  end

  defp forward_port_event(state, {:data, _data} = event) do
    send_if_present(state.test_process, {state.port, event})
    notify_observers(state.observers, {:port_event, state.port, event})
    state
  end

  defp forward_port_event(state, {:exit_status, status} = event) do
    send_if_present(state.test_process, {state.port, event})
    notify_observers(state.observers, {:external_exit, state.port, status})
    %{state | exit_status: status}
  end

  defp notify_observers(observers, event) do
    Enum.each(observers, fn {observer, observer_ref} -> send(observer, {observer_ref, event}) end)
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
    %{
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
