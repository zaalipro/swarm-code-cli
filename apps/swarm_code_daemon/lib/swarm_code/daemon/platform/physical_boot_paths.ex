defmodule SwarmCode.Daemon.Platform.PhysicalBootPaths do
  @moduledoc false
  import Bitwise
  alias SwarmCode.Daemon.Platform.PathSet

  # This is deliberately not realpath: only the existing trusted macOS system
  # alias may resolve, and every physical component is checked without following
  # any other link. Native admission subsequently retains and verifies the chain.
  def admit(%PathSet{} = paths) do
    with {:ok, runtime} <- resolve(paths.runtime, paths.platform),
         {:ok, data} <- resolve(paths.data, paths.platform),
         true <- length(Path.split(runtime)) + length(Path.split(data)) <= 128 do
      {:ok, %{runtime: runtime, data: data}}
    else
      _other -> {:error, :unsafe_physical_paths}
    end
  end

  def resolve(path, platform) when is_binary(path) and platform in [:macos, :linux] do
    with true <- canonical?(path),
         {:ok, physical} <- translate_var(path, platform),
         true <- canonical?(physical),
         :ok <- physical_chain(physical) do
      {:ok, physical}
    else
      _other -> {:error, :unsafe_physical_path}
    end
  end

  def resolve(_path, _platform), do: {:error, :unsafe_physical_path}

  defp canonical?(path) do
    byte_size(path) in 2..4095 and String.valid?(path) and
      not String.contains?(path, [<<0>>, "\n", "\r"]) and
      Path.type(path) == :absolute and Path.expand(path) == path and
      Enum.all?(Path.split(path), &(byte_size(&1) <= 255))
  end

  defp translate_var(path, :macos) when path == "/var" or binary_part(path, 0, 5) == "/var/" do
    with {:ok, %File.Stat{type: :symlink, uid: 0}} <- File.lstat("/var"),
         {:ok, target} <- File.read_link("/var"),
         true <- target in ["private/var", "/private/var"],
         :ok <- trusted_directory("/private"),
         :ok <- trusted_directory("/private/var") do
      {:ok, "/private/var" <> String.replace_prefix(path, "/var", "")}
    else
      # A physical /var (for example on Linux) needs no alias privilege.
      _other -> {:ok, path}
    end
  end

  defp translate_var(path, _platform), do: {:ok, path}

  defp trusted_directory(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory, uid: 0, mode: mode}} when band(mode, 0o022) == 0 -> :ok
      _other -> {:error, :untrusted_system_alias}
    end
  end

  defp physical_chain(path) do
    [_root | components] = Path.split(path)

    Enum.reduce_while(components, {:ok, "/"}, fn component, {:ok, parent} ->
      next = Path.join(parent, component)

      case File.lstat(next) do
        {:ok, %File.Stat{type: :directory}} -> {:cont, {:ok, next}}
        _other -> {:halt, {:error, :nonphysical_component}}
      end
    end)
    |> case do
      {:ok, _path} -> :ok
      error -> error
    end
  end
end
