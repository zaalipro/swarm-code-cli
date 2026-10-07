defmodule SwarmCodeCLI.UI.OsCommand do
  @moduledoc """
  cli020 lane D: one bounded external command (`osascript`, `pbcopy`,
  `sips`) for the session runtime's owned tasks. The command runs through a
  Port the calling process owns, its output is kept up to a byte bound while
  it is read, and past the deadline the OS process is killed, so a stuck tool
  never outlives the task that started it. No shell is involved unless the
  caller names one.
  """

  @max_output 65_536

  @type result ::
          {:ok, non_neg_integer(), binary()} | {:error, :timeout | :unavailable}

  @doc """
  Runs `executable` (an absolute path) with `args` and waits at most
  `timeout_ms` for its exit status. Returns the status and at most 64 KiB of
  its output (stdout and stderr together).
  """
  @spec run(Path.t(), [binary()], pos_integer()) :: result()
  def run(executable, args, timeout_ms)
      when is_binary(executable) and is_list(args) and is_integer(timeout_ms) and timeout_ms > 0 do
    if Path.type(executable) == :absolute and File.regular?(executable) do
      port =
        Port.open({:spawn_executable, executable}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          :hide,
          args: args
        ])

      deadline = System.monotonic_time(:millisecond) + timeout_ms
      collect(port, deadline, [], 0)
    else
      {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  defp collect(port, deadline, acc, bytes) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        room = max(@max_output - bytes, 0)
        kept = binary_part(data, 0, min(byte_size(data), room))
        collect(port, deadline, [kept | acc], bytes + byte_size(kept))

      {^port, {:exit_status, status}} ->
        {:ok, status, acc |> Enum.reverse() |> IO.iodata_to_binary()}
    after
      left ->
        kill(port)
        {:error, :timeout}
    end
  end

  defp kill(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) -> :os.cmd(~c"kill -KILL #{pid} 2>/dev/null")
      _ -> :ok
    end

    Port.close(port)
  catch
    _, _ -> :ok
  end
end
