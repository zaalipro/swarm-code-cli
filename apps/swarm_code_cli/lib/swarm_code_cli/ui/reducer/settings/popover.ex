defmodule SwarmCodeCLI.UI.Reducer.Settings.Popover do
  @moduledoc """
  The settings layer's popovers (spec §4.8, §4.12, T§12): while one is open
  it owns every key — Tab and Shift-Tab stay inside it, Esc closes it once,
  and the page under it keeps its cursor (the opener).

    * `{:confirm, %{confirm: %Confirm{}, then: ops}}` — the safe button is
      focused first; Enter presses the focused button; the destructive
      letter presses it directly; a typed confirmation (`delete 14`) takes
      the typed text first and keeps the button disabled until it matches;
      `counting?` keeps it disabled until the counts arrive.
    * `{:picker, %Picker{}}` — ↑↓ PgUp PgDn Home End move, typing filters,
      Enter chooses (`on_pick`), Esc closes.
    * `{:help, %{scroll: n}}` — the keys sheet; ↑↓ scroll it.
    * `{:pending, %{items, then, save}}` — things not saved on leaving a
      page: `s` saves what can be saved, `d` discards, Esc stays.
  """

  alias SwarmCodeCLI.UI.Reducer.Settings.{Commit, Edit, Ops}
  alias SwarmCodeCLI.UI.Settings.{Confirm, Layer, Nav, Picker, Row, Sections}

  @picker_page 10

  @doc "One event while a popover is open."
  @spec event(map(), term()) :: {map(), list()}
  def event(%{settings: %Layer{popover: {kind, body}}} = state, event) do
    handle(state, kind, body, event)
  end

  def event(state, _event), do: {state, []}

  # --------------------------------------------------------------- help

  defp handle(state, :help, body, {:verb, verb})
       when verb in [:up, :down, :page_up, :page_down] do
    delta = %{up: -1, down: 1, page_up: -10, page_down: 10}[verb]
    {put(state, {:help, %{body | scroll: max(body.scroll + delta, 0)}}), []}
  end

  defp handle(state, :help, _body, {:verb, verb}) when verb in [:escape, :back, :help, :close],
    do: close(state)

  defp handle(state, :help, _body, _event), do: {state, []}

  # ------------------------------------------------------------ confirm

  defp handle(state, :confirm, body, {:verb, verb})
       when verb in [:next_button, :previous_button, :left, :right] do
    confirm = body.confirm
    focus = if confirm.focus == :safe and enabled?(confirm), do: :danger, else: :safe
    {put(state, {:confirm, %{body | confirm: %{confirm | focus: focus}}}), []}
  end

  defp handle(state, :confirm, body, {:verb, verb}) when verb in [:enter, :commit] do
    if body.confirm.focus == :danger and enabled?(body.confirm),
      do: press(state, body),
      else: close(state)
  end

  defp handle(state, :confirm, _body, {:verb, verb})
       when verb in [:escape, :back, :close, :interrupt],
       do: close(state)

  defp handle(
         state,
         :confirm,
         %{confirm: %Confirm{typed: typed} = confirm} = body,
         {:verb, :backspace}
       )
       when is_binary(typed) do
    input = String.slice(confirm.input, 0, max(String.length(confirm.input) - 1, 0))
    {put(state, {:confirm, %{body | confirm: %{confirm | input: input}}}), []}
  end

  defp handle(state, :confirm, %{confirm: %Confirm{typed: typed} = confirm} = body, {:text, text})
       when is_binary(typed) do
    input = String.slice(confirm.input <> text, 0, 64)
    {put(state, {:confirm, %{body | confirm: %{confirm | input: input}}}), []}
  end

  # The destructive letter presses its button (a verb binding or a typed letter).
  defp handle(state, :confirm, %{confirm: %Confirm{letter: letter}} = body, event)
       when is_binary(letter) do
    if letter?(event, letter) and enabled?(body.confirm),
      do: press(state, body),
      else: {state, []}
  end

  defp handle(state, :confirm, _body, _event), do: {state, []}

  # ------------------------------------------------------------- picker

  defp handle(state, kind, %Picker{} = picker, {:verb, verb})
       when kind in [:picker, :project_picker] and
              verb in [:up, :down, :page_up, :page_down, :first, :last] do
    count = length(Picker.visible(picker))

    cursor =
      case verb do
        :up -> picker.cursor - 1
        :down -> picker.cursor + 1
        :page_up -> picker.cursor - @picker_page
        :page_down -> picker.cursor + @picker_page
        :first -> 0
        :last -> count - 1
      end

    {put(state, {kind, %{picker | cursor: clamp(cursor, count)}}), []}
  end

  defp handle(state, kind, %Picker{} = picker, {:text, text})
       when kind in [:picker, :project_picker] do
    if picker.filter?,
      do:
        {put(
           state,
           {kind, %{picker | query: String.slice(picker.query <> text, 0, 120), cursor: 0}}
         ), []},
      else: {state, []}
  end

  defp handle(state, kind, %Picker{} = picker, {:verb, verb})
       when kind in [:picker, :project_picker] and verb in [:backspace, :delete_word, :clear_line] do
    query =
      case verb do
        :backspace -> String.slice(picker.query, 0, max(String.length(picker.query) - 1, 0))
        _ -> ""
      end

    {put(state, {kind, %{picker | query: query, cursor: 0}}), []}
  end

  defp handle(state, kind, %Picker{} = picker, {:verb, verb})
       when kind in [:picker, :project_picker] and verb in [:enter, :commit] do
    case Enum.at(Picker.visible(picker), picker.cursor) do
      nil -> {state, []}
      option -> pick(elem(close(state), 0), picker, option.value)
    end
  end

  defp handle(state, kind, _picker, {:verb, verb})
       when kind in [:picker, :project_picker] and verb in [:escape, :back, :close, :interrupt],
       do: close(state)

  defp handle(state, kind, _picker, _event) when kind in [:picker, :project_picker],
    do: {state, []}

  # ------------------------------------------------------------ pending

  defp handle(state, :pending, body, event) do
    cond do
      letter?(event, "s") ->
        state |> close() |> elem(0) |> Ops.run(Map.get(body, :save, []) ++ body.then)

      letter?(event, "d") ->
        state |> close() |> elem(0) |> Ops.run(Map.get(body, :discard, []) ++ body.then)

      event in [{:verb, :escape}, {:verb, :back}, {:verb, :close}] ->
        close(state)

      true ->
        {state, []}
    end
  end

  defp handle(state, _kind, _body, {:verb, verb}) when verb in [:escape, :back, :close],
    do: close(state)

  defp handle(state, _kind, _body, _event), do: {state, []}

  # ------------------------------------------------------------ helpers

  @doc "Whether the destructive button of `confirm` can be pressed."
  @spec enabled?(Confirm.t()) :: boolean()
  def enabled?(%Confirm{counting?: true}), do: false
  def enabled?(%Confirm{typed: nil}), do: true
  def enabled?(%Confirm{typed: typed, input: input}), do: String.trim(input) == typed

  defp press(state, %{then: ops}) do
    {state, _} = close(state)
    Ops.run(state, ops)
  end

  defp pick(state, %Picker{on_pick: {:patch, key}}, value) when is_binary(key),
    do: Commit.patch(state, key, value, reason: :edit)

  defp pick(state, %Picker{on_pick: {:project, :page}}, value) do
    {state, effects} = Ops.run(state, [{:project, value}])
    {state, more} = SwarmCodeCLI.UI.Reducer.Settings.Responses.reload(state)
    {state, effects ++ more}
  end

  defp pick(%{settings: layer} = state, %Picker{on_pick: {:section, section, tag}}, value),
    do:
      Ops.run(state, Sections.picked(section || Layer.section(layer), Nav.ctx(state), tag, value))

  defp pick(state, %Picker{on_pick: {:commit, %Row{} = row}}, value),
    do: Edit.commit(state, row, value)

  defp pick(state, %Picker{on_pick: {:ops, ops}}, value) when is_list(ops),
    do: Ops.run(state, Enum.map(ops, &put_value(&1, value)))

  defp pick(state, %Picker{} = picker, value) do
    row = %Row{id: "picker:#{picker.id}", kind: :field, target: picker.opener}
    Edit.commit(state, row, value)
  end

  defp put_value(:value, value), do: value

  defp put_value(term, value) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.map(&put_value(&1, value)) |> List.to_tuple()

  defp put_value(term, _value), do: term

  defp letter?({:text, text}, letter), do: text == letter
  defp letter?({:raw, {code, []}}, letter), do: code == letter

  defp letter?({:verb, verb}, letter),
    do: Ops.key_label(verb) == letter

  defp letter?(_event, _letter), do: false

  defp clamp(_cursor, 0), do: 0
  defp clamp(cursor, count), do: cursor |> max(0) |> min(count - 1)

  defp put(%{settings: layer} = state, popover),
    do: %{state | settings: %{layer | popover: popover}}

  @doc "Closes the popover; the page's cursor is where it was (the opener)."
  @spec close(map()) :: {map(), list()}
  def close(%{settings: %Layer{} = layer} = state),
    do: {%{state | settings: %{layer | popover: nil}}, []}

  def close(state), do: {state, []}
end
