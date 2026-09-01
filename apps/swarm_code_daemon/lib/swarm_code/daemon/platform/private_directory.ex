defmodule SwarmCode.Daemon.Platform.PrivateDirectory do
  @moduledoc false

  import Bitwise

  @private_mode 0o700

  @spec ensure(Path.t(), non_neg_integer()) ::
          :ok | {:error, {:unsafe_private_directory, Path.t(), atom()}}
  def ensure(path, uid) when is_binary(path) and is_integer(uid) and uid >= 0 do
    case File.lstat(path) do
      {:ok, stat} ->
        secure_existing(path, uid, stat)

      {:error, :enoent} ->
        create(path, uid)

      {:error, reason} ->
        unsafe(path, reason)
    end
  end

  defp create(path, uid) do
    case File.mkdir(path) do
      :ok ->
        with {:ok, stat} <- lstat(path),
             :ok <- validate_directory(path, stat, uid) do
          chmod_and_verify(path, uid)
        end

      {:error, :eexist} ->
        with {:ok, stat} <- lstat(path) do
          secure_existing(path, uid, stat)
        end

      {:error, reason} ->
        unsafe(path, reason)
    end
  end

  defp secure_existing(path, uid, stat) do
    with :ok <- validate_directory(path, stat, uid) do
      chmod_and_verify(path, uid)
    end
  end

  defp chmod_and_verify(path, uid) do
    case File.chmod(path, @private_mode) do
      :ok ->
        with {:ok, stat} <- lstat(path),
             :ok <- validate_directory(path, stat, uid),
             true <- band(stat.mode, 0o777) == @private_mode do
          :ok
        else
          false -> unsafe(path, :wrong_mode)
          {:error, _reason} = error -> error
        end

      {:error, reason} ->
        unsafe(path, reason)
    end
  end

  defp validate_directory(path, %File.Stat{type: :symlink}, _uid), do: unsafe(path, :symlink)

  defp validate_directory(path, %File.Stat{type: type}, _uid) when type != :directory,
    do: unsafe(path, :not_directory)

  defp validate_directory(path, %File.Stat{uid: actual_uid}, expected_uid)
       when actual_uid != expected_uid,
       do: unsafe(path, :wrong_owner)

  defp validate_directory(_path, %File.Stat{}, _uid), do: :ok

  defp lstat(path) do
    case File.lstat(path) do
      {:ok, stat} -> {:ok, stat}
      {:error, reason} -> unsafe(path, reason)
    end
  end

  defp unsafe(path, reason), do: {:error, {:unsafe_private_directory, path, reason}}
end
