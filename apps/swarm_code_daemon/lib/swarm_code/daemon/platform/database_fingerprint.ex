defmodule SwarmCode.Daemon.Platform.DatabaseFingerprint do
  @moduledoc false

  @prefix "sqlite-file-v1:"
  @maximum_symlink_hops 40

  @spec for_path(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def for_path(path) when is_binary(path) do
    with {:ok, canonical_path} <- canonical_path(path) do
      case File.lstat(canonical_path) do
        {:ok, %File.Stat{type: :regular} = stat} ->
          payload = [
            "swarm-code-sqlite-file-fingerprint\n",
            "version=1\n",
            "path=",
            Integer.to_string(byte_size(canonical_path)),
            ?:,
            canonical_path,
            ?\n,
            "device=",
            Integer.to_string(stat.major_device),
            ?:,
            Integer.to_string(stat.minor_device),
            ?\n,
            "inode=",
            Integer.to_string(stat.inode),
            ?\n
          ]

          digest =
            :crypto.hash(:sha256, payload)
            |> Base.encode16(case: :lower)

          {:ok, @prefix <> digest}

        {:ok, _stat} ->
          {:error, :database_not_regular}

        {:error, reason} ->
          {:error, {:database_lstat_failed, reason}}
      end
    end
  end

  def for_path(_path), do: {:error, :invalid_database_path}

  defp canonical_path(path) do
    expanded = Path.expand(path)

    with {:ok, directory} <- resolve_directory(Path.dirname(expanded), 0) do
      {:ok, Path.join(directory, Path.basename(expanded))}
    end
  end

  defp resolve_directory(_path, hops) when hops > @maximum_symlink_hops,
    do: {:error, :too_many_directory_symlinks}

  defp resolve_directory(path, hops) do
    case Path.split(Path.expand(path)) do
      [root | components] -> resolve_components(root, components, hops)
      [] -> {:error, :invalid_database_path}
    end
  end

  defp resolve_components(current, [], _hops) do
    case File.lstat(current) do
      {:ok, %File.Stat{type: :directory}} -> {:ok, current}
      {:ok, _stat} -> {:error, :database_parent_not_directory}
      {:error, reason} -> {:error, {:database_parent_lstat_failed, reason}}
    end
  end

  defp resolve_components(current, [component | remaining], hops) do
    candidate = Path.join(current, component)

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} ->
        with {:ok, target} <- File.read_link(candidate) do
          target =
            if Path.type(target) == :absolute,
              do: Path.expand(target),
              else: Path.expand(target, current)

          target
          |> append_components(remaining)
          |> resolve_directory(hops + 1)
        end

      {:ok, %File.Stat{type: :directory}} ->
        resolve_components(candidate, remaining, hops)

      {:ok, _stat} ->
        {:error, :database_parent_not_directory}

      {:error, reason} ->
        {:error, {:database_parent_lstat_failed, reason}}
    end
  end

  defp append_components(path, components),
    do: Enum.reduce(components, path, &Path.join(&2, &1))
end
