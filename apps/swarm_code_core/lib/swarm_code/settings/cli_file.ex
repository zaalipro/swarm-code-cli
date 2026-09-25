defmodule SwarmCode.Settings.CliFile do
  @moduledoc """
  The cli.json file layer (pass 74, spec §3.8.1, D20): this machine's terminal
  preferences, `<config_dir>/cli.json`, owner-only (0600), at most 64 KiB.

  Registry-driven: the known json names are `Registry.cli_entries/0`; values
  are converted with `WireValue.from_json/2` and checked with
  `Validate.check/2`. Unknown keys are kept on every write. A write compares
  per key (compare-and-set), writes a same-directory temporary file created
  exclusively at 0600, re-reads the file's fingerprint just before the rename
  (another writer in between restarts the write once, a second one answers
  `:busy`) and removes the temporary file on every path.

  `swarmcode config` calls it directly; the TUI through
  `SwarmCodeCLI.UI.Init.Preferences` in work its session runtime owns. It is
  never called from a state owner's callback.
  """

  alias SwarmCode.Settings.{Registry, Validate, WireValue}

  @max_bytes 65_536

  # A value that is written as "the key is absent" (the theme follows the
  # desktop app when the file names none).
  @absent_as %{"theme" => "follow"}

  @type status :: :ok | :absent | :too_large | :unreadable | :not_json | :symlink
  @type snapshot :: %{
          values: %{String.t() => term()},
          invalid: [String.t()],
          unknown: [String.t()],
          fingerprint: String.t() | nil,
          mode: non_neg_integer() | nil,
          size: non_neg_integer(),
          status: status()
        }
  @type change :: term() | :remove
  @type expectation :: term() | :absent | :any

  @doc "The largest cli.json this version reads or writes."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc "The snapshot of a missing file (the defaults)."
  @spec empty() :: snapshot()
  def empty,
    do: %{
      values: %{},
      invalid: [],
      unknown: [],
      fingerprint: nil,
      mode: nil,
      size: 0,
      status: :absent
    }

  @doc "Read the file: valid known keys, invalid and unknown key names, fingerprint, mode, status."
  @spec read_all(Path.t() | nil) :: snapshot()
  def read_all(nil), do: empty()

  def read_all(path) when is_binary(path) do
    case read_raw(path) do
      {:ok, bytes, map, stat} -> classify(map, bytes, stat)
      {:absent, _} -> empty()
      {:error, status, stat} -> %{empty() | status: status} |> put_stat(stat)
    end
  end

  @doc """
  Apply `changes` (json name => wire value or `:remove`) when every
  `expectations` entry (json name => value, `:absent` or `:any`) still holds.
  """
  @spec write_changes(
          Path.t(),
          %{String.t() => change()},
          %{String.t() => expectation()},
          keyword()
        ) ::
          {:ok, snapshot()}
          | {:conflict, %{String.t() => term() | :absent}}
          | {:error, :invalid, %{String.t() => String.t()}}
          | {:error, :too_large | :unreadable | :not_json | :symlink | :busy | File.posix()}
  def write_changes(path, changes, expectations, opts \\ [])

  def write_changes(path, changes, expectations, opts)
      when is_binary(path) and is_map(changes) and is_map(expectations) do
    with :ok <- validate_changes(changes) do
      attempt_changes(path, changes, expectations, opts, 1)
    end
  end

  def write_changes(_path, _changes, _expectations, _opts), do: {:error, :einval}

  @doc """
  Write `text` as typed (the external-edit return, §2.21) when the file's
  fingerprint is still `expected_fingerprint` (nil = the file was absent).
  Text that is not a JSON object is not written; known keys with bad values
  are written as typed and answered as warnings.
  """
  @spec write_text(Path.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, snapshot(), %{String.t() => String.t()}}
          | {:conflict, String.t() | nil}
          | {:error, {:not_json, pos_integer()} | :too_large | :symlink | :busy | File.posix()}
  def write_text(path, text, expected_fingerprint, opts \\ [])

  def write_text(path, text, expected_fingerprint, opts)
      when is_binary(path) and is_binary(text) do
    cond do
      byte_size(text) > @max_bytes ->
        {:error, :too_large}

      true ->
        case decode_object(text) do
          {:ok, map} -> attempt_text(path, text, map, expected_fingerprint, opts, 1)
          {:error, line} -> {:error, {:not_json, line}}
        end
    end
  end

  def write_text(_path, _text, _fingerprint, _opts), do: {:error, :einval}

  @doc "The words for a status or an error atom, for rows and toasts."
  @spec words(atom()) :: String.t()
  def words(:symlink), do: "cli.json is a symbolic link; SwarmCode will not replace it"
  def words(:busy), do: "cli.json keeps changing; try again"
  def words(:too_large), do: "cli.json is larger than 64 KB"
  def words(:not_json), do: "cli.json is not valid JSON"
  def words(:unreadable), do: "cli.json could not be read"
  def words(other), do: "Couldn't write cli.json: #{other}"

  # --- writes ---------------------------------------------------------------

  defp attempt_changes(path, changes, expectations, opts, attempt) do
    with {:ok, current, before} <- current_for_write(path, changes),
         :ok <- compare(current, expectations) do
      merged = merge(current, changes)
      body = JSON.encode!(merged)

      if byte_size(body) > @max_bytes do
        {:error, :too_large}
      else
        case replace(path, body, before, opts, attempt) do
          :ok -> {:ok, read_all(path)}
          :moved when attempt == 1 -> attempt_changes(path, changes, expectations, opts, 2)
          :moved -> {:error, :busy}
          {:error, reason} -> {:error, reason}
        end
      end
    else
      :nothing_to_remove -> removal_on_broken_file(path, expectations)
      other -> other
    end
  end

  # Every change removes a key of a file that is not JSON: the keys are already
  # absent for every reader, so nothing is written and the broken file stays
  # for the person to fix (`e` in Files & environment).
  defp removal_on_broken_file(path, expectations) do
    if Enum.all?(expectations, fn {_k, v} -> v in [:any, :absent] end),
      do: {:ok, read_all(path)},
      else: {:error, :not_json}
  end

  defp attempt_text(path, text, map, expected_fingerprint, opts, attempt) do
    with {:ok, before} <- fingerprint_for_write(path) do
      if before != expected_fingerprint do
        {:conflict, before}
      else
        case replace(path, text, before, opts, attempt) do
          :ok -> {:ok, read_all(path), warnings(map)}
          :moved when attempt == 1 -> attempt_text(path, text, map, expected_fingerprint, opts, 2)
          :moved -> {:error, :busy}
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  # The current map for a write. A file that is not JSON is never replaced,
  # unless every change removes a key: then the keys are already absent for
  # every reader, and nothing is written.
  defp current_for_write(path, changes) do
    case read_raw(path) do
      {:ok, bytes, map, _stat} ->
        {:ok, map, fingerprint(bytes)}

      {:absent, _} ->
        {:ok, %{}, nil}

      {:error, :symlink, _} ->
        {:error, :symlink}

      {:error, :not_json, _} ->
        if Enum.all?(changes, fn {_k, v} -> v == :remove end),
          do: :nothing_to_remove,
          else: {:error, :not_json}

      {:error, status, _} ->
        {:error, status}
    end
  end

  defp fingerprint_for_write(path) do
    case read_raw(path) do
      {:ok, bytes, _map, _stat} -> {:ok, fingerprint(bytes)}
      {:absent, _} -> {:ok, nil}
      {:error, :not_json, _} -> {:ok, current_fingerprint(path)}
      {:error, :symlink, _} -> {:error, :symlink}
      {:error, status, _} -> {:error, status}
    end
  end

  defp validate_changes(changes) do
    errors =
      Enum.reduce(changes, %{}, fn {name, change}, acc ->
        case check_change(name, change) do
          :ok -> acc
          {:error, message} -> Map.put(acc, to_string(name), message)
        end
      end)

    if errors == %{}, do: :ok, else: {:error, :invalid, errors}
  end

  defp check_change(name, change) when is_binary(name) do
    case Registry.cli_entry(name) do
      :error ->
        {:error, "not a setting"}

      {:ok, _entry} when change == :remove ->
        :ok

      {:ok, entry} ->
        value = Validate.normalise(entry, change)

        case Validate.check(entry, value) do
          :ok -> :ok
          {:error, message} -> {:error, message}
        end
    end
  end

  defp check_change(_name, _change), do: {:error, "not a setting"}

  defp compare(current, expectations) do
    conflicts =
      Enum.reduce(expectations, %{}, fn
        {_name, :any}, acc ->
          acc

        {name, expected}, acc ->
          actual = Map.get(current, name, :absent)
          if same?(name, actual, expected), do: acc, else: Map.put(acc, name, actual)
      end)

    if conflicts == %{}, do: :ok, else: {:conflict, conflicts}
  end

  defp same?(name, actual, expected) do
    expected = if Map.get(@absent_as, name) == expected, do: :absent, else: expected

    case {actual, expected} do
      {:absent, :absent} ->
        true

      {:absent, _} ->
        false

      {_, :absent} ->
        false

      {actual, expected} ->
        case Registry.cli_entry(name) do
          {:ok, entry} ->
            WireValue.equal?(
              WireValue.normalize(entry, actual),
              WireValue.normalize(entry, expected)
            )

          :error ->
            WireValue.equal?(actual, expected)
        end
    end
  end

  defp merge(current, changes) do
    Enum.reduce(changes, current, fn {name, change}, map ->
      entry = Registry.cli_entry(name)

      cond do
        change == :remove -> Map.delete(map, name)
        change == nil -> Map.delete(map, name)
        Map.get(@absent_as, name) == change -> Map.delete(map, name)
        match?({:ok, _}, entry) -> Map.put(map, name, Validate.normalise(elem(entry, 1), change))
        true -> Map.put(map, name, change)
      end
    end)
  end

  # Write `body` over `path` through a private temporary file. Answers
  # `:moved` when the file changed since `before` was read.
  defp replace(path, body, before, opts, attempt) do
    dir = Path.dirname(path)
    temporary = Path.join(dir, ".cli.json." <> random() <> ".tmp")

    try do
      with :ok <- ensure_dir(dir),
           :ok <- write_private(temporary, body) do
        run_hook(opts, attempt, path)

        case current_fingerprint(path) do
          ^before ->
            case File.rename(temporary, path) do
              :ok -> :ok
              {:error, reason} -> {:error, reason}
            end

          _moved ->
            :moved
        end
      end
    after
      _ = File.rm(temporary)
    end
  end

  defp run_hook(opts, attempt, path) do
    case Keyword.get(opts, :before_rename) do
      fun when is_function(fun, 2) -> fun.(attempt, path)
      _ -> :ok
    end
  end

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

  # --- reads ---------------------------------------------------------------

  defp read_raw(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        {:absent, nil}

      {:error, _reason} ->
        {:error, :unreadable, nil}

      {:ok, %File.Stat{type: :symlink} = stat} ->
        {:error, :symlink, stat}

      {:ok, %File.Stat{type: :regular, size: size} = stat} when size > @max_bytes ->
        {:error, :too_large, stat}

      {:ok, %File.Stat{type: :regular} = stat} ->
        case File.read(path) do
          {:ok, bytes} when byte_size(bytes) > @max_bytes ->
            {:error, :too_large, stat}

          {:ok, bytes} ->
            case decode_object(bytes) do
              {:ok, map} -> {:ok, bytes, map, stat}
              {:error, _line} -> {:error, :not_json, stat}
            end

          {:error, _reason} ->
            {:error, :unreadable, stat}
        end

      {:ok, stat} ->
        {:error, :unreadable, stat}
    end
  end

  defp current_fingerprint(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        case File.read(path) do
          {:ok, bytes} -> fingerprint(bytes)
          {:error, _} -> :unreadable
        end

      {:ok, _other} ->
        :not_regular

      {:error, _} ->
        nil
    end
  end

  defp classify(map, bytes, stat) do
    {values, invalid, unknown} =
      Enum.reduce(map, {%{}, [], []}, fn {name, raw}, {values, invalid, unknown} ->
        case Registry.cli_entry(name) do
          :error ->
            {values, invalid, [name | unknown]}

          {:ok, entry} ->
            with {:ok, value} <- WireValue.from_json(entry, raw),
                 :ok <- Validate.check(entry, value),
                 false <- Map.get(@absent_as, name) == value do
              {Map.put(values, name, value), invalid, unknown}
            else
              true -> {values, invalid, unknown}
              _ -> {values, [name | invalid], unknown}
            end
        end
      end)

    %{
      values: values,
      invalid: Enum.sort(invalid),
      unknown: Enum.sort(unknown),
      fingerprint: fingerprint(bytes),
      mode: nil,
      size: byte_size(bytes),
      status: :ok
    }
    |> put_stat(stat)
  end

  defp put_stat(snapshot, %File.Stat{mode: mode, size: size}),
    do: %{snapshot | mode: Bitwise.band(mode, 0o777), size: size}

  defp put_stat(snapshot, _stat), do: snapshot

  defp warnings(map) do
    Enum.reduce(map, %{}, fn {name, raw}, acc ->
      case Registry.cli_entry(name) do
        :error ->
          acc

        {:ok, entry} ->
          case WireValue.from_json(entry, raw) do
            {:ok, value} ->
              case Validate.check(entry, value) do
                :ok -> acc
                {:error, message} -> Map.put(acc, name, message)
              end

            :error ->
              message =
                case Validate.check(entry, raw) do
                  {:error, message} -> message
                  :ok -> "is invalid"
                end

              Map.put(acc, name, message)
          end
      end
    end)
  end

  defp decode_object(text) do
    case JSON.decode(text) do
      {:ok, %{} = map} -> {:ok, map}
      {:ok, _other} -> {:error, 1}
      {:error, reason} -> {:error, error_line(text, reason)}
    end
  end

  defp error_line(text, reason) do
    offset =
      case reason do
        {:unexpected_end, offset} -> offset
        {:invalid_byte, offset, _byte} -> offset
        {:unexpected_sequence, offset, _bytes} -> offset
        _ -> 0
      end

    offset = min(offset, byte_size(text))
    prefix = binary_part(text, 0, offset)
    length(:binary.matches(prefix, "\n")) + 1
  end

  defp fingerprint(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp random, do: 8 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
