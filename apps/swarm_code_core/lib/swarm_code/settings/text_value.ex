defmodule SwarmCode.Settings.TextValue do
  @moduledoc """
  The typed-text grammar of `swarmcode config set` and the settings command
  line (pass 74, spec §3.10.3): `on/off/true/false`, numbers with units
  (`30m`, `90s`, `2h`), `default`/`null`, comma-separated lists, models as
  `provider/model`, colours as `#RRGGBB`. Record fields parse by the same rules
  against their field type.

  `parse/2` answers the wire value, or `{:model_ref, provider_name, model}`
  for a model named by its provider's name (the caller resolves the name; core
  knows no providers), or `{:error, message}`. It never validates the finer
  rules (`Validate.check/2` does).
  """

  alias SwarmCode.Settings.{Entry, RecordKind, Validate}
  alias SwarmCode.Settings.RecordKind.Field

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @unit_ms %{
    "ms" => 1,
    "s" => 1_000,
    "m" => 60_000,
    "min" => 60_000,
    "h" => 3_600_000,
    "d" => 86_400_000
  }
  @stored_ms %{ms: 1, s: 1_000, days: 86_400_000}

  @type result ::
          {:ok, term()} | {:ok, {:model_ref, String.t(), String.t()}} | {:error, String.t()}

  @doc "Parse typed text into an entry's (or a record field's) wire value."
  @spec parse(Entry.t() | Field.t(), String.t()) :: result()
  def parse(target, text) when is_binary(text) do
    trimmed = String.trim(text)

    cond do
      String.downcase(trimmed) == "default" -> {:ok, reset_value(target)}
      String.downcase(trimmed) in ["null", "unset"] -> {:ok, nil}
      true -> parse_typed(target, trimmed, text)
    end
  end

  def parse(_target, _text), do: {:error, "is invalid"}

  @doc "The value `default` stands for: a session entry's unset, else the registry default."
  @spec reset_value(Entry.t() | Field.t()) :: term()
  def reset_value(%Entry{scope: :session, key: "session.mode"}), do: "build"
  def reset_value(%Entry{scope: :session, nullable: true}), do: nil
  def reset_value(%Entry{default: default}), do: default
  def reset_value(%Field{}), do: nil

  # --- entries --------------------------------------------------------------

  defp parse_typed(%Entry{} = entry, trimmed, raw) do
    case null_word(entry, trimmed) do
      {:ok, value} -> {:ok, value}
      :no -> entry_value(entry, trimmed, raw)
    end
  end

  defp parse_typed(%Field{} = field, trimmed, raw), do: field_value(field, trimmed, raw)

  defp null_word(%Entry{type: :lsp_command}, _text), do: :no

  defp null_word(%Entry{nullable: true, null_label: label}, text) when is_binary(label) do
    if String.downcase(text) == String.downcase(label), do: {:ok, nil}, else: none_word(text)
  end

  defp null_word(%Entry{nullable: true}, text), do: none_word(text)
  defp null_word(%Entry{}, _text), do: :no

  defp none_word(text),
    do: if(String.downcase(text) in ["none", "off", "no limit"], do: {:ok, nil}, else: :no)

  defp entry_value(%Entry{type: :toggle}, text, _raw), do: boolean(text)

  defp entry_value(%Entry{type: :enum} = entry, text, _raw), do: choice(entry.choices, text)

  defp entry_value(%Entry{type: :checklist} = entry, text, _raw) do
    items = split_list(text)

    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case choice(entry.choices, item) do
        {:ok, value} -> {:cont, {:ok, acc ++ [value]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp entry_value(%Entry{type: :integer} = entry, text, _raw) do
    case special(entry, text) do
      {:ok, value} -> {:ok, value}
      :no -> integer(strip_unit(text, entry.unit))
    end
  end

  defp entry_value(%Entry{type: :duration} = entry, text, _raw) do
    case special(entry, text) do
      {:ok, value} -> {:ok, value}
      :no -> duration(text, entry.unit || :s)
    end
  end

  defp entry_value(%Entry{type: :money}, text, _raw) do
    case number(String.trim_leading(text, "$")) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, "must be a whole number of dollars, zero or more"}
    end
  end

  defp entry_value(%Entry{type: :list}, text, _raw), do: {:ok, split_list(text)}
  defp entry_value(%Entry{type: :model}, text, _raw), do: model(text)
  defp entry_value(%Entry{type: :effort}, text, _raw), do: {:ok, String.downcase(text)}
  defp entry_value(%Entry{type: :path}, "", _raw), do: {:ok, nil}
  defp entry_value(%Entry{type: :path}, text, _raw), do: {:ok, text}

  defp entry_value(%Entry{type: :color}, text, _raw) do
    case Validate.normalise_hex(text) do
      nil -> {:error, "a colour such as #FF6A1A"}
      hex -> {:ok, hex}
    end
  end

  defp entry_value(%Entry{type: :lsp_command}, text, _raw), do: {:ok, text}
  defp entry_value(%Entry{type: :combo}, text, _raw), do: {:ok, text}

  defp entry_value(%Entry{type: type}, text, _raw) when type in [:keys, :map_readonly],
    do: json_map(text)

  defp entry_value(%Entry{type: :text}, _text, raw),
    do: {:ok, raw |> String.trim_trailing("\n") |> String.trim_trailing("\r")}

  defp entry_value(%Entry{}, _text, _raw), do: {:error, "read-only"}

  defp special(%Entry{special: special}, text) do
    folded = String.downcase(text)

    case Enum.find(special, fn {_value, label} -> String.downcase(label) == folded end) do
      {value, _label} -> {:ok, value}
      nil -> :no
    end
  end

  # --- record fields -------------------------------------------------------

  defp field_value(%Field{secret: true}, _text, _raw),
    do: {:error, "secrets are read from stdin"}

  defp field_value(%Field{type: :kv_secrets}, _text, _raw),
    do: {:error, "set one entry at a time: KIND:NAME.env.NAME"}

  defp field_value(%Field{type: :bool}, text, _raw), do: boolean(text)
  defp field_value(%Field{type: :integer}, text, _raw), do: integer(text)

  defp field_value(%Field{type: :number}, text, _raw) do
    case number(text) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, "must be a number"}
    end
  end

  defp field_value(%Field{type: :enum, choices: choices}, text, _raw),
    do: choice(Enum.map(choices, &%{value: &1, label: to_string(&1)}), text)

  defp field_value(%Field{type: :list}, text, _raw), do: {:ok, split_list(text)}
  defp field_value(%Field{type: :url}, "", _raw), do: {:ok, nil}
  defp field_value(%Field{type: :url}, text, _raw), do: {:ok, Validate.normalise_url(text)}

  defp field_value(%Field{type: :uuid}, text, _raw) do
    if Regex.match?(@uuid, text), do: {:ok, text}, else: {:error, "is invalid"}
  end

  defp field_value(%Field{type: type}, text, _raw) when type in [:map, :json], do: json(text)

  defp field_value(%Field{type: type}, _text, raw) when type in [:string, :text],
    do: {:ok, raw |> String.trim_trailing("\n") |> String.trim()}

  defp field_value(%Field{}, _text, _raw), do: {:error, "read-only"}

  # --- shared grammar -------------------------------------------------------

  defp boolean(text) do
    case String.downcase(text) do
      word when word in ["on", "true", "yes", "1", "enabled"] -> {:ok, true}
      word when word in ["off", "false", "no", "0", "disabled"] -> {:ok, false}
      _ -> {:error, "use on or off"}
    end
  end

  defp choice(choices, text) do
    folded = String.downcase(text)

    found =
      Enum.find(choices, fn %{value: value} = choice ->
        String.downcase(to_string(value)) == folded or
          String.downcase(to_string(Map.get(choice, :label) || "")) == folded
      end)

    case found do
      %{value: value} ->
        {:ok, value}

      nil ->
        values = Enum.map_join(choices, ", ", &to_string(&1.value))
        {:error, "is invalid; choose one of: #{values}"}
    end
  end

  defp integer(text) do
    case Integer.parse(String.replace(text, "_", "")) do
      {value, ""} ->
        {:ok, value}

      _ ->
        case Float.parse(text) do
          {value, ""} -> {:ok, value}
          _ -> {:error, "must be a whole number"}
        end
    end
  end

  defp number(text) do
    cleaned = String.replace(text, "_", "")

    case Integer.parse(cleaned) do
      {value, ""} ->
        {:ok, value}

      _ ->
        case Float.parse(cleaned) do
          {value, ""} -> {:ok, value}
          _ -> :error
        end
    end
  end

  defp strip_unit(text, :days), do: String.trim_trailing(String.trim_trailing(text, "d"), " days")
  defp strip_unit(text, :px), do: String.trim_trailing(text, "px")
  defp strip_unit(text, _unit), do: text

  defp duration(text, stored_unit) do
    case Regex.run(~r/\A(\d+(?:\.\d+)?)\s*(ms|s|min|m|h|d)?\z/i, text) do
      [_, amount] ->
        integer(amount)

      [_, amount, unit] ->
        {number, ""} = Float.parse(amount)
        ms = number * Map.fetch!(@unit_ms, String.downcase(unit))
        stored = ms / Map.fetch!(@stored_ms, stored_unit)

        if stored == Float.round(stored),
          do: {:ok, trunc(stored)},
          else: {:error, "use a whole number of #{unit_word(stored_unit)}"}

      _ ->
        {:error, "use a number with a unit, such as 90s, 30m or 2h"}
    end
  end

  defp unit_word(:ms), do: "milliseconds"
  defp unit_word(:s), do: "seconds"
  defp unit_word(:days), do: "days"

  defp model(text) do
    cond do
      String.starts_with?(text, "{") ->
        case json(text) do
          {:ok, %{"provider_id" => _, "model" => _} = map} -> {:ok, map}
          _ -> {:error, "use provider/model"}
        end

      match = Regex.run(~r/\A([0-9a-f\-]{36})[|\/](.+)\z/, text) ->
        [_, id, model] = match

        if Regex.match?(@uuid, id),
          do: {:ok, %{"provider_id" => id, "model" => String.trim(model)}},
          else: {:error, "use provider/model"}

      match = Regex.run(~r/\A([^\/]+)\/(.+)\z/, text) ->
        [_, provider, model] = match
        {:model_ref, String.trim(provider), String.trim(model)} |> then(&{:ok, &1})

      true ->
        {:error, "use provider/model"}
    end
  end

  defp split_list(text) do
    trimmed = String.trim(text)

    if trimmed in ["", "[]"] do
      []
    else
      trimmed
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
    end
  end

  defp json_map(text) do
    case json(text) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _} -> {:error, "must be a JSON object"}
      error -> error
    end
  end

  defp json(text) do
    case Jason.decode(text) do
      {:ok, value} -> {:ok, value}
      {:error, _} -> {:error, "is not valid JSON"}
    end
  end

  # --- format --------------------------------------------------------------

  @doc """
  Format a wire value as text the parser reads back. `opts[:providers]` maps
  provider ids to names for model values.
  """
  @spec format(Entry.t() | Field.t(), term(), keyword()) :: String.t()
  def format(target, value, opts \\ [])

  def format(%Entry{} = entry, nil, _opts), do: entry.null_label || "null"
  def format(%Field{}, nil, _opts), do: "null"
  def format(_target, true, _opts), do: "on"
  def format(_target, false, _opts), do: "off"

  def format(%Entry{type: type} = entry, value, _opts)
      when type in [:integer, :duration] and is_integer(value) do
    case Map.fetch(entry.special, value) do
      {:ok, label} -> label
      :error -> format_number(entry, value)
    end
  end

  def format(%Entry{type: :money}, value, _opts) when is_number(value), do: "$#{value}"

  def format(%Entry{type: :model}, %{"provider_id" => id, "model" => model}, opts) do
    case Map.get(Keyword.get(opts, :providers, %{}), id) do
      nil -> "#{id}|#{model}"
      name -> "#{name}/#{model}"
    end
  end

  def format(_target, value, _opts) when is_list(value),
    do: Enum.map_join(value, ", ", &to_string/1)

  def format(_target, value, _opts) when is_map(value), do: Jason.encode!(value)
  def format(_target, value, _opts) when is_binary(value), do: value
  def format(_target, value, _opts), do: to_string(value)

  defp format_number(%Entry{type: :duration, unit: :s}, value) do
    cond do
      value != 0 and rem(value, 3_600) == 0 -> "#{div(value, 3_600)}h"
      value != 0 and rem(value, 60) == 0 -> "#{div(value, 60)}m"
      true -> "#{value}s"
    end
  end

  defp format_number(%Entry{type: :duration, unit: :ms}, value) do
    cond do
      value != 0 and rem(value, 3_600_000) == 0 -> "#{div(value, 3_600_000)}h"
      value != 0 and rem(value, 60_000) == 0 -> "#{div(value, 60_000)}m"
      value != 0 and rem(value, 1_000) == 0 -> "#{div(value, 1_000)}s"
      true -> "#{value}ms"
    end
  end

  defp format_number(%Entry{type: :duration, unit: :days}, value), do: "#{value}d"
  defp format_number(%Entry{}, value), do: Integer.to_string(value)

  @doc false
  @spec record_kind_field(String.t(), String.t()) :: Field.t() | nil
  def record_kind_field(kind, field) do
    case RecordKind.fetch(kind) do
      {:ok, record_kind} -> RecordKind.field(record_kind, field)
      :error -> nil
    end
  end
end
