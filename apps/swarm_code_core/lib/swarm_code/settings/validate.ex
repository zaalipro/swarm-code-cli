defmodule SwarmCode.Settings.Validate do
  @moduledoc """
  The registry's validators, as data (pass 74, spec §3.2.4).

  `check/2` runs an entry's validators on a wire value and answers the first
  failing validator's exact message (the desktop changeset's text where one
  exists). `{:svc, check}` validators are the service's: `check/2` passes them
  (the daemon runs them with `svc_checks/1`). `normalise/2` applies the
  desktop's normalisations first (domains, variable names, colours, paths).
  """

  alias SwarmCode.Settings.{Entry, WireValue}

  @defaults %{
    range: "must be between {min} and {max}",
    min: "must be greater than or equal to {n}",
    max: "must be less than or equal to {n}",
    inclusion: "is invalid",
    format: "has invalid format",
    max_length: "should be at most {n} character(s)",
    required: "can't be blank",
    one_line: "one line only",
    list_max: "too many items ({n} max)",
    unique_items: "already in the list",
    hex_color: "a colour such as #FF6A1A",
    whole_dollars: "must be a whole number of dollars, zero or more"
  }

  @item_messages %{
    domain: "not a domain: {item}",
    env_name: "use a variable name: A–Z, 0–9 and _",
    command_family: "can't be blank",
    model_id: "can't be blank",
    text: "can't be blank"
  }

  @hint_messages [
    "only lowercase letters a–z",
    "each letter once",
    "use at least 8 letters",
    "y a d n q answer approvals or close; they cannot be hint letters"
  ]

  @env_name ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/

  @doc "The default message of a validator key (for docs and tests)."
  @spec default_message(atom()) :: String.t() | nil
  def default_message(key), do: Map.get(@defaults, key)

  @doc "The four hint-letter messages, in the order they are checked."
  @spec hint_letter_messages() :: [String.t()]
  def hint_letter_messages, do: @hint_messages

  @doc "The `{:svc, check}` validators of an entry (the service runs these)."
  @spec svc_checks(Entry.t()) :: [atom()]
  def svc_checks(%Entry{validate: validators}),
    do: for({:svc, check} <- validators, do: check)

  @doc "Check a (normalised) wire value against the entry. `:ok` or the first message."
  @spec check(Entry.t(), term()) :: :ok | {:error, String.t()}
  def check(%Entry{} = entry, nil) do
    if WireValue.type_ok?(entry, nil), do: :ok, else: {:error, message(entry, :required, %{})}
  end

  def check(%Entry{} = entry, value) do
    cond do
      not shape_ok?(entry, value) ->
        {:error, shape_message(entry)}

      true ->
        case Enum.find_value(entry.validate, &run(entry, &1, value)) do
          nil ->
            if WireValue.type_ok?(entry, value),
              do: :ok,
              else: {:error, shape_message(entry)}

          message ->
            {:error, message}
        end
    end
  end

  @doc "Apply the desktop normalisations of an entry to a wire value."
  @spec normalise(Entry.t(), term()) :: term()
  def normalise(%Entry{type: :list, item: :domain}, value) when is_list(value) do
    value
    |> Enum.flat_map(&split_items(&1, ~r/[\s,]+/u))
    |> Enum.map(&normalise_domain/1)
    |> Enum.reject(&(&1 == ""))
  end

  def normalise(%Entry{type: :list, item: :env_name}, value) when is_list(value) do
    value
    |> Enum.flat_map(&split_items(&1, ~r/,/))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  def normalise(%Entry{type: :list}, value) when is_list(value),
    do: Enum.map(value, fn item -> if is_binary(item), do: String.trim(item), else: item end)

  def normalise(%Entry{type: :color}, value) when is_binary(value),
    do: normalise_hex(value) || value

  def normalise(%Entry{type: :path, nullable: true}, value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def normalise(%Entry{type: type}, value)
      when type in [:effort, :lsp_command, :combo] and is_binary(value),
      do: String.trim(value)

  def normalise(%Entry{} = entry, value) do
    value = WireValue.normalize(entry, value)

    if :hex_color in entry.validate and is_binary(value),
      do: normalise_hex(value) || value,
      else: value
  end

  defp split_items(item, pattern) when is_binary(item), do: String.split(item, pattern)
  defp split_items(item, _pattern), do: [item]

  defp normalise_domain(item) when is_binary(item) do
    item
    |> String.trim()
    |> String.replace(~r{\Ahttps?://}i, "")
    |> String.trim_trailing("/")
  end

  defp normalise_domain(item), do: item

  @doc "A URL as the desktop stores it: trimmed, without a trailing `/`."
  @spec normalise_url(String.t()) :: String.t()
  def normalise_url(url) when is_binary(url),
    do: url |> String.trim() |> String.trim_trailing("/")

  @doc "`#RGB`, `RRGGBB` or `#rrggbb` as upper-case `#RRGGBB`, else nil."
  @spec normalise_hex(String.t()) :: String.t() | nil
  def normalise_hex(text) when is_binary(text) do
    hex = text |> String.trim() |> String.trim_leading("#")

    cond do
      Regex.match?(~r/\A[0-9a-fA-F]{6}\z/, hex) ->
        "#" <> String.upcase(hex)

      Regex.match?(~r/\A[0-9a-fA-F]{3}\z/, hex) ->
        "#" <> (hex |> String.graphemes() |> Enum.map_join(&(&1 <> &1)) |> String.upcase())

      true ->
        nil
    end
  end

  def normalise_hex(_text), do: nil

  @doc "Check hint letters (§2.16), in the spec's order. `:ok` or the message."
  @spec hint_letters(term()) :: :ok | {:error, String.t()}
  def hint_letters(value) when is_binary(value) do
    letters = String.graphemes(value)
    [only, once, at_least, reserved] = @hint_messages

    cond do
      not Enum.all?(letters, &(&1 =~ ~r/\A[a-z]\z/)) -> {:error, only}
      Enum.uniq(letters) != letters -> {:error, once}
      length(letters) < 8 -> {:error, at_least}
      Enum.any?(letters, &(&1 in ~w(y a d n q))) -> {:error, reserved}
      true -> :ok
    end
  end

  def hint_letters(_value), do: {:error, hd(@hint_messages)}

  # --- validators -----------------------------------------------------------

  defp run(entry, {:range, min, max}, value) when is_number(value) do
    if value >= min and value <= max,
      do: nil,
      else: message(entry, :range, %{"{min}" => min, "{max}" => max})
  end

  defp run(entry, {:special_or_range, specials, min, max}, value) when is_number(value) do
    if value in specials or (value >= min and value <= max),
      do: nil,
      else: message(entry, :range, %{"{min}" => min, "{max}" => max})
  end

  defp run(entry, {:min, n}, value) when is_number(value),
    do: if(value >= n, do: nil, else: message(entry, :min, %{"{n}" => n}))

  defp run(entry, {:max, n}, value) when is_number(value),
    do: if(value <= n, do: nil, else: message(entry, :max, %{"{n}" => n}))

  defp run(entry, :inclusion, value),
    do: if(value in Entry.choice_values(entry), do: nil, else: message(entry, :inclusion, %{}))

  defp run(entry, {:format, source}, value) when is_binary(value) do
    if Regex.match?(Regex.compile!(source), value),
      do: nil,
      else: message(entry, :format, %{})
  end

  defp run(entry, {:max_length, n}, value) when is_binary(value),
    do: if(String.length(value) <= n, do: nil, else: message(entry, :max_length, %{"{n}" => n}))

  defp run(entry, :required, value) when is_binary(value),
    do: if(String.trim(value) == "", do: message(entry, :required, %{}), else: nil)

  defp run(entry, :required, value) when is_list(value),
    do: if(value == [], do: message(entry, :required, %{}), else: nil)

  defp run(entry, :one_line, value) when is_binary(value),
    do: if(String.contains?(value, ["\n", "\r"]), do: message(entry, :one_line, %{}), else: nil)

  defp run(entry, {:list_max, n}, value) when is_list(value),
    do: if(length(value) <= n, do: nil, else: message(entry, :list_max, %{"{n}" => n}))

  defp run(entry, :unique_items, value) when is_list(value),
    do: if(Enum.uniq(value) == value, do: nil, else: message(entry, :unique_items, %{}))

  defp run(entry, {:item, kind}, value) when is_list(value),
    do: Enum.find_value(value, &item_error(entry, kind, &1))

  defp run(entry, :hex_color, value) when is_binary(value) do
    if Regex.match?(~r/\A#[0-9A-F]{6}\z/, value),
      do: nil,
      else: message(entry, :hex_color, %{})
  end

  defp run(_entry, :hint_letters, value) do
    case hint_letters(value) do
      :ok -> nil
      {:error, message} -> message
    end
  end

  defp run(entry, :whole_dollars, value) do
    if is_integer(value) and value >= 0,
      do: nil,
      else: message(entry, :whole_dollars, %{})
  end

  defp run(_entry, {:svc, _check}, _value), do: nil
  defp run(_entry, _validator, _value), do: nil

  defp item_error(_entry, :domain, item) when is_binary(item) do
    if item == "" or String.contains?(item, [" ", "\t", "\n"]),
      do: String.replace(@item_messages.domain, "{item}", item),
      else: nil
  end

  defp item_error(_entry, :env_name, item) when is_binary(item),
    do: if(Regex.match?(@env_name, item), do: nil, else: @item_messages.env_name)

  defp item_error(_entry, :command_family, item) when is_binary(item) do
    cond do
      String.trim(item) == "" -> "can't be blank"
      String.contains?(item, ["\n", "\r"]) -> "one line only"
      byte_size(item) > 200 -> "should be at most 200 character(s)"
      true -> nil
    end
  end

  defp item_error(_entry, kind, item) when is_binary(item) and kind in [:model_id, :text],
    do: if(String.trim(item) == "", do: Map.fetch!(@item_messages, kind), else: nil)

  defp item_error(_entry, _kind, _item), do: "is invalid"

  defp shape_ok?(%Entry{type: type}, value) when type in [:integer, :duration, :money],
    do: is_integer(value)

  defp shape_ok?(%Entry{type: :toggle}, value), do: is_boolean(value)
  defp shape_ok?(%Entry{type: type}, value) when type in [:list, :checklist], do: is_list(value)

  defp shape_ok?(%Entry{type: type}, value)
       when type in [:text, :path, :effort, :lsp_command, :combo, :color],
       do: is_binary(value)

  defp shape_ok?(%Entry{type: :model}, value), do: is_map(value)
  defp shape_ok?(%Entry{type: type}, value) when type in [:keys, :map_readonly], do: is_map(value)
  defp shape_ok?(%Entry{type: :enum}, value), do: is_binary(value) or is_integer(value)
  defp shape_ok?(%Entry{}, _value), do: true

  defp shape_message(%Entry{type: :money} = entry), do: message(entry, :whole_dollars, %{})

  defp shape_message(%Entry{type: type, min: min, max: max} = entry)
       when type in [:integer, :duration] and is_integer(min) and is_integer(max),
       do: message(entry, :range, %{"{min}" => min, "{max}" => max})

  defp shape_message(%Entry{type: :color} = entry), do: message(entry, :hex_color, %{})
  defp shape_message(entry), do: message(entry, :inclusion, %{})

  defp message(%Entry{messages: messages}, key, bindings) do
    template = Map.get(messages, key) || Map.fetch!(@defaults, key)

    Enum.reduce(bindings, template, fn {name, value}, text ->
      String.replace(text, name, to_string(value))
    end)
  end
end
