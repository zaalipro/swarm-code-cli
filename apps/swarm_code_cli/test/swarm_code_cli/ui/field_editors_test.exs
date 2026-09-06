defmodule SwarmCodeCLI.UI.FieldEditorsTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.UI.{Editor, FieldEditors}

  test "fields preserve exact text, selections and undo independently" do
    key = {:layer_query, "layer", :switcher}
    fields = FieldEditors.new()
    {:ok, editor} = Editor.apply(FieldEditors.fetch(fields, key), {:paste, "find me"})
    {:ok, editor} = Editor.apply(editor, {:extend_selection, :left})
    fields = FieldEditors.put(fields, key, editor)
    assert FieldEditors.fetch(fields, key) == editor
    assert Editor.text(FieldEditors.fetch(fields, {:region_filter, "main"})) == ""
    {:ok, undone} = Editor.apply(FieldEditors.fetch(fields, key), :undo)
    assert Editor.text(undone) == ""
  end

  test "field limits cannot be bypassed by supplying a larger editor" do
    key = {:region_filter, "main"}
    fields = FieldEditors.new()

    assert {:error, :text_too_large} =
             Editor.apply(
               FieldEditors.fetch(fields, key),
               {:paste, String.duplicate("x", 16_385)}
             )

    {:ok, large} = Editor.apply(Editor.new(), {:paste, String.duplicate("x", 16_385)})
    assert_raise ArgumentError, fn -> FieldEditors.put(fields, key, large) end
  end

  test "closing one owner preserves other fields and whitespace remains guarded" do
    fields = FieldEditors.new()
    a = {:layer_query, "a", :switcher}
    b = {:question_other, "b", 7}
    {:ok, whitespace} = Editor.apply(FieldEditors.fetch(fields, a), {:paste, " "})
    {:ok, answer} = Editor.apply(FieldEditors.fetch(fields, b), {:paste, "answer canary"})
    fields = fields |> FieldEditors.put(a, whitespace) |> FieldEditors.put(b, answer)
    assert FieldEditors.dirty?(fields)
    closed = FieldEditors.close_owner(fields, "a")
    assert Editor.text(FieldEditors.fetch(closed, a)) == ""
    assert FieldEditors.fetch(closed, b) == answer
    refute closed |> FieldEditors.close_owner("b") |> FieldEditors.dirty?()
    refute inspect(fields) =~ "canary"
    assert_raise ArgumentError, fn -> FieldEditors.fetch(fields, {"conversation", :main}) end
  end
end
