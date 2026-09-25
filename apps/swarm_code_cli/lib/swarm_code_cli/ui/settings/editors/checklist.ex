defmodule SwarmCodeCLI.UI.Settings.Editors.Checklist do
  @moduledoc """
  A checklist (spec §3.7.8): ↑↓ move, Space ticks, Enter writes the
  ticked values in the choices' order, Esc puts them back. A list of more
  than 20 items takes a filter as you type. Opts: `choices` (`%{value,
  label, hint}`), `value` (the ticked values).
  """

  @behaviour SwarmCodeCLI.UI.Settings.Editor

  alias SwarmCodeCLI.UI.Settings.Editors.Enum, as: EnumEditor

  @filter_over 20

  @impl true
  def init(_row, opts, _ctx) do
    choices = EnumEditor.choices(Map.delete(opts, :nullable))
    ticked = MapSet.new(List.wrap(Map.get(opts, :value)))
    {:ok, %{choices: choices, ticked: ticked, cursor: 0, query: ""}}
  end

  @impl true
  def handle(state, {:key, :up}, _ctx), do: {:cont, move(state, -1)}
  def handle(state, {:key, :down}, _ctx), do: {:cont, move(state, 1)}
  def handle(state, {:key, :home}, _ctx), do: {:cont, %{state | cursor: 0}}

  def handle(state, {:key, :end}, _ctx),
    do: {:cont, %{state | cursor: max(length(visible(state)) - 1, 0)}}

  def handle(state, {:key, :space}, _ctx), do: {:cont, tick(state)}
  def handle(state, {:text, " "}, _ctx), do: {:cont, tick(state)}

  def handle(state, {:key, :enter}, _ctx) do
    value =
      for choice <- state.choices, MapSet.member?(state.ticked, choice.value), do: choice.value

    {:commit, value, state}
  end

  def handle(state, {:key, :escape}, _ctx), do: {:cancel, state}

  def handle(state, {:text, text}, _ctx) do
    if length(state.choices) > @filter_over,
      do: {:cont, %{state | query: String.slice(state.query <> text, 0, 60), cursor: 0}},
      else: {:cont, state}
  end

  def handle(state, {:key, :backspace}, _ctx),
    do:
      {:cont,
       %{
         state
         | query: String.slice(state.query, 0, max(String.length(state.query) - 1, 0)),
           cursor: 0
       }}

  def handle(state, _event, _ctx), do: {:cont, state}

  defp move(state, delta) do
    count = length(visible(state))
    %{state | cursor: if(count == 0, do: 0, else: min(max(state.cursor + delta, 0), count - 1))}
  end

  defp tick(state) do
    case Enum.at(visible(state), state.cursor) do
      nil ->
        state

      choice ->
        ticked =
          if MapSet.member?(state.ticked, choice.value),
            do: MapSet.delete(state.ticked, choice.value),
            else: MapSet.put(state.ticked, choice.value)

        %{state | ticked: ticked}
    end
  end

  defp visible(%{query: ""} = state), do: state.choices

  defp visible(state) do
    query = String.downcase(state.query)
    Enum.filter(state.choices, &String.contains?(String.downcase(&1.label), query))
  end

  @impl true
  def display(state, _ctx) do
    count = MapSet.size(state.ticked)

    lines =
      state
      |> visible()
      |> Enum.with_index()
      |> Enum.map(fn {choice, index} ->
        box = if MapSet.member?(state.ticked, choice.value), do: "[✓] ", else: "[ ] "
        role = if index == state.cursor, do: :selection, else: :text_primary
        [{box, :text_muted}, {choice.label, role}]
      end)

    filter = if state.query == "", do: [], else: [[{"/ " <> state.query, :info}]]

    %{
      value: [{"#{count} ticked", :text_primary}],
      lines: filter ++ lines,
      popover: nil,
      context: :settings_edit,
      footer: [{"Space", "tick"}, {"Enter", "save"}, {"Esc", "cancel"}]
    }
  end
end
