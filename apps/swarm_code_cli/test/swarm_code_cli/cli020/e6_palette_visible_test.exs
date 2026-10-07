defmodule SwarmCodeCLI.Cli020.E6PaletteVisibleTest do
  # cli020 E6 (ux-live-1): the palette's scroll offset is clamped so the
  # selected entry is inside the window; offset 0 when the selection is 0,
  # whatever offset an earlier dialog left behind.
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.Demo.Conversation
  alias SwarmCodeCLI.UI.{Capabilities, Editor, FieldEditors, Layout, Size, Switcher}
  alias SwarmCodeCLI.UI.Projector.Dialog

  defp palette(focus, scroll) do
    size = %Size{columns: 120, rows: 24}
    state = Conversation.state(:first_reply, size, %Capabilities{size: size})
    layer = {:switcher, "palette"}

    %{
      state
      | layers: [layer],
        focus: focus,
        selection: Map.put(state.selection, "dialog_scroll", scroll),
        field_editors:
          FieldEditors.put(
            state.field_editors,
            Switcher.field_key(layer),
            Editor.new(max_bytes: 16_384)
          )
    }
  end

  defp dialog(state), do: Dialog.project(state, Layout.classify(state.size))

  defp ids(dialog),
    do: for(block <- dialog.blocks, do: block)

  test "a fresh palette (focus in the query) shows its first entry, whatever the old offset" do
    for scroll <- [0, 5, 15, 40] do
      d = palette("query", scroll) |> dialog()
      assert d.body_total_count >= 24
      assert d.body_scroll == 0, "offset #{scroll} kept: #{inspect(d.body_visible_range)}"
    end
  end

  test "selection 0 and the last entry are inside the window" do
    state = palette("dialog", 30)
    entries = Switcher.visible(state, %{})
    assert length(entries) >= 24

    first = hd(entries).id
    d = %{state | focus: first} |> dialog()
    {from, _to} = d.body_visible_range
    assert from == 0

    last = List.last(entries).id

    d =
      %{state | focus: last, selection: Map.put(state.selection, "dialog_scroll", 0)} |> dialog()

    {_from, to} = d.body_visible_range
    assert to == d.body_total_count
    assert ids(d) != []
  end
end
