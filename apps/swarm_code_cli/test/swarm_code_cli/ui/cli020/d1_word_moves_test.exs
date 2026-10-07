defmodule SwarmCodeCLI.UI.Cli020.D1WordMovesTest do
  @moduledoc """
  cli020 D1 (tui-code-3): word movement in the composer. macOS Option-arrows
  arrive as `ESC b` / `ESC f` (the port decodes them as the letters with Alt),
  Ctrl-arrows as `CSI 1;5 D/C`, and Option-Delete-forward as `ESC d`.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers

  alias SwarmCodeCLI.UI.{Drafts, Editor, Input, Keymap}

  defp cursor(state), do: Editor.cursor(Drafts.fetch(state.drafts, key()).editor)
  defp alt(text), do: Input.text_fragment(:press, text, [:alt])

  defp typed, do: ready() |> paste("one two three")

  test "Alt-b (ESC b) moves a word left and Alt-f (ESC f) a word right" do
    state = typed()
    assert {:ok, {:editor, _, {:move, :word_left}}} = Keymap.resolve(alt("b"), state, %{})
    left = press!(state, alt("b"))
    assert cursor(left) < cursor(state)
    assert text(left) == "one two three"

    right = left |> press!(alt("b")) |> press!(alt("f"))
    assert {:ok, {:editor, _, {:move, :word_right}}} = Keymap.resolve(alt("f"), left, %{})
    assert cursor(right) > cursor(press!(left, alt("b")))
    assert text(right) == "one two three"
  end

  test "Ctrl-Left and Ctrl-Right move by words" do
    state = typed()

    assert {:ok, {:editor, _, {:move, :word_left}}} =
             Keymap.resolve(Input.key(:left, [:control]), state, %{})

    assert {:ok, {:editor, _, {:move, :word_right}}} =
             Keymap.resolve(Input.key(:right, [:control]), state, %{})

    assert cursor(press!(state, Input.key(:left, [:control]))) < cursor(state)
  end

  test "Alt-Left and Alt-Right still move by words" do
    state = typed()

    assert {:ok, {:editor, _, {:move, :word_left}}} =
             Keymap.resolve(Input.key(:left, [:alt]), state, %{})

    assert {:ok, {:editor, _, {:move, :word_right}}} =
             Keymap.resolve(Input.key(:right, [:alt]), state, %{})
  end

  test "Alt-d (ESC d) deletes the word after the cursor" do
    state = typed() |> press!(Input.key(:home)) |> press!(Input.key(:home, [:control]))
    assert {:ok, {:editor, _, :delete_word_forward}} = Keymap.resolve(alt("d"), state, %{})
    after_delete = press!(state, alt("d"))
    assert String.length(text(after_delete)) < String.length("one two three")
  end

  test "the bindings table documents the word moves in the edit group" do
    rows = SwarmCodeCLI.UI.Keymap.Bindings.all()
    left = Enum.find(rows, &(&1.id == :composer_word_left))
    right = Enum.find(rows, &(&1.id == :composer_word_right))
    assert left.group == :edit and right.group == :edit
    assert {"b", [:alt]} in left.keys and {:left, [:control]} in left.keys
    assert {"f", [:alt]} in right.keys and {:right, [:control]} in right.keys
    assert left.help == "Word left/right (Option-←/→, Ctrl-←/→, Alt-b/f)"
  end
end
