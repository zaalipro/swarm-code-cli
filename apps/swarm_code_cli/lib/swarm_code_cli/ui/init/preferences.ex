defmodule SwarmCodeCLI.UI.Init.Preferences do
  @moduledoc """
  The CLI's preferences file (pass 72, P6): `cli.json` beside the database in
  the SwarmCode config directory, owner-only (0600).

  It holds the side panel's mode (`{"panel": "compact"}`) and, since pass 73,
  whether tool rows show their diffs (`"show_diffs": false`, `/diff`), the
  theme (`"theme": "light"`, `/theme`) and whether the terminal sends wheel
  reports (`"mouse": false`, `/mouse`). Keys this version does not know are
  kept when it writes, and a write changes only the keys it is given. A
  missing, unreadable, oversized or malformed file (or value) means the
  defaults, never a crash.

  `read/1` runs in the launcher before the session starts, `write/2` in work
  the session runtime owns; neither is ever called from a state owner's
  callback. A write is a same-directory temporary file, synced, then renamed
  over the old one, and the temporary file is removed on every failure.
  """

  @max_bytes 16_384
  @modes %{"full" => :full, "compact" => :compact, "hidden" => :hidden}

  @themes %{"dark" => :dark, "light" => :light}

  # Each preference: its key in the file, its encoder and its validity.
  @keys %{panel_mode: "panel", show_diffs: "show_diffs", theme: "theme", mouse?: "mouse"}

  @typedoc """
  `theme` is nil when the file names none: the launcher then falls back to
  the desktop's settings (`SWARM_THEME` > cli.json > desktop > dark).
  """
  @type t :: %{
          panel_mode: :full | :compact | :hidden,
          show_diffs: boolean(),
          theme: :dark | :light | nil,
          mouse?: boolean()
        }

  @doc "The defaults: the full panel, diffs shown, no theme of its own, wheel reports on."
  @spec defaults() :: t()
  def defaults, do: %{panel_mode: :full, show_diffs: true, theme: nil, mouse?: true}

  @doc "The preferences in `path`, or the defaults (per key)."
  @spec read(Path.t() | nil) :: t()
  def read(path) do
    case read_map(path) do
      {:ok, map} ->
        %{
          panel_mode: Map.get(@modes, Map.get(map, "panel"), :full),
          show_diffs: boolean(Map.get(map, "show_diffs"), true),
          theme: Map.get(@themes, Map.get(map, "theme")),
          mouse?: boolean(Map.get(map, "mouse"), true)
        }

      :error ->
        defaults()
    end
  end

  @doc """
  Whether `preferences` is a non-empty map of known keys with valid values:
  what `write/2` accepts (any subset of `t()`, `theme` not nil).
  """
  @spec valid?(term()) :: boolean()
  def valid?(preferences) when is_map(preferences) and map_size(preferences) > 0,
    do: Enum.all?(preferences, fn {key, value} -> valid_value?(key, value) end)

  def valid?(_preferences), do: false

  defp valid_value?(:panel_mode, mode), do: mode in [:full, :compact, :hidden]
  defp valid_value?(:show_diffs, value), do: is_boolean(value)
  defp valid_value?(:theme, value), do: value in [:dark, :light]
  defp valid_value?(:mouse?, value), do: is_boolean(value)
  defp valid_value?(_key, _value), do: false

  defp boolean(value, _default) when is_boolean(value), do: value
  defp boolean(_value, default), do: default

  defp encode(value) when is_boolean(value), do: value
  defp encode(value) when is_atom(value), do: Atom.to_string(value)

  @doc """
  Writes the given preferences (any subset of `t()`) to `path` atomically,
  keeping every other key, known or not.
  """
  @spec write(Path.t(), map()) :: :ok | {:error, term()}
  def write(path, preferences) when is_binary(path) do
    if valid?(preferences), do: write_valid(path, preferences), else: {:error, :invalid}
  end

  def write(_path, _preferences), do: {:error, :invalid}

  defp write_valid(path, preferences) do
    existing =
      case read_map(path) do
        {:ok, map} -> map
        :error -> %{}
      end

    body =
      preferences
      |> Enum.reduce(existing, fn {key, value}, map ->
        Map.put(map, Map.fetch!(@keys, key), encode(value))
      end)
      |> JSON.encode!()

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
