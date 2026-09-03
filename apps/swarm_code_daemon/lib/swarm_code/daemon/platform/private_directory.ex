defmodule SwarmCode.Daemon.Platform.PrivateDirectory do
  @moduledoc false

  import Bitwise

  @private_mode 0o700
  @trusted_system_symlink_ancestors ["/var"]

  @spec ensure(Path.t(), non_neg_integer()) ::
          :ok | {:error, {:unsafe_private_directory, Path.t(), atom()}}
  def ensure(path, uid) when is_binary(path) and is_integer(uid) and uid >= 0 do
    ensure(path, uid, [])
  end

  @doc false
  @spec ensure(Path.t(), non_neg_integer(), keyword()) ::
          :ok | {:error, {:unsafe_private_directory, Path.t(), atom()}}
  def ensure(path, uid, opts)
      when is_binary(path) and is_integer(uid) and uid >= 0 and is_list(opts) do
    mkdir = Keyword.get(opts, :mkdir, &File.mkdir/1)

    case validate_ancestors(path, uid) do
      :ok ->
        case File.lstat(path) do
          {:ok, stat} ->
            validate_directory(path, stat, uid)

          {:error, :enoent} ->
            create(path, uid, mkdir)

          {:error, reason} ->
            unsafe(path, reason)
        end

      {:error, reason} ->
        unsafe(path, reason)
    end
  end

  defp create(path, uid, mkdir) do
    case mkdir.(path) do
      :ok ->
        validate_path(path, uid)

      {:error, :eexist} ->
        validate_path(path, uid)

      {:error, reason} ->
        unsafe(path, reason)
    end
  end

  defp validate_path(path, uid) do
    case File.lstat(path) do
      {:ok, stat} -> validate_directory(path, stat, uid)
      {:error, reason} -> unsafe(path, reason)
    end
  end

  defp validate_directory(path, %File.Stat{type: :symlink}, _uid), do: unsafe(path, :symlink)

  defp validate_directory(path, %File.Stat{type: type}, _uid) when type != :directory,
    do: unsafe(path, :not_directory)

  defp validate_directory(path, %File.Stat{uid: actual_uid}, expected_uid)
       when actual_uid != expected_uid,
       do: unsafe(path, :wrong_owner)

  defp validate_directory(path, %File.Stat{mode: mode}, _uid)
       when band(mode, 0o7777) != @private_mode,
       do: unsafe(path, :permissions)

  defp validate_directory(_path, %File.Stat{}, _uid), do: :ok

  defp validate_ancestors(path, _uid) do
    components = Path.split(Path.expand(path))
    root = hd(components)

    components
    |> Enum.drop(-1)
    |> Enum.reduce_while(root, fn component, prefix ->
      next = Path.join(prefix, component)

      case File.lstat(next) do
        {:ok, %File.Stat{type: :symlink}} when next in @trusted_system_symlink_ancestors ->
          {:cont, next}

        {:ok, %File.Stat{type: :symlink}} ->
          {:halt, {:error, :symlink}}

        {:ok, %File.Stat{type: :directory}} ->
          {:cont, next}

        {:ok, _other} ->
          {:halt, {:error, :not_directory}}

        {:error, :enoent} ->
          {:halt, :error}

        {:error, _reason} ->
          {:halt, {:error, :ancestor_unavailable}}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      :error -> :ok
      _prefix -> :ok
    end
  end

  defp unsafe(path, reason), do: {:error, {:unsafe_private_directory, path, reason}}
end
