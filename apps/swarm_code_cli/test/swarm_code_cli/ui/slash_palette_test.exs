defmodule SwarmCodeCLI.UI.SlashPaletteTest do
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{
    Action,
    Capabilities,
    Drafts,
    Editor,
    Input,
    Keymap,
    Reducer,
    SafeText,
    Size,
    SlashPalette,
    State,
    Width
  }

  alias SwarmCodeCLI.UI.Projector.Composer
  alias SwarmCodeCLI.UI.Scene.{Block, Rect}

  defp state(text) do
    size = %Size{columns: 70, rows: 30}

    state = %State{
      size: size,
      capabilities: %Capabilities{size: size},
      destination: {:conversation, "c"},
      focus: "composer"
    }

    {:ok, editor} = Editor.apply(Editor.new(), {:paste, text})
    draft = Drafts.fetch(state.drafts, {"c", :main})
    %{state | drafts: Drafts.put(state.drafts, %{draft | editor: editor})}
  end

  test "palette exposes every builtin with description and follows registry ranking" do
    entries = SlashPalette.entries(state("/"))
    assert length(entries) == 19
    assert Enum.all?(entries, &(is_binary(&1.desc) and &1.desc != ""))
    assert Enum.map(SlashPalette.entries(state("/research")), & &1.name) == ["deep_research"]
    assert SlashPalette.entries(state("/ese")) == []
  end

  test "palette only opens for a focused command token at the end of an unselected draft" do
    for text <- ["hello /sw", "/swarm task", "/swarm\n", " /sw", "/not-known"] do
      assert SlashPalette.entries(state(text)) == []
    end

    original = state("/sw")
    assert SlashPalette.entries(%{original | layers: [:help]}) == []
    assert SlashPalette.entries(%{original | focus: "main"}) == []
    {moved, _} = Reducer.update(original, {:editor, {"c", :main}, {:move, :left}})
    assert SlashPalette.entries(moved) == []
  end

  test "up down wrap selection and Tab accepts without executing" do
    original = state("/")
    assert {:ok, {:move, :next}} = Keymap.resolve(Input.key(:down), original, %{})
    {selected, []} = Reducer.update(original, {:move, :next})
    assert SlashPalette.selected(selected).name == "goal"
    assert {:ok, {:complete_command, "goal"}} = Keymap.resolve(Input.key(:tab), selected, %{})
    {completed, effects} = Reducer.update(selected, {:complete_command, "goal"})
    assert Enum.all?(effects, &match?({:cancel_timer, _}, &1))
    assert Editor.text(Drafts.fetch(completed.drafts, {"c", :main}).editor) == "/goal "
    assert SlashPalette.entries(completed) == []
    assert completed.focus == "composer"
    {undone, _} = Reducer.update(completed, {:editor, {"c", :main}, :undo})
    assert Editor.text(Drafts.fetch(undone.drafts, {"c", :main}).editor) == "/"
    {last, []} = Reducer.update(original, {:move, :previous})
    assert SlashPalette.selected(last).name == "compact"
  end

  test "completion validates registry membership and current matching token" do
    assert {:error, :invalid_action} = Action.validate({:complete_command, "not-a-command"})
    assert {:error, :invalid_action} = Action.validate({:complete_command, <<255>>})
    original = state("/sw")
    assert {^original, []} = Reducer.update(original, {:complete_command, "goal"})
    {completed, _} = Reducer.update(original, {:complete_command, "swarm"})
    assert Editor.text(Drafts.fetch(completed.drafts, {"c", :main}).editor) == "/swarm "
    assert {:ok, {:focus_cycle, :next}} = Keymap.resolve(Input.key(:tab), completed, %{})
  end

  test "selection resets for changed query and completion changes only current draft" do
    original = state("/")
    other = Drafts.fetch(original.drafts, {"other", :main})
    {:ok, editor} = Editor.apply(other.editor, {:paste, "keep me"})
    original = %{original | drafts: Drafts.put(original.drafts, %{other | editor: editor})}
    {selected, []} = Reducer.update(original, {:move, :next})
    {typed, _} = Reducer.update(selected, {:editor, {"c", :main}, {:insert, "sw"}})
    assert SlashPalette.selected(typed).name == "swarm"
    {completed, _} = Reducer.update(typed, {:complete_command, "swarm"})
    assert Editor.text(Drafts.fetch(completed.drafts, {"other", :main}).editor) == "keep me"
  end

  test "Enter keeps literal slash command in authorized dispatch and release is inert" do
    original = state("/sw")
    intent = {:dispatch, :send, "/sw", :main, []}

    assert {:ok, {:invoke, ^intent, _}} =
             Keymap.resolve(Input.key(:enter), original, %{"send" => {:intent, intent}})

    assert :ignore = Keymap.resolve(Input.key(:release, :tab, []), original, %{})
    modal = %{original | layers: [:help]}
    assert {:ok, {:focus_cycle, :next}} = Keymap.resolve(Input.key(:tab), modal, %{})
  end

  test "neutral palette projection fits narrow regions while preserving editor cursor" do
    for width <- [20, 40, 70, 100], height <- [1, 2, 3, 5] do
      original = state("/sw")
      rect = %Rect{x: 2, y: 4, width: width, height: height}
      {blocks, cursor} = Composer.project(original, rect)
      # The draft is a card row: the rail and two cells, then the text.
      assert %Block.RichText{spans: spans} = hd(blocks)
      assert Enum.map_join(spans, &SafeText.value(&1.text)) =~ "/sw"
      # +3 accounts for the rail and the two cells after it
      assert cursor.x == 8 and cursor.y == 4
      assert length(blocks) <= height

      for %Block.RichText{spans: spans} <- blocks do
        cells = Enum.reduce(spans, 0, &(Width.cells(SafeText.value(&1.text), :narrow) + &2))
        assert cells <= width
      end
    end
  end
end
