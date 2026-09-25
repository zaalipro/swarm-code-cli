defmodule SwarmCodeCLI.UI.DataSource.DTO.SettingsDecode do
  @moduledoc """
  pass74 §3.4.6: the decoding rules every settings DTO shares — the client's last
  line of defence for D6.

  Every settings DTO decodes with `run/1`: a helper that finds a value outside its
  shape or bound calls `reject!/1`, and the whole snapshot or result is refused
  (`{:error, reason}`); the codec turns that into `{:settings_failed, request_id,
  words}`, never a connection close. Required keys must be present; keys a newer
  daemon adds are ignored. Nothing here creates atoms from the wire: every atom is
  looked up in a closed table.
  """
  require Logger

  alias SwarmCode.Settings.{RecordKind, SecretPattern}
  alias SwarmCode.Settings.RecordKind.Field
  alias SwarmCodeCLI.UI.Intent

  @string_max 65_536
  @layers %{
    "flag" => :flag,
    "env" => :env,
    "session" => :session,
    "project" => :project,
    "cli" => :cli,
    "global" => :global,
    "project_file" => :project_file,
    "default" => :default
  }

  @doc "Run a decoder; a `reject!/1` inside becomes `{:error, reason}`."
  @spec run((-> term())) :: {:ok, term()} | {:error, term()}
  def run(fun) do
    {:ok, fun.()}
  catch
    {:settings_reject, reason} -> {:error, reason}
  end

  @doc "Refuse the whole response."
  @spec reject!(term()) :: no_return()
  def reject!(reason), do: throw({:settings_reject, reason})

  @doc "The layer atoms, in no particular order."
  @spec layers() :: [atom()]
  def layers, do: Map.values(@layers)

  @doc "A layer name from the wire, as an atom of the closed list."
  @spec layer!(term()) :: atom()
  def layer!(name) when is_binary(name) do
    case Map.fetch(@layers, name) do
      {:ok, layer} -> layer
      :error -> reject!({:layer, name})
    end
  end

  def layer!(name), do: reject!({:layer, name})

  @doc "A closed enum: `table` maps wire strings to atoms."
  @spec enum!(term(), %{String.t() => atom()}, term()) :: atom()
  def enum!(value, table, what) when is_binary(value) do
    case Map.fetch(table, value) do
      {:ok, atom} -> atom
      :error -> reject!({what, :value})
    end
  end

  def enum!(_value, _table, what), do: reject!({what, :value})

  @doc "A required key of a wire map."
  @spec fetch!(term(), String.t()) :: term()
  def fetch!(map, key) when is_map(map) and not is_struct(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> reject!({:missing, key})
    end
  end

  def fetch!(_map, key), do: reject!({:not_a_map, key})

  @doc "A wire map (string keys, ≤ `max` entries)."
  @spec map!(term(), pos_integer(), term()) :: map()
  def map!(value, max \\ 256, what \\ :map)

  def map!(value, max, what) when is_map(value) and not is_struct(value) do
    if map_size(value) <= max and Enum.all?(Map.keys(value), &is_binary/1),
      do: value,
      else: reject!({what, :map})
  end

  def map!(_value, _max, what), do: reject!({what, :map})

  @doc "A bounded UTF-8 string."
  @spec text!(term(), pos_integer(), term()) :: String.t()
  def text!(value, max \\ @string_max, what \\ :text)

  def text!(value, max, what) do
    if is_binary(value) and byte_size(value) <= max and String.valid?(value),
      do: value,
      else: reject!({what, :text})
  end

  @doc "A bounded string or nil."
  @spec opt_text!(term(), pos_integer(), term()) :: String.t() | nil
  def opt_text!(value, max \\ @string_max, what \\ :text)
  def opt_text!(nil, _max, _what), do: nil
  def opt_text!(value, max, what), do: text!(value, max, what)

  @doc "A non-negative integer (a whole-number float is accepted)."
  @spec count!(term(), term()) :: non_neg_integer()
  def count!(value, what \\ :count)
  def count!(value, _what) when is_integer(value) and value >= 0, do: value

  def count!(value, what) when is_float(value) and value >= 0 do
    if value == Float.round(value), do: trunc(value), else: reject!({what, :count})
  end

  def count!(_value, what), do: reject!({what, :count})

  @doc "A non-negative integer or nil."
  @spec opt_count!(term(), term()) :: non_neg_integer() | nil
  def opt_count!(value, what \\ :count)
  def opt_count!(nil, _what), do: nil
  def opt_count!(value, what), do: count!(value, what)

  @doc "A boolean."
  @spec bool!(term(), term()) :: boolean()
  def bool!(value, _what) when is_boolean(value), do: value
  def bool!(_value, what), do: reject!({what, :boolean})

  @doc "A request id or nil."
  @spec opt_id!(term(), term()) :: String.t() | nil
  def opt_id!(nil, _what), do: nil

  def opt_id!(value, what),
    do: if(Intent.valid_id?(value), do: value, else: reject!({what, :id}))

  @doc "A list of at most `max` items."
  @spec list!(term(), non_neg_integer(), term()) :: list()
  def list!(value, max, what) when is_list(value) do
    if bounded_length?(value, max), do: value, else: reject!({what, :too_many})
  end

  def list!(_value, _max, what), do: reject!({what, :list})

  @doc """
  Bounded generic JSON: depth ≤ 8, maps ≤ 256 entries with string keys ≤ 256 bytes,
  lists ≤ 2 048 items, strings ≤ `string_max` bytes.
  """
  @spec json!(term(), pos_integer(), term()) :: term()
  def json!(value, string_max \\ @string_max, what \\ :json) do
    if json?(value, 8, string_max), do: value, else: reject!({what, :json})
  end

  @doc "True for bounded generic JSON (see `json!/3`)."
  @spec json?(term(), non_neg_integer(), pos_integer()) :: boolean()
  def json?(value, _depth, _max)
      when is_nil(value) or is_boolean(value) or is_integer(value) or is_float(value),
      do: true

  def json?(value, _depth, max) when is_binary(value),
    do: byte_size(value) <= max and String.valid?(value)

  def json?(value, depth, max) when is_list(value) and depth > 0,
    do: bounded_length?(value, 2_048) and Enum.all?(value, &json?(&1, depth - 1, max))

  def json?(value, depth, max) when is_map(value) and not is_struct(value) and depth > 0,
    do:
      map_size(value) <= 256 and
        Enum.all?(value, fn {k, v} ->
          is_binary(k) and byte_size(k) in 1..256 and String.valid?(k) and
            json?(v, depth - 1, max)
        end)

  def json?(_value, _depth, _max), do: false

  @doc "An optional bounded JSON map."
  @spec opt_json_map!(term(), pos_integer(), term()) :: map() | nil
  def opt_json_map!(nil, _max, _what), do: nil

  def opt_json_map!(value, max, what) when is_map(value) and not is_struct(value),
    do: json!(value, max, what)

  def opt_json_map!(_value, _max, what), do: reject!({what, :map})

  @doc "A bounded JSON map encoded within `bytes`."
  @spec encoded_within!(term(), pos_integer(), term()) :: term()
  def encoded_within!(value, bytes, what) do
    case Jason.encode(value) do
      {:ok, encoded} when byte_size(encoded) <= bytes -> value
      _ -> reject!({what, :too_large})
    end
  end

  @doc """
  The secret shape (§3.4.6 rule 2): exactly `{"set": boolean, "hint": null | 4
  printable characters}`. Anything else refuses the whole response and logs the
  kind and field (never the value).
  """
  @spec secret!(term(), String.t(), String.t()) :: %{set: boolean(), hint: String.t() | nil}
  def secret!(%{"set" => set, "hint" => hint} = value, kind, field)
      when map_size(value) == 2 and is_boolean(set) do
    if hint?(hint), do: %{set: set, hint: hint}, else: secret_rejected!(kind, field)
  end

  def secret!(_value, kind, field), do: secret_rejected!(kind, field)

  @doc "A hint: nil or exactly 4 printable characters."
  @spec hint?(term()) :: boolean()
  def hint?(nil), do: true

  def hint?(hint) when is_binary(hint),
    do:
      byte_size(hint) <= 16 and String.valid?(hint) and String.length(hint) == 4 and
        String.printable?(hint) and not String.match?(hint, ~r/[[:cntrl:]]/u)

  def hint?(_hint), do: false

  defp secret_rejected!(kind, field) do
    Logger.warning("settings response rejected: secret field shape (#{kind}.#{field})")
    reject!({:secret_shape, kind, field})
  end

  @doc """
  An MCP env/header list (§3.4.6 rule 3): `[{"name", "secret", "value", "hint"}]`;
  a secret entry carries no value, a shown entry must not look like a secret.
  """
  @spec kv_secrets!(term(), String.t(), String.t(), pos_integer()) :: [map()]
  def kv_secrets!(entries, kind, field, max) do
    entries
    |> list!(max, {kind, field})
    |> Enum.map(fn entry ->
      name = text!(fetch!(entry, "name"), 256, {kind, field})
      secret = bool!(fetch!(entry, "secret"), {kind, field})
      value = fetch!(entry, "value")
      hint = fetch!(entry, "hint")

      unless hint?(hint), do: secret_rejected!(kind, field)

      cond do
        secret and value != nil ->
          secret_rejected!(kind, field)

        secret ->
          %{name: name, secret: true, value: nil, hint: hint}

        not is_binary(value) or byte_size(value) > @string_max ->
          reject!({{kind, field}, :value})

        SecretPattern.secret_kv?(name, value) ->
          Logger.warning("settings response rejected: secret shown (#{kind}.#{field})")
          reject!({:secret_shown, kind, field})

        true ->
          %{name: name, secret: false, value: value, hint: hint}
      end
    end)
  end

  @doc """
  A record's fields (§3.4.6 rules 2–4) against its `RecordKind`: undeclared fields
  are dropped (logged by name), secret fields keep the `{set, hint}` shape, lists
  keep the field's bound.
  """
  @spec fields!(RecordKind.t(), term(), pos_integer()) :: map()
  def fields!(%RecordKind{} = kind, fields, string_max \\ @string_max) do
    fields
    |> map!(256, {kind.name, :fields})
    |> Enum.reduce(%{}, fn {name, value}, acc ->
      case RecordKind.field(kind, name) do
        nil ->
          Logger.debug("settings record field dropped: #{kind.name}.#{safe_name(name)}")
          acc

        field ->
          Map.put(acc, name, field!(kind, field, value, string_max))
      end
    end)
  end

  defp field!(kind, %Field{secret: true, name: name}, value, _max),
    do: secret!(value, kind.name, name)

  defp field!(kind, %Field{type: :kv_secrets, name: name} = field, value, _max),
    do: if(is_nil(value), do: nil, else: kv_secrets!(value, kind.name, name, list_max(field)))

  defp field!(kind, %Field{type: {:records, sub}, name: name} = field, value, max)
       when is_list(value) do
    case RecordKind.fetch(sub) do
      {:ok, sub_kind} ->
        value
        |> list!(list_max(field), {kind.name, name})
        |> Enum.map(fn
          row when is_map(row) -> fields!(sub_kind, row, max)
          other -> json!(other, max, {kind.name, name})
        end)

      :error ->
        value |> list!(list_max(field), {kind.name, name}) |> json!(max, {kind.name, name})
    end
  end

  defp field!(kind, %Field{name: name} = field, value, max) when is_list(value),
    do: value |> list!(list_max(field), {kind.name, name}) |> json!(max, {kind.name, name})

  defp field!(kind, %Field{name: name}, value, max), do: json!(value, max, {kind.name, name})

  defp list_max(%Field{} = field), do: RecordKind.list_max(field)

  @doc "A record `{kind, id, fields}`."
  @spec record!(term()) :: SwarmCodeCLI.UI.DataSource.DTO.SettingsRecord.t()
  def record!(wire) do
    kind_name = text!(fetch!(wire, "kind"), 64, :record_kind)

    kind =
      case RecordKind.fetch(kind_name) do
        {:ok, kind} -> kind
        :error -> reject!({:record_kind, :unknown})
      end

    %SwarmCodeCLI.UI.DataSource.DTO.SettingsRecord{
      kind: kind_name,
      id: record_id!(fetch!(wire, "id")),
      fields: fields!(kind, fetch!(wire, "fields"))
    }
  end

  @doc "A record id: nil or a string of 1..512 bytes without control characters."
  @spec record_id!(term()) :: String.t() | nil
  def record_id!(nil), do: nil

  def record_id!(id) when is_binary(id) and byte_size(id) in 1..512 do
    if String.valid?(id) and not String.match?(id, ~r/[[:cntrl:]]/u),
      do: id,
      else: reject!({:record_id, :text})
  end

  def record_id!(_id), do: reject!({:record_id, :text})

  @doc "A name from the wire, printable and short, for a log line."
  @spec safe_name(term()) :: String.t()
  def safe_name(name) when is_binary(name) do
    name = if String.valid?(name), do: name, else: "?"
    name |> String.replace(~r/[^A-Za-z0-9._\-]/u, "?") |> binary_part_safe(64)
  end

  def safe_name(_name), do: "?"

  defp binary_part_safe(text, max) when byte_size(text) <= max, do: text
  defp binary_part_safe(text, max), do: binary_part(text, 0, max)

  defp bounded_length?(list, max), do: bounded_length?(list, max, 0)
  defp bounded_length?([], _max, _n), do: true
  defp bounded_length?([_ | rest], max, n) when n < max, do: bounded_length?(rest, max, n + 1)
  defp bounded_length?(_list, _max, _n), do: false
end
