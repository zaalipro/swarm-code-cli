defmodule SwarmCode.Daemon.Platform.ExternalCommand do
  @moduledoc false

  @default_timeout 5_000
  @default_terminate_grace 250
  @default_kill_grace 2_000
  @maximum_argument_bytes 16 * 1_024
  @maximum_aggregate_argument_bytes 64 * 1_024
  @maximum_line_bytes 16 * 1_024
  @maximum_timeout 300_000
  @test_build Mix.env() == :test
  @allowed_options if(@test_build,
                     do: [
                       :cwd,
                       :kill_grace,
                       :max_line_bytes,
                       :observer,
                       :terminate_grace,
                       :test_after_port_open,
                       :test_before_terminate,
                       :test_fail_after_port_open,
                       :test_signal_executable,
                       :timeout
                     ],
                     else: [
                       :cwd,
                       :kill_grace,
                       :max_line_bytes,
                       :observer,
                       :terminate_grace,
                       :timeout
                     ]
                   )

  @spec run(Path.t(), [String.t()], keyword()) :: {:ok, String.t()} | {:error, atom()}
  def run(executable, args, opts \\ []) do
    with {:ok, config} <- validate(executable, args, opts) do
      requester = self()
      request_ref = make_ref()

      {owner, owner_monitor} =
        spawn_monitor(fn -> command_owner(requester, request_ref, config) end)

      receive do
        {^request_ref, ^owner, result} ->
          Process.demonitor(owner_monitor, [:flush])
          result

        {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
          {:error, :command_owner_failed}
      end
    end
  end

  defp command_owner(requester, request_ref, config) do
    requester_monitor = Process.monitor(requester)

    case open_port(config) do
      {:ok, port, port_monitor, os_pid} ->
        notify(config.observer, {:external_command_started, self(), os_pid})

        if config.fail_after_port_open? do
          cleanup_result = terminate_and_await(port, port_monitor, os_pid, empty_state(), config)

          case cleanup_result do
            {:pending, reaper_state} ->
              send_result(requester, request_ref, {:error, :command_cleanup_pending})
              reaper_loop(port, port_monitor, reaper_state, config.observer, os_pid)

            :ok ->
              send_result(requester, request_ref, {:error, :command_start_failed})

            _other ->
              send_result(requester, request_ref, {:error, :command_cleanup_pending})
          end
        else
          run_open_command(
            requester,
            request_ref,
            requester_monitor,
            port,
            port_monitor,
            os_pid,
            config
          )
        end

      {:error, _reason} ->
        send_result(requester, request_ref, {:error, :command_start_failed})
    end
  end

  defp run_open_command(
         requester,
         request_ref,
         requester_monitor,
         port,
         port_monitor,
         os_pid,
         config
       ) do
    state = %{empty_state() | requester: requester, request_ref: request_ref}
    deadline = monotonic_deadline(config.timeout)

    case collect(port, port_monitor, requester_monitor, deadline, state) do
      {:terminal, terminal_state} ->
        notify(config.observer, {:external_command_terminal, os_pid})
        send_result(requester, request_ref, result(terminal_state))

      {:timeout, timeout_state} ->
        invoke_before_terminate(config.before_terminate)

        cleanup_result =
          terminate_and_await(port, port_monitor, os_pid, timeout_state, config)

        case cleanup_result do
          {:pending, reaper_state} ->
            send_result(requester, request_ref, {:error, :command_cleanup_pending})
            reaper_loop(port, port_monitor, reaper_state, config.observer, os_pid)

          :ok ->
            send_result(requester, request_ref, {:error, :command_timeout})

          _other ->
            send_result(requester, request_ref, {:error, :command_cleanup_pending})
        end

      {:command_error, error_state} ->
        cleanup_result = terminate_and_await(port, port_monitor, os_pid, error_state, config)

        case cleanup_result do
          {:pending, reaper_state} ->
            send_result(requester, request_ref, {:error, :command_cleanup_pending})
            reaper_loop(port, port_monitor, reaper_state, config.observer, os_pid)

          :ok ->
            send_result(requester, request_ref, {:error, :command_failed})

          _other ->
            send_result(requester, request_ref, {:error, :command_cleanup_pending})
        end

      {:requester_down, requester_state} ->
        case terminate_and_await(port, port_monitor, os_pid, requester_state, config) do
          {:pending, reaper_state} ->
            reaper_loop(port, port_monitor, reaper_state, config.observer, os_pid)

          _other ->
            :ok
        end
    end
  end

  defp empty_state,
    do: %{
      exit_status: nil,
      eof?: false,
      output: nil,
      port_down?: false,
      requester: nil,
      request_ref: nil
    }

  defp open_port(config) do
    options = [
      :binary,
      :exit_status,
      :eof,
      :hide,
      :use_stdio,
      :stderr_to_stdout,
      {:args, Enum.map(config.args, &String.to_charlist/1)},
      {:line, config.max_line_bytes}
    ]

    options = if config.cwd, do: [{:cd, String.to_charlist(config.cwd)} | options], else: options

    # Retain the Port through a fast child exit so its exact OS PID remains
    # available. Close it only after both output EOF and child exit evidence.
    port = Port.open({:spawn_executable, String.to_charlist(config.executable)}, options)
    port_monitor = Port.monitor(port)
    invoke_after_port_open(config.after_port_open, port)

    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) and os_pid > 0 ->
        {:ok, port, port_monitor, os_pid}

      _other ->
        Port.demonitor(port_monitor, [:flush])
        Port.close(port)
        {:error, :missing_os_pid}
    end
  rescue
    _error -> {:error, :port_open_failed}
  end

  defp collect(port, port_monitor, requester_monitor, deadline, state) do
    if terminal?(state) do
      {:terminal, state}
    else
      timeout = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {^port, {:data, {:eol, line}}} when is_binary(line) and is_nil(state.output) ->
          collect(port, port_monitor, requester_monitor, deadline, %{state | output: line})

        {^port, {:data, _extra_or_overlong_output}} ->
          {:command_error, %{state | output: :invalid}}

        {^port, {:exit_status, status}} when is_integer(status) and status >= 0 ->
          collect(
            port,
            port_monitor,
            requester_monitor,
            deadline,
            close_finished_port(port, %{state | exit_status: status})
          )

        {^port, :eof} ->
          collect(
            port,
            port_monitor,
            requester_monitor,
            deadline,
            close_finished_port(port, %{state | eof?: true})
          )

        {:DOWN, ^port_monitor, :port, ^port, _reason} ->
          collect(port, port_monitor, requester_monitor, deadline, %{state | port_down?: true})

        {:DOWN, ^requester_monitor, :process, _requester, _reason} ->
          {:requester_down, state}

        _other ->
          collect(port, port_monitor, requester_monitor, deadline, state)
      after
        timeout -> {:timeout, state}
      end
    end
  end

  defp terminate_and_await(port, port_monitor, os_pid, state, config) do
    case await_terminal(port, port_monitor, state, 0) do
      {:ok, _terminal_state} ->
        terminal(config.observer, os_pid)

      {:timeout, running_state} ->
        # A retained Port can outlive its child; never signal a PID whose exact
        # exit status is already known while waiting for output EOF or DOWN.
        if is_nil(running_state.exit_status) do
          notify(config.observer, {:external_command_signal, os_pid, :term})
          _signal_result = signal(config.signal_executable, os_pid, "-TERM")
        end

        case await_terminal(port, port_monitor, running_state, config.terminate_grace) do
          {:ok, _terminal_state} ->
            terminal(config.observer, os_pid)

          {:timeout, term_state} ->
            kill_and_await(port, port_monitor, os_pid, term_state, config)
        end
    end
  end

  defp kill_and_await(port, port_monitor, os_pid, state, config) do
    case await_terminal(port, port_monitor, state, 0) do
      {:ok, _terminal_state} ->
        terminal(config.observer, os_pid)

      {:timeout, running_state} ->
        if is_nil(running_state.exit_status) do
          notify(config.observer, {:external_command_signal, os_pid, :kill})
          _signal_result = signal(config.signal_executable, os_pid, "-KILL")
        end

        case await_terminal(port, port_monitor, running_state, config.kill_grace) do
          {:ok, _terminal_state} ->
            terminal(config.observer, os_pid)

          {:timeout, kill_state} ->
            # The caller receives a bounded, typed outcome immediately after
            # TERM/KILL grace expires.  This owner remains the explicit reaper
            # and emits terminal observer evidence only once the exact Port
            # and child exit events arrive.
            {:pending, kill_state}
        end
    end
  end

  defp terminal(observer, os_pid) do
    notify(observer, {:external_command_terminal, os_pid})
    :ok
  end

  defp await_terminal(port, port_monitor, state, timeout) do
    deadline = monotonic_deadline(timeout)
    do_await_terminal(port, port_monitor, state, deadline)
  end

  defp do_await_terminal(port, port_monitor, state, deadline) do
    if terminal?(state) do
      {:ok, state}
    else
      timeout = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {^port, {:data, _output}} ->
          do_await_terminal(port, port_monitor, state, deadline)

        {^port, {:exit_status, status}} when is_integer(status) and status >= 0 ->
          do_await_terminal(
            port,
            port_monitor,
            close_finished_port(port, %{state | exit_status: status}),
            deadline
          )

        {^port, :eof} ->
          do_await_terminal(
            port,
            port_monitor,
            close_finished_port(port, %{state | eof?: true}),
            deadline
          )

        {:DOWN, ^port_monitor, :port, ^port, _reason} ->
          do_await_terminal(port, port_monitor, %{state | port_down?: true}, deadline)

        _other ->
          do_await_terminal(port, port_monitor, state, deadline)
      after
        timeout -> {:timeout, state}
      end
    end
  end

  defp await_terminal_forever(port, port_monitor, state) do
    if terminal?(state) do
      state
    else
      receive do
        {^port, {:data, _output}} ->
          await_terminal_forever(port, port_monitor, state)

        {^port, {:exit_status, status}} when is_integer(status) and status >= 0 ->
          await_terminal_forever(
            port,
            port_monitor,
            close_finished_port(port, %{state | exit_status: status})
          )

        {^port, :eof} ->
          await_terminal_forever(
            port,
            port_monitor,
            close_finished_port(port, %{state | eof?: true})
          )

        {:DOWN, ^port_monitor, :port, ^port, _reason} ->
          await_terminal_forever(port, port_monitor, %{state | port_down?: true})

        _other ->
          await_terminal_forever(port, port_monitor, state)
      end
    end
  end

  # Account for EOF and exit_status independently; close only after both
  # child termination and complete output delivery are established.
  defp close_finished_port(port, %{eof?: true, exit_status: status} = state)
       when is_integer(status) do
    Port.close(port)
    state
  end

  defp close_finished_port(_port, state), do: state

  defp result(%{exit_status: 0, output: output}) when is_binary(output), do: {:ok, output}
  defp result(%{exit_status: 0, output: nil}), do: {:ok, ""}
  defp result(%{exit_status: 0}), do: {:error, :invalid_command_output}
  defp result(%{exit_status: _status}), do: {:error, :command_failed}

  defp terminal?(%{exit_status: status, port_down?: true}) when is_integer(status), do: true
  defp terminal?(_state), do: false

  defp signal(executable, os_pid, signal) do
    case System.cmd(executable, [signal, Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {_output, _status} -> {:error, :signal_failed}
    end
  rescue
    _error -> {:error, :signal_failed}
  catch
    _kind, _reason -> {:error, :signal_failed}
  end

  defp send_result(requester, request_ref, result) do
    send(requester, {request_ref, self(), result})
    :ok
  end

  defp reaper_loop(port, port_monitor, state, observer, os_pid) do
    _terminal_state = await_terminal_forever(port, port_monitor, state)
    terminal(observer, os_pid)
    :ok
  end

  defp notify(nil, _event), do: :ok
  defp notify(observer, event), do: send(observer, event)

  defp validate(executable, args, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    terminate_grace = Keyword.get(opts, :terminate_grace, @default_terminate_grace)
    kill_grace = Keyword.get(opts, :kill_grace, @default_kill_grace)
    max_line_bytes = Keyword.get(opts, :max_line_bytes, @maximum_line_bytes)
    observer = Keyword.get(opts, :observer)
    cwd = Keyword.get(opts, :cwd)
    signal_executable = signal_executable(opts)
    after_port_open = after_port_open(opts)
    before_terminate = before_terminate(opts)
    fail_after_port_open? = fail_after_port_open?(opts)

    with true <- valid_options?(opts),
         true <- valid_executable?(executable),
         true <- valid_args?(args),
         true <- valid_timeout?(timeout),
         true <- valid_timeout?(terminate_grace),
         true <- valid_timeout?(kill_grace),
         true <- is_integer(max_line_bytes) and max_line_bytes in 1..@maximum_line_bytes//1,
         true <- is_nil(observer) or is_pid(observer),
         true <- is_nil(cwd) or is_binary(cwd),
         true <- is_nil(after_port_open) or is_function(after_port_open, 1),
         true <- is_nil(before_terminate) or is_function(before_terminate, 1),
         true <- is_boolean(fail_after_port_open?),
         true <- is_binary(signal_executable) and Path.type(signal_executable) == :absolute do
      {:ok,
       %{
         executable: executable,
         args: args,
         timeout: timeout,
         terminate_grace: terminate_grace,
         kill_grace: kill_grace,
         max_line_bytes: max_line_bytes,
         observer: observer,
         cwd: cwd,
         after_port_open: after_port_open,
         before_terminate: before_terminate,
         fail_after_port_open?: fail_after_port_open?,
         signal_executable: signal_executable
       }}
    else
      _other -> {:error, :invalid_command}
    end
  end

  if @test_build do
    defp after_port_open(opts), do: Keyword.get(opts, :test_after_port_open)
    defp before_terminate(opts), do: Keyword.get(opts, :test_before_terminate)

    defp signal_executable(opts),
      do: Keyword.get(opts, :test_signal_executable, "/bin/kill")

    defp fail_after_port_open?(opts), do: Keyword.get(opts, :test_fail_after_port_open, false)
  else
    defp after_port_open(_opts), do: nil
    defp before_terminate(_opts), do: nil
    defp signal_executable(_opts), do: "/bin/kill"
    defp fail_after_port_open?(_opts), do: false
  end

  defp invoke_after_port_open(nil, _port), do: :ok
  defp invoke_after_port_open(function, port), do: function.(port)

  defp invoke_before_terminate(nil), do: :ok
  defp invoke_before_terminate(function), do: function.(self())

  defp valid_options?(opts) do
    keys = Keyword.keys(opts)

    Keyword.keyword?(opts) and keys == Enum.uniq(keys) and
      Enum.all?(keys, &(&1 in @allowed_options))
  end

  defp valid_executable?(path) when is_binary(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} ->
        Path.type(path) == :absolute and Bitwise.band(mode, 0o111) != 0

      _other ->
        false
    end
  end

  defp valid_executable?(_path), do: false

  defp valid_args?(args) when is_list(args) do
    Enum.all?(args, fn arg ->
      is_binary(arg) and String.valid?(arg) and not String.contains?(arg, <<0>>) and
        byte_size(arg) <= @maximum_argument_bytes
    end) and Enum.sum(Enum.map(args, &byte_size/1)) <= @maximum_aggregate_argument_bytes
  end

  defp valid_args?(_args), do: false

  defp valid_timeout?(value),
    do: is_integer(value) and value in 1..@maximum_timeout//1

  defp monotonic_deadline(timeout),
    do: System.monotonic_time(:millisecond) + timeout
end
