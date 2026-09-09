defmodule SwarmCode.Domain.Workflows.Args do
  @moduledoc """
  The `key=value` grammar the composer uses for workflow launches and the type
  casting against `meta.args` (spec 09 §5.3).
  """

  @doc """
  Splits `text` into `{%{"key" => "value"}, rest}`. A value runs to the next
  whitespace unless it is `"quoted like this"`; everything that is not a
  `key=value` token joins `rest` in order.
  """
  @spec parse(String.t()) :: {map(), String.t()}
  def parse(text) when is_binary(text) do
    scanned =
      Regex.scan(
        ~r/([a-zA-Z_][a-zA-Z0-9_-]*)=(?:"([^"]*)"|(\S+))|(\S+)/,
        String.trim(text)
      )

    {pairs, rest} =
      Enum.reduce(scanned, {[], []}, fn match, {pairs, rest} ->
        case match ++ List.duplicate("", 5 - length(match)) do
          [_all, "", "", "", word] -> {pairs, [word | rest]}
          [_all, key, "", value, _] -> {[{key, value} | pairs], rest}
          [_all, key, quoted, _, _] -> {[{key, quoted} | pairs], rest}
        end
      end)

    {pairs |> Enum.reverse() |> Map.new(), rest |> Enum.reverse() |> Enum.join(" ")}
  end

  def parse(_text), do: {%{}, ""}

  @doc """
  Casts a raw string map against `meta.args`: declared keys become atoms with
  their declared type, defaults are applied, `required` is checked and `rest`
  lands in `args.input` (spec 09 §5.3).
  """
  @spec cast(map(), map(), String.t()) :: {:ok, map()} | {:error, [String.t()]}
  def cast(meta, raw, rest \\ "") do
    declared = Map.get(meta, :args) || %{}

    # A blank field of the launch form is "not given", so a required arg is
    # still reported as missing instead of arriving as "" (spec 09 §6.6).
    raw =
      for {k, v} <- raw,
          not (is_binary(v) and String.trim(v) == ""),
          into: %{},
          do: {to_string(k), v}

    raw =
      if String.trim(rest) == "" do
        raw
      else
        Map.put_new(raw, "input", rest)
      end

    {values, problems} =
      Enum.reduce(declared, {%{}, []}, fn {key, spec}, {values, problems} ->
        spec = Map.new(spec)

        case Map.fetch(raw, to_string(key)) do
          {:ok, value} ->
            case cast_value(key, spec, value) do
              {:ok, cast} -> {Map.put(values, key, cast), problems}
              {:error, msg} -> {values, problems ++ [msg]}
            end

          :error ->
            cond do
              Map.has_key?(spec, :default) ->
                {Map.put(values, key, spec[:default]), problems}

              spec[:required] ->
                {values, problems ++ ["#{key} is required"]}

              true ->
                {Map.put(values, key, nil), problems}
            end
        end
      end)

    unknown =
      for {k, v} <- raw, not Map.has_key?(declared, safe_key(declared, k)), into: %{}, do: {k, v}

    if problems == [], do: {:ok, Map.merge(unknown, values)}, else: {:error, problems}
  end

  defp safe_key(declared, key) do
    Enum.find(Map.keys(declared), fn k -> to_string(k) == key end) || key
  end

  defp cast_value(_key, _spec, nil), do: {:ok, nil}

  # spec 60 T46: a value that is not text (a `workflow_run` JSON argument, a
  # carry) is type-checked instead of passed through whatever it is.
  defp cast_value(key, spec, value) when not is_binary(value) do
    type = spec[:type] || :string

    ok? =
      case type do
        :integer -> is_integer(value)
        :boolean -> is_boolean(value)
        :list -> is_list(value)
        :enum -> to_string(value) in Enum.map(spec[:values] || [], &to_string/1)
        _ -> false
      end

    if ok?, do: {:ok, value}, else: {:error, type_error(key, spec, type)}
  end

  defp cast_value(key, spec, value) do
    case spec[:type] || :string do
      :integer ->
        case Integer.parse(String.trim(value)) do
          {n, ""} -> {:ok, n}
          _ -> {:error, "#{key} must be an integer"}
        end

      :boolean ->
        case String.downcase(String.trim(value)) do
          v when v in ["true", "yes", "1"] -> {:ok, true}
          v when v in ["false", "no", "0"] -> {:ok, false}
          _ -> {:error, "#{key} must be true or false"}
        end

      :list ->
        {:ok, value |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))}

      :enum ->
        values = Enum.map(spec[:values] || [], &to_string/1)

        if String.trim(value) in values,
          do: {:ok, String.trim(value)},
          else: {:error, "#{key} must be one of: " <> Enum.join(values, ", ")}

      _ ->
        {:ok, value}
    end
  end

  # spec 60 T46: the message the text branch above gives a failed parse of the
  # same type (`:list` and `:string`/`:path` never fail there — text is always
  # a list of one and always text).
  defp type_error(key, spec, type) do
    case type do
      :integer -> "#{key} must be an integer"
      :boolean -> "#{key} must be true or false"
      :list -> "#{key} must be a list"
      :enum -> "#{key} must be one of: " <> Enum.map_join(spec[:values] || [], ", ", &to_string/1)
      _ -> "#{key} must be text"
    end
  end
end
