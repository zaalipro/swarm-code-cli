defmodule SwarmCode.Domain.Workflows.Schema do
  @moduledoc """
  The tiny JSON-schema subset workflow agents answer in (spec 09 §3.2).

  Supported keys: `type` (`:object :array :string :integer :number :boolean`),
  `properties`, `required`, `items`, `enum`, `minimum`, `maximum`,
  `description`, `additionalProperties` (default true). No `$ref`, no
  `oneOf` — everything is written by hand, so there is no hex dependency.
  """

  @types ~w(object array string integer number boolean)a

  @doc "Validates a decoded value against `schema`."
  @spec validate(map(), term()) :: :ok | {:error, [String.t()]}
  def validate(schema, value) do
    case check(schema, value, "value") do
      [] -> :ok
      problems -> {:error, Enum.uniq(problems)}
    end
  end

  defp check(schema, value, path) when is_map(schema) do
    type = type_of(schema)

    cond do
      is_nil(value) and type != nil ->
        ["#{path} is missing"]

      type == :object ->
        object(schema, value, path)

      type == :array ->
        array(schema, value, path)

      type == :string ->
        if is_binary(value), do: enum(schema, value, path), else: ["#{path} must be a string"]

      type == :integer ->
        if is_integer(value),
          do: bounds(schema, value, path),
          else: ["#{path} must be an integer"]

      type == :number ->
        if is_number(value), do: bounds(schema, value, path), else: ["#{path} must be a number"]

      type == :boolean ->
        if is_boolean(value), do: [], else: ["#{path} must be a boolean"]

      true ->
        enum(schema, value, path)
    end
  end

  defp check(_schema, _value, _path), do: []

  defp object(schema, value, path) when is_map(value) do
    properties = props(schema)
    required = schema[:required] || schema["required"] || []

    missing =
      for key <- required, is_nil(fetch(value, key)), do: "#{path}.#{key} is required"

    checked =
      Enum.flat_map(properties, fn {key, sub} ->
        case fetch(value, key) do
          nil -> []
          v -> check(sub, v, "#{path}.#{key}")
        end
      end)

    extra =
      if additional?(schema) do
        []
      else
        allowed = MapSet.new(Enum.map(properties, fn {k, _} -> to_string(k) end))

        for {k, _v} <- value,
            not MapSet.member?(allowed, to_string(k)),
            do: "#{path}.#{k} is not allowed"
      end

    missing ++ checked ++ extra
  end

  defp object(_schema, _value, path), do: ["#{path} must be an object"]

  defp array(schema, value, path) when is_list(value) do
    case schema[:items] || schema["items"] do
      nil ->
        []

      items ->
        value
        |> Enum.with_index()
        |> Enum.flat_map(fn {v, i} -> check(items, v, "#{path}[#{i}]") end)
    end
  end

  defp array(_schema, _value, path), do: ["#{path} must be an array"]

  defp enum(schema, value, path) do
    case schema[:enum] || schema["enum"] do
      nil ->
        []

      values ->
        if Enum.any?(values, &(to_string(&1) == to_string(value))),
          do: [],
          else: ["#{path} must be one of: " <> Enum.map_join(values, ", ", &to_string/1)]
    end
  end

  defp bounds(schema, value, path) do
    min = schema[:minimum] || schema["minimum"]
    max = schema[:maximum] || schema["maximum"]

    []
    |> then(fn acc ->
      if is_number(min) and value < min, do: ["#{path} must be >= #{min}" | acc], else: acc
    end)
    |> then(fn acc ->
      if is_number(max) and value > max, do: ["#{path} must be <= #{max}" | acc], else: acc
    end)
    |> Kernel.++(enum(schema, value, path))
  end

  @doc "The schema as a JSON-schema map (atoms → strings) for the tool parameters."
  @spec to_json_schema(map()) :: map()
  def to_json_schema(schema) when is_map(schema) do
    schema
    |> Enum.flat_map(fn {key, value} -> json_pair(to_string(key), value) end)
    |> Map.new()
  end

  defp json_pair("properties", props) when is_map(props) do
    [{"properties", Map.new(props, fn {k, v} -> {to_string(k), to_json_schema(v)} end)}]
  end

  defp json_pair("items", items) when is_map(items), do: [{"items", to_json_schema(items)}]

  defp json_pair("required", keys) when is_list(keys),
    do: [{"required", Enum.map(keys, &to_string/1)}]

  defp json_pair("enum", values) when is_list(values),
    do: [{"enum", Enum.map(values, &json_scalar/1)}]

  defp json_pair("type", type), do: [{"type", to_string(type)}]

  defp json_pair(key, value) when key in ~w(minimum maximum description additionalProperties),
    do: [{key, value}]

  defp json_pair(_key, _value), do: []

  defp json_scalar(v) when is_atom(v) and not is_boolean(v) and not is_nil(v), do: to_string(v)
  defp json_scalar(v), do: v

  @doc "A canned instance of `schema` used by the smoke check (spec 09 §4.4)."
  @spec sample(map()) :: term()
  def sample(schema), do: sample(schema, nil)

  defp sample(schema, key) when is_map(schema) do
    case type_of(schema) do
      :object ->
        properties = props(schema)
        required = Enum.map(schema[:required] || schema["required"] || [], &to_string/1)

        keep =
          properties
          |> Enum.split_with(fn {k, _} -> to_string(k) in required end)
          |> then(fn {req, opt} -> req ++ Enum.take(opt, 3) end)

        Map.new(keep, fn {k, sub} -> {atomize_key(k), sample(sub, to_string(k))} end)

      :array ->
        case schema[:items] || schema["items"] do
          nil -> []
          items -> [sample(items, key)]
        end

      :integer ->
        first_enum(schema) || schema[:minimum] || schema["minimum"] || 1

      :number ->
        first_enum(schema) || schema[:minimum] || schema["minimum"] || 1

      :boolean ->
        true

      _ ->
        first_enum(schema) || sample_string(key)
    end
  end

  defp sample(_schema, _key), do: "sample"

  # spec 60 T48: the canned project tree is one file — `Canned.canned/1` answers
  # every host helper with `lib/sample.ex`. A canned agent that names a *file*
  # answers with that same one, so a program that keeps only findings about the
  # files it was given still walks its whole path in the smoke check.
  defp sample_string(key) when key in ~w(file path filename file_path), do: "lib/sample.ex"
  defp sample_string(_key), do: "sample"

  defp first_enum(schema) do
    case schema[:enum] || schema["enum"] do
      [first | _] -> first
      _ -> nil
    end
  end

  @doc """
  Turns the keys declared in `properties` into atoms (recursively). Undeclared
  keys stay strings — `String.to_atom/1` is never called on model output.
  """
  @spec atomize(map(), term()) :: term()
  def atomize(schema, value) when is_map(schema) and is_map(value) and not is_struct(value) do
    properties = props(schema)
    declared = Map.new(properties, fn {k, sub} -> {to_string(k), {atomize_key(k), sub}} end)

    Map.new(value, fn {k, v} ->
      case Map.get(declared, to_string(k)) do
        nil -> {k, v}
        {atom, sub} -> {atom, atomize(sub, v)}
      end
    end)
  end

  def atomize(schema, value) when is_map(schema) and is_list(value) do
    case schema[:items] || schema["items"] do
      nil -> value
      items -> Enum.map(value, &atomize(items, &1))
    end
  end

  def atomize(_schema, value), do: value

  defp atomize_key(key) when is_atom(key), do: key

  # spec 60 T34: a declared key the code base never named stays a string —
  # `fetch/2` below already falls back to the string form.
  defp atomize_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  # Model output is string-keyed JSON; declared keys may be atoms in the schema.
  defp fetch(value, key) when is_map(value) do
    case Map.fetch(value, key) do
      {:ok, v} -> v
      :error -> Map.get(value, to_string(key))
    end
  end

  defp fetch(_value, _key), do: nil

  defp props(schema) do
    case schema[:properties] || schema["properties"] do
      map when is_map(map) -> Enum.to_list(map)
      _ -> []
    end
  end

  defp additional?(schema) do
    case Map.get(schema, :additionalProperties, Map.get(schema, "additionalProperties", true)) do
      false -> false
      _ -> true
    end
  end

  defp type_of(schema) do
    case schema[:type] || schema["type"] do
      nil ->
        nil

      type ->
        atom = if is_atom(type), do: type, else: safe_atom(type)
        if atom in @types, do: atom, else: nil
    end
  end

  defp safe_atom("object"), do: :object
  defp safe_atom("array"), do: :array
  defp safe_atom("string"), do: :string
  defp safe_atom("integer"), do: :integer
  defp safe_atom("number"), do: :number
  defp safe_atom("boolean"), do: :boolean
  defp safe_atom(_other), do: nil
end
