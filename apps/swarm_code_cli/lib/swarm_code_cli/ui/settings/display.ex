defmodule SwarmCodeCLI.UI.Settings.Display do
  @moduledoc """
  A setting's value in the row's value column (spec §4.5), as `[{text,
  role}]` segments. Pure; the projector clips to the column.
  """

  alias SwarmCode.Settings.Entry

  @list_items 3
  @invalid_raw 40

  @doc "The value segments of `entry` holding `value` (`setting` is its SettingValue, or nil)."
  @spec value(Entry.t(), term(), map() | nil, map()) :: [{String.t(), atom()}]
  def value(entry, value, setting \\ nil, lookups \\ %{})

  def value(%Entry{} = entry, _value, %{state: state} = setting, _lookups)
      when state in [:invalid, "invalid"] do
    raw = setting |> Map.get(:note) |> raw_words(setting)
    _ = entry
    [{"✗ stored value not understood: " <> clip(raw, @invalid_raw), :error}]
  end

  def value(%Entry{type: :fact}, value, _setting, _lookups), do: [{words(value), :text_muted}]

  def value(%Entry{type: type} = entry, _value, _setting, _lookups) when type in [:action, :link],
    do: [{"▸ " <> entry.label, :text_primary}]

  def value(%Entry{secret: true}, value, _setting, _lookups) do
    if value in [nil, "", false],
      do: [{"not set", :text_ghost}],
      else: [{"●●●●●●●●", :text_primary}]
  end

  def value(%Entry{nullable: true} = entry, nil, _setting, _lookups),
    do: [{entry.null_label || "not set", :text_muted}]

  def value(%Entry{type: :toggle}, value, _setting, _lookups),
    do: [{if(value == true, do: "on", else: "off"), :text_primary}]

  def value(%Entry{type: type} = entry, value, setting, _lookups) when type in [:enum, :effort] do
    choices = choices(entry, setting)

    label =
      case Enum.find(choices, &(choice_value(&1) == value)) do
        nil -> words(value)
        choice -> choice_label(choice)
      end

    [{label, :text_primary}]
  end

  def value(%Entry{type: type} = entry, value, _setting, _lookups)
      when type in [:integer, :duration, :money] and is_number(value) do
    case Map.fetch(entry.special || %{}, value) do
      {:ok, label} -> [{label, :text_primary}]
      :error -> [{number(entry, value), :text_primary}]
    end
  end

  def value(%Entry{type: :model}, %{} = value, _setting, lookups) do
    provider_id = field(value, "provider_id")
    model = field(value, "model") || ""
    providers = Map.get(lookups, :providers)

    cond do
      is_map(providers) and Map.has_key?(providers, provider_id) ->
        [{model, :text_primary}, {" · " <> Map.fetch!(providers, provider_id), :text_faint}]

      is_map(providers) ->
        [{"! the provider was deleted; pick another", :warning}]

      true ->
        [{model, :text_primary}]
    end
  end

  def value(%Entry{type: :color}, value, _setting, _lookups) when is_binary(value),
    do: [{"[" <> value <> "]", :text_muted}, {" " <> value, :text_primary}]

  def value(%Entry{type: :color}, _value, _setting, _lookups),
    do: [{"Carbon", :text_muted}]

  def value(%Entry{type: :keys}, value, _setting, _lookups) when is_map(value) do
    case map_size(value) do
      0 -> [{"defaults", :text_muted}]
      1 -> [{"1 binding changed", :text_primary}]
      n -> [{"#{n} bindings changed", :text_primary}]
    end
  end

  def value(%Entry{type: :map_readonly}, value, _setting, _lookups) when is_map(value),
    do: [{entries(map_size(value)) <> names(Map.keys(value)), :text_muted}]

  def value(%Entry{type: :path}, value, _setting, lookups) when is_binary(value),
    do: [{home(value, Map.get(lookups, :home)), :text_primary}]

  def value(%Entry{}, value, _setting, _lookups) when is_list(value) do
    case value do
      [] ->
        [{"none", :text_ghost}]

      items ->
        shown = items |> Enum.take(@list_items) |> Enum.map_join(", ", &words/1)
        more = length(items) - @list_items
        [{shown, :text_primary}] ++ if(more > 0, do: [{" +#{more} more", :text_faint}], else: [])
    end
  end

  def value(%Entry{}, value, _setting, _lookups) when is_binary(value) do
    case String.split(value, "\n") do
      [""] -> [{"empty", :text_ghost}]
      [line] -> [{line, :text_primary}]
      [line | rest] -> [{line, :text_primary}, {" (+#{length(rest)} lines)", :text_faint}]
    end
  end

  def value(%Entry{}, nil, _setting, _lookups), do: [{"not set", :text_ghost}]
  def value(%Entry{}, value, _setting, _lookups), do: [{words(value), :text_primary}]

  @doc "The choices of an enum or effort entry: the SettingValue's dynamic ones, else the entry's."
  @spec choices(Entry.t(), map() | nil) :: [map()]
  def choices(%Entry{} = entry, setting) do
    case setting && Map.get(setting, :choices) do
      [_ | _] = dynamic -> dynamic
      _ -> entry.choices || []
    end
  end

  defp choice_value(%{value: value}), do: value
  defp choice_value(%{"value" => value}), do: value
  defp choice_value(value), do: value

  defp choice_label(%{label: label}) when is_binary(label), do: label
  defp choice_label(%{"label" => label}) when is_binary(label), do: label
  defp choice_label(choice), do: words(choice_value(choice))

  @doc """
  A number in words: durations by their largest whole unit (`30 min`,
  `2 h`, `1.5 s` stays `1500 ms`), money as dollars, other units plain.
  """
  @spec number(Entry.t(), number()) :: String.t()
  def number(%Entry{type: :money}, value), do: "$" <> plain(value)

  def number(%Entry{type: :duration, unit: :ms}, value) when is_integer(value),
    do: duration(value)

  def number(%Entry{type: :duration, unit: :s}, value) when is_integer(value),
    do: duration(value * 1_000)

  def number(%Entry{unit: :days}, 1), do: "1 day"
  def number(%Entry{unit: :days}, value), do: plain(value) <> " days"
  def number(%Entry{unit: :usd}, value), do: "$" <> plain(value)
  def number(%Entry{}, value), do: plain(value)

  @doc "A duration of `ms` milliseconds by its largest whole unit."
  @spec duration(integer()) :: String.t()
  def duration(0), do: "0 s"

  def duration(ms) do
    cond do
      rem(ms, 86_400_000) == 0 -> "#{div(ms, 86_400_000)} d"
      rem(ms, 3_600_000) == 0 -> "#{div(ms, 3_600_000)} h"
      rem(ms, 60_000) == 0 -> "#{div(ms, 60_000)} min"
      rem(ms, 1_000) == 0 -> "#{div(ms, 1_000)} s"
      true -> "#{ms} ms"
    end
  end

  defp plain(value) when is_float(value) do
    if value == Float.round(value), do: Integer.to_string(trunc(value)), else: to_string(value)
  end

  defp plain(value), do: to_string(value)

  @doc "The stored raw text of an invalid value, for the row and the detail."
  @spec raw_words(term(), map()) :: String.t()
  def raw_words(note, setting) do
    raw =
      setting
      |> Map.get(:layers, [])
      |> Enum.find_value(fn layer -> Map.get(layer, :raw) end)

    cond do
      is_binary(raw) -> raw
      is_binary(note) -> note
      true -> "?"
    end
  end

  @doc "Cut `text` to `max` characters with `…`."
  @spec clip(String.t(), pos_integer()) :: String.t()
  def clip(text, max) do
    if String.length(text) <= max, do: text, else: String.slice(text, 0, max - 1) <> "…"
  end

  @doc "A value in words, one line (never inspect output)."
  @spec words(term()) :: String.t()
  def words(nil), do: "not set"
  def words(true), do: "on"
  def words(false), do: "off"
  def words(value) when is_binary(value), do: String.replace(value, ["\r\n", "\n", "\r"], " ")
  def words(value) when is_atom(value) or is_number(value), do: to_string(value)
  def words(value) when is_list(value), do: Enum.map_join(value, ", ", &words/1)
  def words(value) when is_map(value), do: entries(map_size(value))
  def words(_value), do: "?"

  defp entries(1), do: "1 entry"
  defp entries(n), do: "#{n} entries"

  defp names([]), do: ""

  defp names(keys) do
    shown = keys |> Enum.map(&to_string/1) |> Enum.sort() |> Enum.take(@list_items)
    " · " <> Enum.join(shown, ", ")
  end

  @doc "`path` with the home directory written `~`."
  @spec home(String.t(), String.t() | nil) :: String.t()
  def home(path, home) when is_binary(home) and home != "" do
    cond do
      path == home -> "~"
      String.starts_with?(path, home <> "/") -> "~" <> String.replace_prefix(path, home, "")
      true -> path
    end
  end

  def home(path, _home), do: path

  defp field(map, "provider_id"), do: Map.get(map, "provider_id") || Map.get(map, :provider_id)
  defp field(map, "model"), do: Map.get(map, "model") || Map.get(map, :model)

  @doc "The words of a value for a toast (`Side panel → compact`)."
  @spec toast_words(Entry.t(), term(), map() | nil) :: String.t()
  def toast_words(entry, value, setting \\ nil) do
    entry
    |> value(value, setting && Map.delete(setting, :state), %{})
    |> Enum.map_join("", &elem(&1, 0))
  end
end
