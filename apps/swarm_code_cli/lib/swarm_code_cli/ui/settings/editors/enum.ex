defmodule SwarmCodeCLI.UI.Settings.Editors.Enum do
  @moduledoc """
  An enum (spec §3.7.8): segmented when its choices fit the value column —
  ← → move, Enter writes, Esc puts the old value back, a letter jumps to the
  choice that starts with it. (More than five choices, or too wide: the
  layer opens a picker popover instead, `picker/2`.)

  Opts: `choices` (`[%{value, label, hint}]`, or plain values), `value`,
  `nullable`, `null_label`.
  """

  @behaviour SwarmCodeCLI.UI.Settings.Editor

  alias SwarmCodeCLI.UI.Settings.{Grid, Picker}

  @segmented_max 5

  @doc "The choices of `opts` as `%{value, label, hint}` maps (with the null choice)."
  @spec choices(map()) :: [map()]
  def choices(opts) do
    listed =
      opts
      |> Map.get(:choices, [])
      |> Enum.map(fn
        %{value: _} = choice ->
          Map.merge(%{label: to_string(choice.value), hint: nil}, choice)

        %{"value" => value} = choice ->
          %{
            value: value,
            label: Map.get(choice, "label", to_string(value)),
            hint: Map.get(choice, "hint")
          }

        value ->
          %{value: value, label: to_string(value), hint: nil}
      end)

    if Map.get(opts, :nullable, false),
      do: [%{value: nil, label: Map.get(opts, :null_label) || "none", hint: nil} | listed],
      else: listed
  end

  @doc "Whether the choices are few enough to show side by side."
  @spec segmented?(map()) :: boolean()
  def segmented?(opts), do: length(choices(opts)) <= @segmented_max

  @doc "The choice after (`1`) or before (`-1`) `value`, stopping at the ends."
  @spec step(map(), term(), integer()) :: term()
  def step(opts, value, delta) do
    list = choices(opts)
    index = Enum.find_index(list, &(&1.value == value)) || 0
    Enum.at(list, min(max(index + delta, 0), length(list) - 1)).value
  end

  @doc "The label of `value` among the choices (the value itself when unknown)."
  @spec label(map(), term()) :: String.t()
  def label(opts, value) do
    case Enum.find(choices(opts), &(&1.value == value)) do
      %{label: label} -> label
      nil -> to_string(value)
    end
  end

  @doc "A picker popover over the choices (more than five of them)."
  @spec picker(String.t(), map()) :: Picker.t()
  def picker(title, opts) do
    list = choices(opts)

    %Picker{
      id: "enum",
      title: title,
      options: list,
      current: Map.get(opts, :value),
      cursor: Enum.find_index(list, &(&1.value == Map.get(opts, :value))) || 0,
      filter?: length(list) > 8
    }
  end

  @impl true
  def init(_row, opts, _ctx) do
    list = choices(opts)

    case list do
      [] ->
        {:error, "nothing to choose from"}

      _ ->
        index = Enum.find_index(list, &(&1.value == Map.get(opts, :value))) || 0
        {:ok, %{choices: list, index: index, original: Map.get(opts, :value)}}
    end
  end

  @impl true
  def handle(state, {:key, key}, _ctx) when key in [:left, :up],
    do: {:cont, %{state | index: max(state.index - 1, 0)}}

  def handle(state, {:key, key}, _ctx) when key in [:right, :down, :space],
    do: {:cont, %{state | index: min(state.index + 1, length(state.choices) - 1)}}

  def handle(state, {:key, :home}, _ctx), do: {:cont, %{state | index: 0}}
  def handle(state, {:key, :end}, _ctx), do: {:cont, %{state | index: length(state.choices) - 1}}
  def handle(state, {:key, :enter}, _ctx), do: {:commit, current(state), state}
  def handle(state, {:key, :escape}, _ctx), do: {:cancel, state}

  def handle(state, {:text, text}, _ctx) do
    needle = String.downcase(text)

    case Enum.find_index(state.choices, &String.starts_with?(String.downcase(&1.label), needle)) do
      nil -> {:cont, state}
      index -> {:cont, %{state | index: index}}
    end
  end

  def handle(state, _event, _ctx), do: {:cont, state}

  defp current(state), do: Enum.at(state.choices, state.index).value

  # The value column's room at this terminal size: the grid's page from the
  # value column, less a gap and the tag's room (pass 75), at least 12.
  defp budget(%{size: %{columns: columns, rows: rows}})
       when is_integer(columns) and is_integer(rows) do
    case Grid.for(columns, rows) do
      %Grid{page: %{width: width}, value_offset: offset} -> max(width - offset - 4, 12)
      %Grid{} -> 12
    end
  end

  defp budget(_ctx), do: 60

  # The first and last choice drawn: all when they fit, else as many as fit
  # around the focused one.
  defp window(state, room) do
    widths = Enum.map(state.choices, &(String.length(&1.label) + 2))
    count = length(widths)

    if Enum.sum(widths) <= room + 2 do
      {0, count - 1}
    else
      grow(widths, state.index, state.index, Enum.at(widths, state.index), room - 4)
    end
  end

  defp grow(widths, first, last, used, room) do
    right = if last + 1 < length(widths), do: Enum.at(widths, last + 1)
    left = if first > 0, do: Enum.at(widths, first - 1)

    cond do
      right && used + right <= room -> grow(widths, first, last + 1, used + right, room)
      left && used + left <= room -> grow(widths, first - 1, last, used + left, room)
      true -> {first, last}
    end
  end

  @impl true
  def display(state, ctx) do
    # Pass 75 (E): a segmented control on the row: the candidate is the one
    # accent-backed word, the saved value is underlined, the others muted,
    # three cells apart; `…` at a windowed end (QA #2 P2-1: the choices
    # around the candidate stay in view when they do not all fit).
    {first, last} = window(state, budget(ctx) - 4)

    shown =
      state.choices
      |> Enum.with_index()
      |> Enum.slice(first..last//1)
      |> Enum.map(fn {choice, index} ->
        cond do
          index == state.index -> {" " <> choice.label <> " ", {:on_accent, [:bold]}}
          choice.value == state.original -> {choice.label, {:text_primary, [:underline]}}
          true -> {choice.label, :text_muted}
        end
      end)

    value =
      if(first > 0, do: [{"…", :text_faint}], else: [])
      |> Kernel.++(shown)
      |> Kernel.++(if(last < length(state.choices) - 1, do: [{"…", :text_faint}], else: []))
      |> Enum.intersperse({"   ", :text_primary})

    candidate = Enum.at(state.choices, state.index)

    words =
      case candidate do
        %{hint: hint} when is_binary(hint) and hint != "" -> [{hint, :text_muted}]
        _ -> []
      end

    unsaved =
      if candidate && candidate.value != state.original,
        do: [{"not saved", :warning}],
        else: []

    %{
      value: value,
      lines: if(words ++ unsaved == [], do: [], else: [words ++ unsaved]),
      popover: nil,
      context: :settings_edit,
      footer: [{"←→", "choose"}, {"Enter", "save"}, {"Esc", "cancel"}]
    }
  end
end
