defmodule SwarmCodeCLI.Release.SocketSweep do
  @moduledoc """
  cli020 B10 (bugs-15): the private socket folders a hard exit (kill -9, a
  crash, a lost machine) left in /tmp are removed when the next session
  starts.

  A folder is removed only when all hold: its name starts `scl-p-` (TUI) or
  `scl-h-` (headless), it is a real directory (not a link) of this user, it
  is older than 60 s, and its socket `s` is missing or refuses a connection
  (no live session behind it). Its inode and device are compared again just
  before `rmdir`, as the sessions' own close does.
  """

  @prefixes ["scl-p-", "scl-h-"]
  @min_age_s 60
  @connect_ms 500

  @doc "Sweeps `base` (default /tmp); returns the folders it removed."
  @spec sweep(Path.t(), integer(), keyword()) :: [Path.t()]
  def sweep(base \\ "/tmp", now \\ System.os_time(:second), opts \\ []) do
    uid = Keyword.get_lazy(opts, :uid, &own_uid/0)

    case File.ls(base) do
      {:ok, names} ->
        for name <- names,
            String.starts_with?(name, @prefixes),
            dir = Path.join(base, name),
            remove?(dir, uid, now),
            do: dir

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp remove?(dir, uid, now) do
    with {:ok, %File.Stat{type: :directory, uid: ^uid, mtime: mtime} = stat}
         when is_integer(mtime) <- File.lstat(dir, time: :posix),
         true <- now - mtime > @min_age_s,
         false <- live?(Path.join(dir, "s")) do
      _ = File.rm(Path.join(dir, "s"))

      case File.lstat(dir) do
        {:ok, current}
        when current.inode == stat.inode and current.major_device == stat.major_device and
               current.type == :directory ->
          File.rmdir(dir) == :ok

        _ ->
          false
      end
    else
      _ -> false
    end
  end

  # A socket that accepts is a live session; anything else is not.
  defp live?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :other}} ->
        case :gen_tcp.connect({:local, path}, 0, [:binary, active: false], @connect_ms) do
          {:ok, socket} ->
            :gen_tcp.close(socket)
            true

          {:error, :timeout} ->
            true

          {:error, _} ->
            false
        end

      {:ok, _} ->
        # Something other than a socket: not ours to remove.
        true

      {:error, :enoent} ->
        false

      _ ->
        true
    end
  end

  defp own_uid do
    case File.lstat(System.user_home!()) do
      {:ok, %File.Stat{uid: uid}} -> uid
      _ -> -1
    end
  end
end
