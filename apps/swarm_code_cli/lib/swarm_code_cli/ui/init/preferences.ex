defmodule SwarmCodeCLI.UI.Init.Preferences do
  @moduledoc """
  The CLI's preferences file (pass 72, P6): `cli.json` beside the database in
  the SwarmCode config directory, owner-only (0600).

  It holds the side panel's mode today (`{"panel": "compact"}`); keys this
  version does not know are kept when it writes. A missing, unreadable,
  oversized or malformed file means the defaults, never a crash.

  `read/1` runs in the launcher before the session starts, `write/2` in work
  the session runtime owns; neither is ever called from a state owner's
  callback. A write is a same-directory temporary file, synced, then renamed
  over the old one, and the temporary file is removed on every failure.
  """

  @max_bytes 16_384
  @modes %{"full" => :full, "compact" => :compact, "hidden" => :hidden}

  @type t :: %{panel_mode: :full | :compact | :hidden}

  @doc "The defaults: the full panel."
  @spec defaults() :: t()
  def defaults, do: %{panel_mode: :full}

  @doc "The preferences in `path`, or the defaults."
  @spec read(Path.t() | nil) :: t()
  def read(path) do
    case read_map(path) do
      {:ok, map} -> %{panel_mode: Map.get(@modes, Map.get(map, "panel"), :full)}
      :error -> defaults()
    end
  end

  @doc "Writes `preferences` to `path` atomically, keeping keys it does not know."
  @spec write(Path.t(), t()) :: :ok | {:error, term()}
  def write(path, %{panel_mode: mode})
      when is_binary(path) and mode in [:full, :compact, :hidden] do
    existing =
      case read_map(path) do
        {:ok, map} -> map
        :error -> %{}
      end

    body = JSON.encode!(Map.put(existing, "panel", Atom.to_string(mode)))
    dir = Path.dirname(path)
    temporary = Path.join(dir, ".cli.json." <> random() <> ".tmp")

    try do
      with :ok <- ensure_dir(dir),
           :ok <- write_private(temporary, body),
           :ok <- File.rename(temporary, path) do
        :ok
      else
        {:error, reason} -> {:error, reason}
      end
    after
      _ = File.rm(temporary)
    end
  end

  def write(_path, _preferences), do: {:error, :invalid}

  defp read_map(path) when is_binary(path) do
    with {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_bytes <- File.stat(path),
         {:ok, body} <- File.read(path),
         {:ok, %{} = map} <- JSON.decode(body) do
      {:ok, map}
    else
      _ -> :error
    end
  end

  defp read_map(_path), do: :error

  # The config directory is the database's; it normally exists. When it does
  # not, it is created owner-only, like the app creates it.
  defp ensure_dir(dir) do
    if File.dir?(dir) do
      :ok
    else
      with :ok <- File.mkdir_p(dir), do: File.chmod(dir, 0o700)
    end
  end

  defp write_private(path, body) do
    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, device} ->
        try do
          with :ok <- File.chmod(path, 0o600),
               :ok <- IO.binwrite(device, body),
               :ok <- :file.sync(device) do
            :ok
          end
        after
          File.close(device)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp random, do: 8 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
