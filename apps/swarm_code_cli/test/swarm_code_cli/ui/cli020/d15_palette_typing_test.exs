defmodule SwarmCodeCLI.UI.Cli020.D15PaletteTypingTest do
  @moduledoc """
  cli020 D15 (ux-live-1): while the palette (or a picker with a query) is on
  top, text and Backspace always edit its query, whatever row has focus, and
  Up on the first row stays there.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers

  alias SwarmCodeCLI.UI.{FieldEditors, Editor, Input, Keymap, Reducer, Switcher}

  defp palette do
    state = ready()
    layer = Switcher.open(state, state.focus)
    {state, _} = Reducer.update(state, {:open_layer, layer})
    {state, layer}
  end

  defp query(state, layer),
    do: Editor.text(FieldEditors.fetch(state.field_editors, Switcher.field_key(layer)))

  defp key!(state, input) do
    case Keymap.resolve(input, state, %{}) do
      {:ok, action} -> elem(Reducer.update(state, action), 0)
      :ignore -> state
    end
  end

  test "typing edits the query with the focus on any row, Cancel included" do
    {state, layer} = palette()
    state = key!(state, Input.text_fragment(:press, "n", []))
    assert query(state, layer) == "n"

    for focus <- ["cancel", "confirm"] do
      moved = %{state | focus: focus}
      typed = key!(moved, Input.text_fragment(:press, "e", []))
      assert query(typed, layer) == "ne", "typing on #{focus} was lost"
      erased = key!(typed, Input.key(:backspace))
      assert query(erased, layer) == "n"
    end
  end

  test "Up on the first row stays on the first row" do
    {state, _layer} = palette()
    [first | _] = Switcher.visible(state)
    state = %{state | focus: first.id}
    state = key!(state, Input.key(:up))
    assert state.focus == first.id
  end
end
