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

  alias SwarmCodeCLI.UI.Settings.Picker

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

  # The value column's room at this terminal size (the projector's layout:
  # the rail from 120 columns, the detail from 160, the value at 32, a tag).
  defp budget(%{size: %{columns: columns}}) when is_integer(columns) do
    page =
      cond do
        columns >= 160 -> columns - 27 - 49
        columns >= 120 -> columns - 27
        true -> columns
      end

    max(page - 32 - 12, 16)
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
    # §4.5 `‹ auto  read-only  full ›`; QA #2 P2-1: when the choices do not
    # fit the value column the ones around the focused choice are drawn (the
    # line was cut at its end, so a later choice, even the current, was never
    # seen while choosing).
    {first, last} = window(state, budget(ctx) - 4)

    shown =
      state.choices
      |> Enum.with_index()
      |> Enum.slice(first..last//1)
      |> Enum.flat_map(fn {choice, index} ->
        role = if index == state.index, do: :selection, else: :text_muted
        [{choice.label, role}, {"  ", :text_faint}]
      end)
      |> Enum.drop(-1)

    value =
      [{"‹ ", :text_faint}] ++
        if(first > 0, do: [{"… ", :text_faint}], else: []) ++
        shown ++
        if(last < length(state.choices) - 1, do: [{" …", :text_faint}], else: []) ++
        [{" ›", :text_faint}]

    hint =
      case Enum.at(state.choices, state.index) do
        %{hint: hint} when is_binary(hint) and hint != "" -> [[{hint, :text_faint}]]
        _ -> []
      end

    %{
      value: value,
      lines: hint,
      popover: nil,
      context: :settings_edit,
      footer: [{"←→", "choose"}, {"Enter", "save"}, {"Esc", "cancel"}]
    }
  end
end
