defmodule SwarmCode.Daemon.Platform.PhysicalPath do
  @moduledoc false

  import Bitwise

  @maximum_path_bytes 16 * 1_024
  @command_timeout 5_000

  @type resolved :: %{path: Path.t(), stat: File.Stat.t()}

  @spec resolve_regular(Path.t()) :: {:ok, resolved()} | {:error, term()}
  def resolve_regular(path), do: resolve(path, :regular)

  @spec resolve_directory(Path.t()) :: {:ok, resolved()} | {:error, term()}
  def resolve_directory(path), do: resolve(path, :directory)

  defp resolve(path, expected_type)
       when is_binary(path) and byte_size(path) in 1..@maximum_path_bytes//1 do
    with :ok <- safe_path_text(path),
         {:ok, %File.Stat{type: ^expected_type} = original_stat} <- File.lstat(path),
         {:ok, canonical} <- realpath(path),
         true <- Path.type(canonical) == :absolute,
         {:ok, %File.Stat{type: ^expected_type} = canonical_stat} <- File.lstat(canonical),
         true <- same_object?(original_stat, canonical_stat) do
      {:ok, %{path: canonical, stat: canonical_stat}}
    else
      _other -> {:error, :physical_path_resolution_failed}
    end
  end

  defp resolve(_path, _expected_type), do: {:error, :physical_path_resolution_failed}

  defp safe_path_text(path) do
    if String.valid?(path) and not String.contains?(path, [<<0>>, "\n", "\r"]),
      do: :ok,
      else: {:error, :unsafe_path_text}
  end

  defp realpath(path) do
    with {:ok, executable} <- realpath_executable(),
         {:ok, port} <- open_realpath(executable, path) do
      try do
        collect_realpath(port, nil, monotonic_deadline())
      after
        close_port(port)
      end
    end
  end

  defp realpath_executable do
    candidates =
      case :os.type() do
        {:unix, :darwin} -> ["/bin/realpath"]
        {:unix, :linux} -> ["/usr/bin/realpath", "/bin/realpath"]
        _other -> []
      end

    case Enum.find(candidates, &regular_executable?/1) do
      nil -> {:error, :realpath_unavailable}
      executable -> {:ok, executable}
    end
  end

  defp regular_executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> band(mode, 0o111) != 0
      _other -> false
    end
  end

  defp open_realpath(executable, path) do
    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [
          :binary,
          :exit_status,
          :hide,
          :use_stdio,
          :stderr_to_stdout,
          {:args, [~c"--", String.to_charlist(path)]},
          {:line, @maximum_path_bytes}
        ]
      )

    {:ok, port}
  rescue
    _error -> {:error, :realpath_start_failed}
  end

  defp collect_realpath(port, output, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, {:eol, line}}} when is_binary(line) and is_nil(output) ->
        collect_realpath(port, line, deadline)

      {^port, {:data, _extra_or_overlong_output}} ->
        {:error, :invalid_realpath_output}

      {^port, {:exit_status, 0}} when is_binary(output) and byte_size(output) > 0 ->
        {:ok, output}

      {^port, {:exit_status, _status}} ->
        {:error, :realpath_failed}
    after
      timeout -> {:error, :realpath_timeout}
    end
  end

  defp monotonic_deadline,
    do: System.monotonic_time(:millisecond) + @command_timeout

  defp close_port(port) do
    case Port.info(port) do
      nil -> :ok
      _info -> Port.close(port)
    end
  rescue
    _error -> :ok
  end

  defp same_object?(left, right) do
    {left.type, left.major_device, left.minor_device, left.inode} ==
      {right.type, right.major_device, right.minor_device, right.inode}
  end
end
