defmodule SwarmCode.Daemon.Service.ClipboardInbox do
  @moduledoc """
  cli020 C14 (competitors-6, decision 4i): where a pasted clipboard image
  lands before it is staged.

  The terminal cannot send an image over the wire, so it asks for a slot
  (`attachment.slot`): a random token and the file it may write,
  `<config_dir>/cli-inbox/<token>.png` (directory 0700). The terminal writes
  the PNG there (`osascript`/`sips`), then sends `attachment.attach_slot` with
  the token only: the path is always rebuilt here from an open slot of this
  session, never taken from the client. The file must be a regular file (not a
  symlink), 1..`Attachments.max_bytes/0` bytes, and start with the PNG
  signature; it is removed on every path (staged, refused, crashed).

  A session holds at most 4 open slots; a slot expires after 60 s. A starting
  backend removes inbox files older than an hour (a session that crashed
  between the two requests).

  The slots are plain data in the backend's state (`%{token => expires_at}`,
  monotonic milliseconds); this module holds no process.
  """
  alias SwarmCode.Domain.{Attachments, Paths}

  @max_slots 4
  @slot_ms 60_000
  @stale_s 3_600
  @png <<137, 80, 78, 71, 13, 10, 26, 10>>

  @type slots :: %{String.t() => integer()}

  @doc "The inbox directory, `<config_dir>/cli-inbox`."
  @spec dir() :: Path.t()
  def dir, do: Path.join(Paths.config_dir(), "cli-inbox")

  @doc "The file of `token` (a validated token only)."
  @spec path(String.t()) :: Path.t()
  def path(token), do: Path.join(dir(), token <> ".png")

  @doc "Whether `token` has the shape of a slot token (32 lowercase hex)."
  @spec token?(term()) :: boolean()
  def token?(token), do: is_binary(token) and Regex.match?(~r/\A[0-9a-f]{32}\z/, token)

  @doc """
  Opens a slot: `{:ok, %{"token" => t, "path" => p}, slots}`, or
  `{:error, :capacity_exceeded}` when 4 are open. Expired slots are closed
  (and their files removed) first.
  """
  @spec open(slots(), integer()) :: {:ok, map(), slots()} | {:error, term()}
  def open(slots, now) do
    slots = expire(slots, now)

    cond do
      map_size(slots) >= @max_slots ->
        {:error, :capacity_exceeded}

      true ->
        token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

        # The file exists, empty and 0600, before the terminal writes it.
        with :ok <- ensure_dir(),
             :ok <- File.write(path(token), "", [:exclusive]),
             :ok <- File.chmod(path(token), 0o600) do
          {:ok, %{"token" => token, "path" => path(token)}, Map.put(slots, token, now + @slot_ms)}
        else
          _ -> {:error, :source_unavailable}
        end
    end
  end

  @doc """
  Takes the image of an open slot: `{:ok, png_binary, slots}` or
  `{:error, reason, slots}` (`:invalid_argument` for a token that is not an
  open slot of this session, a symlink, a non-regular file or a file that is
  not a PNG; `:too_large`). The slot is closed and its file removed either way.
  """
  @spec take(slots(), term(), integer()) ::
          {:ok, binary(), slots()} | {:error, atom(), slots()}
  def take(slots, token, now) do
    slots = expire(slots, now)

    if token?(token) and Map.has_key?(slots, token) do
      file = path(token)

      try do
        case read(file) do
          {:ok, binary} -> {:ok, binary, Map.delete(slots, token)}
          {:error, reason} -> {:error, reason, Map.delete(slots, token)}
        end
      after
        File.rm(file)
      end
    else
      {:error, :invalid_argument, slots}
    end
  end

  defp read(file) do
    max = Attachments.max_bytes()

    case File.lstat(file) do
      {:ok, %File.Stat{type: :regular, size: size}} when size > max ->
        {:error, :too_large}

      {:ok, %File.Stat{type: :regular, size: size}} when size > 0 ->
        with {:ok, binary} <- File.read(file),
             true <- byte_size(binary) <= max or {:error, :too_large},
             @png <> _ <- binary do
          {:ok, binary}
        else
          {:error, :too_large} -> {:error, :too_large}
          _ -> {:error, :invalid_argument}
        end

      _ ->
        {:error, :invalid_argument}
    end
  end

  @doc "Closes every slot (the session ends) and removes their files."
  @spec close_all(slots()) :: :ok
  def close_all(slots) do
    Enum.each(Map.keys(slots), &File.rm(path(&1)))
    :ok
  end

  @doc """
  Removes inbox files last modified more than an hour before `now` (a
  `DateTime`); the count removed. Only `<32 hex>.png` regular files are
  touched.
  """
  @spec sweep(DateTime.t()) :: non_neg_integer()
  def sweep(now \\ DateTime.utc_now()) do
    cutoff = DateTime.to_unix(now) - @stale_s

    case File.ls(dir()) do
      {:ok, names} ->
        Enum.count(names, fn name ->
          with true <- token?(Path.rootname(name)) and Path.extname(name) == ".png",
               file = Path.join(dir(), name),
               {:ok, %File.Stat{type: :regular, mtime: mtime}} <- File.lstat(file, time: :posix),
               true <- mtime < cutoff,
               :ok <- File.rm(file) do
            true
          else
            _ -> false
          end
        end)

      _ ->
        0
    end
  end

  defp expire(slots, now) do
    {gone, open} = Enum.split_with(slots, fn {_token, expires} -> expires <= now end)
    Enum.each(gone, fn {token, _} -> File.rm(path(token)) end)
    Map.new(open)
  end

  defp ensure_dir do
    dir = dir()

    with :ok <- File.mkdir_p(dir), do: File.chmod(dir, 0o700)
  end

  @doc "The file name a staged clipboard image gets: `clipboard-HHMMSS.png`."
  @spec name(DateTime.t()) :: String.t()
  def name(now \\ DateTime.utc_now()) do
    time = now |> DateTime.to_time() |> Time.truncate(:second) |> Time.to_iso8601()
    "clipboard-" <> String.replace(time, ":", "") <> ".png"
  end
end
