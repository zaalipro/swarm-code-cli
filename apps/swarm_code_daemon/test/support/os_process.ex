defmodule SwarmCode.Daemon.Test.OSProcess do
  @moduledoc false

  @timeout 5_000
  @owner_key {__MODULE__, :owner}

  @spec start_lease_probe!(Path.t()) :: port()
  def start_lease_probe!(dir) when is_binary(dir) do
    test_process = self()
    start_ref = make_ref()
    executable = System.find_executable("elixir") || raise "elixir executable not found"
    probe_path = Path.expand("lease_probe.exs", __DIR__)
    encoded_opts = encode_opts!(dir)

    owner =
      spawn(fn ->
        open_and_own(test_process, start_ref, executable, probe_path, encoded_opts)
      end)

    receive do
      {^start_ref, ^owner, {:ok, port}} ->
        :persistent_term.put({@owner_key, port}, owner)
        port

      {^start_ref, ^owner, {:error, reason}} ->
        raise "could not start lease probe: #{Exception.format_exit(reason)}"
    after
      @timeout ->
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
    receive do
      {^port, {:exit_status, status}} when is_integer(status) and status >= 0 ->
        finish_owner!(port, status)
        status

      {^port, {:data, data}} ->
        raise "lease probe emitted output while awaiting exit: #{inspect(data)}"
    after
      @timeout ->
        raise "timed out awaiting lease probe exit"
    end
  end

  @spec close_and_reap!(port()) :: :ok
  def close_and_reap!(port) when is_port(port) do
    case owner_for(port) do
      nil ->
        :ok

      owner ->
        request_ref = make_ref()
        monitor = Process.monitor(owner)
        send(owner, {:cleanup, self(), request_ref})

        receive do
          {^request_ref, status} when is_integer(status) and status >= 0 ->
            Process.demonitor(monitor, [:flush])
            erase_owner(port)
            :ok

          {:DOWN, ^monitor, :process, ^owner, reason} ->
            erase_owner(port)
            raise "lease probe owner exited before reaping its port: #{inspect(reason)}"
        after
          @timeout ->
            Process.demonitor(monitor, [:flush])
            raise "timed out closing and reaping lease probe"
        end
    end
  end

  defp await_message!(port, phase) do
    receive do
      {^port, {:data, {:eol, line}}} when is_binary(line) ->
        line

      {^port, {:data, data}} ->
        raise "lease probe emitted an incomplete #{phase} line: #{inspect(data)}"

      {^port, {:exit_status, status}} ->
        finish_owner!(port, status)
        raise "lease probe exited with status #{status} before #{phase}"
    after
      @timeout ->
        raise "timed out awaiting lease probe #{phase}"
    end
  end

  defp finish_owner!(port, status) do
    case owner_for(port) do
      nil ->
        :ok

      owner ->
        request_ref = make_ref()
        monitor = Process.monitor(owner)
        send(owner, {:finish, self(), request_ref, status})

        receive do
          {^request_ref, :ok} ->
            Process.demonitor(monitor, [:flush])
            erase_owner(port)

          {:DOWN, ^monitor, :process, ^owner, :normal} ->
            erase_owner(port)

          {:DOWN, ^monitor, :process, ^owner, reason} ->
            erase_owner(port)
            raise "lease probe owner exited unexpectedly: #{inspect(reason)}"
        after
          @timeout ->
            Process.demonitor(monitor, [:flush])
            raise "timed out finalizing lease probe port"
        end
    end
  end

  defp open_and_own(test_process, start_ref, executable, probe_path, encoded_opts) do
    try do
      port =
        Port.open(
          {:spawn_executable, executable},
          [
            :binary,
            :exit_status,
            {:line, 4096},
            args: code_path_args() ++ [probe_path, encoded_opts]
          ]
        )

      test_monitor = Process.monitor(test_process)
      send(test_process, {start_ref, self(), {:ok, port}})
      owner_loop(port, test_process, test_monitor, nil, nil, nil)
    rescue
      error -> send(test_process, {start_ref, self(), {:error, {:exception, error}}})
    catch
      kind, reason -> send(test_process, {start_ref, self(), {:error, {kind, reason}}})
    end
  end

  defp owner_loop(port, test_process, test_monitor, os_pid, exit_status, cleanup) do
    receive do
      {^port, {:data, {:eol, line}} = event} ->
        send_if_present(test_process, {port, event})
        os_pid = reported_pid(line) || os_pid
        maybe_start_cleanup(port, test_process, test_monitor, os_pid, exit_status, cleanup)

      {^port, {:data, _data} = event} ->
        send_if_present(test_process, {port, event})
        owner_loop(port, test_process, test_monitor, os_pid, exit_status, cleanup)

      {^port, {:exit_status, status} = event} ->
        send_if_present(test_process, {port, event})
        complete_cleanup_or_loop(port, test_process, test_monitor, os_pid, status, cleanup)

      {:finish, from, request_ref, ^exit_status} when is_integer(exit_status) ->
        send(from, {request_ref, :ok})

      {:finish, from, request_ref, reported_status} ->
        send(from, {request_ref, {:status_mismatch, exit_status, reported_status}})
        owner_loop(port, test_process, test_monitor, os_pid, exit_status, cleanup)

      {:cleanup, from, request_ref} when is_integer(exit_status) ->
        send(from, {request_ref, exit_status})

      {:cleanup, from, request_ref} ->
        maybe_start_cleanup(
          port,
          test_process,
          test_monitor,
          os_pid,
          exit_status,
          {from, request_ref}
        )

      {:DOWN, ^test_monitor, :process, ^test_process, _reason} ->
        owner_loop(port, nil, nil, os_pid, exit_status, cleanup)
    end
  end

  defp maybe_start_cleanup(port, test_process, test_monitor, nil, exit_status, cleanup) do
    owner_loop(port, test_process, test_monitor, nil, exit_status, cleanup)
  end

  defp maybe_start_cleanup(port, test_process, test_monitor, os_pid, exit_status, cleanup) do
    if cleanup do
      _ = System.cmd("/bin/kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
      owner_loop(port, test_process, test_monitor, os_pid, exit_status, cleanup)
    else
      owner_loop(port, test_process, test_monitor, os_pid, exit_status, nil)
    end
  end

  defp complete_cleanup_or_loop(_port, _test_process, _test_monitor, _os_pid, status, {from, ref}) do
    send(from, {ref, status})
  end

  defp complete_cleanup_or_loop(port, test_process, test_monitor, os_pid, status, nil) do
    owner_loop(port, test_process, test_monitor, os_pid, status, nil)
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

  defp encode_opts!(dir) do
    opts = %{
      "app_version" => "0.1.0-dev",
      "database_fingerprint" => "sha256:os-process-test",
      "lease_path" => Path.join(dir, "instance_lease.db"),
      "manifest_sha256" => "408afb8e6eb422c8df50fe65536a08f853475c162d584db45b4af708274fd1d0",
      "newest_migration" => 20_260_926_000_000,
      "owner_path" => Path.join(dir, "instance_owner.json"),
      "schema_epoch" => 0,
      "socket_path" => Path.join(dir, "daemon.sock"),
      "uid" => File.lstat!(dir).uid
    }

    opts
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp owner_for(port), do: :persistent_term.get({@owner_key, port}, nil)
  defp erase_owner(port), do: :persistent_term.erase({@owner_key, port})
end
