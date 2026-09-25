defmodule SwarmCode.Settings.WireValue do
  @moduledoc """
  The JSON form of a setting's value (pass 74, spec §3.2.3).

  `type_ok?/2` checks the shape and the bounds of an entry's type (range,
  choices, nullability), never the finer rules of `Validate`. `normalize/2`
  turns an integral float into an integer for the numeric types (a stored
  `50.0` reads as `50`, D30/D34). `equal?/2` and `canonical/1` are what
  compare-and-set compares.
  """

  alias SwarmCode.Settings.Entry

  @max_text 65_536
  @max_list 2_048
  @numeric [:integer, :duration, :money]
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @hex ~r/\A#[0-9A-F]{6}\z/

  @doc "The numeric types (integers in the entry's stored unit)."
  @spec numeric_types() :: [atom()]
  def numeric_types, do: @numeric

  @doc "True when `value` has the entry type's shape and lies within its bounds."
  @spec type_ok?(Entry.t(), term()) :: boolean()
  def type_ok?(%Entry{} = entry, nil), do: nil_ok?(entry)

  def type_ok?(%Entry{type: :toggle}, value), do: is_boolean(value)

  def type_ok?(%Entry{type: :enum} = entry, value),
    do: (is_binary(value) or is_integer(value)) and value in Entry.choice_values(entry)

  def type_ok?(%Entry{type: :checklist} = entry, value) when is_list(value) do
    allowed = Entry.choice_values(entry)
    Enum.all?(value, &(is_binary(&1) and &1 in allowed)) and Enum.uniq(value) == value
  end

  def type_ok?(%Entry{type: type} = entry, value) when type in [:integer, :duration] do
    is_integer(value) and
      (Map.has_key?(entry.special, value) or within?(value, entry.min, entry.max))
  end

  def type_ok?(%Entry{type: :money} = entry, value),
    do: is_integer(value) and value >= 0 and within?(value, entry.min, entry.max)

  def type_ok?(%Entry{type: type}, value) when type in [:text, :path, :combo],
    do: text?(value, @max_text)

  def type_ok?(%Entry{type: :effort}, value),
    do: is_binary(value) and byte_size(value) in 1..24 and String.valid?(value)

  def type_ok?(%Entry{type: :lsp_command}, value), do: text?(value, 1_024) and value != ""

  def type_ok?(%Entry{type: :list}, value) when is_list(value),
    do: length(value) <= @max_list and Enum.all?(value, &text?(&1, @max_text))

  def type_ok?(%Entry{type: :model}, %{"provider_id" => provider, "model" => model} = value),
    do:
      map_size(value) == 2 and is_binary(provider) and Regex.match?(@uuid, provider) and
        text?(model, 512) and String.trim(model) != ""

  def type_ok?(%Entry{type: :color}, value), do: is_binary(value) and Regex.match?(@hex, value)

  def type_ok?(%Entry{type: :keys}, value) when is_map(value) do
    map_size(value) <= 256 and
      Enum.all?(value, fn {id, keys} ->
        text?(id, 128) and is_list(keys) and length(keys) <= 4 and
          Enum.all?(keys, &text?(&1, 64))
      end)
  end

  def type_ok?(%Entry{type: :map_readonly}, value), do: is_map(value)

  def type_ok?(%Entry{type: :datetime}, value) when is_binary(value),
    do: match?({:ok, _, _}, DateTime.from_iso8601(value))

  def type_ok?(%Entry{type: :fact}, _value), do: true
  def type_ok?(%Entry{}, _value), do: false

  @doc """
  The normalised wire value: integral floats become integers for the numeric
  types; anything else is returned as given.
  """
  @spec normalize(Entry.t(), term()) :: term()
  def normalize(%Entry{type: type}, value) when type in @numeric and is_float(value) do
    if value == Float.round(value) and abs(value) < 9.0e15, do: trunc(value), else: value
  end

  def normalize(%Entry{type: :color}, value) when is_binary(value), do: String.upcase(value)
  def normalize(%Entry{}, value), do: value

  @doc "Decode a JSON term into the entry's wire value (normalised and type-checked)."
  @spec from_json(Entry.t(), term()) :: {:ok, term()} | :error
  def from_json(%Entry{} = entry, json) do
    value = normalize(entry, json)
    if type_ok?(entry, value), do: {:ok, value}, else: :error
  end

  @doc "Encode a wire value as JSON-ready data (maps key-sorted, integral numbers kept)."
  @spec to_json(Entry.t(), term()) :: term()
  def to_json(%Entry{} = entry, value), do: entry |> normalize(value) |> canonical()

  @doc "True when two wire values are the same (numbers numerically, maps by content)."
  @spec equal?(term(), term()) :: boolean()
  def equal?(a, b), do: canonical(a) == canonical(b)

  @doc "A JSON-stable form: integral floats as integers, maps sorted into keyword-free maps."
  @spec canonical(term()) :: term()
  def canonical(value) when is_float(value) do
    if value == Float.round(value) and abs(value) < 9.0e15, do: trunc(value), else: value
  end

  def canonical(%{} = value) when not is_struct(value),
    do: Map.new(value, fn {k, v} -> {canonical_key(k), canonical(v)} end)

  def canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  def canonical(value), do: value

  defp canonical_key(key) when is_atom(key) and not is_nil(key) and not is_boolean(key),
    do: Atom.to_string(key)

  defp canonical_key(key), do: key

  defp nil_ok?(%Entry{nullable: true}), do: true
  defp nil_ok?(%Entry{type: type}) when type in [:model, :fact, :datetime], do: true
  defp nil_ok?(%Entry{type: type}) when type in [:action, :link], do: true
  defp nil_ok?(%Entry{type: :checklist}), do: true
  defp nil_ok?(%Entry{default: nil, scope: :session}), do: true
  defp nil_ok?(%Entry{}), do: false

  defp within?(value, min, max),
    do: (is_nil(min) or value >= min) and (is_nil(max) or value <= max)

  defp text?(value, limit),
    do: is_binary(value) and byte_size(value) <= limit and String.valid?(value)
end
