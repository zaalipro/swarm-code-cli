defmodule SwarmCodeCLI.UI.EditorTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SwarmCodeCLI.UI.Editor
  alias SwarmCodeCLI.UI.Editor.Operation

  defp edit(editor, op) do
    assert {:ok, updated} = Editor.apply(editor, op)
    updated
  end

  defp filled(text, opts \\ []), do: edit(Editor.new(opts), {:paste, text})

  test "fragmented accents, modifiers, flags and ZWJ retain exact bytes and graphemes" do
    for text <- ["é", "👩🏽‍🚒", "🇬🇪🇺🇸🇫", "👨‍👩‍👧‍👦", "❤︎❤️", "ქართული", "العربية", "עברית", "界"] do
      editor = Enum.reduce(String.codepoints(text), Editor.new(), &edit(&2, {:insert, &1}))
      assert Editor.text(editor) == text
      assert Editor.cursor(editor) == String.length(text)
      assert Editor.selection(editor) == nil
      assert Editor.text(edit(editor, :undo)) == ""
      assert Editor.text(editor |> edit(:undo) |> edit(:redo)) == text
    end
  end

  test "inserting and deleting at joins resegments both neighbors including flag parity" do
    editor = filled("🇬🇪🇺🇸🇫🇷") |> edit({:move, :buffer_start}) |> edit({:insert, "🇦"})
    assert Editor.text(editor) == "🇦🇬🇪🇺🇸🇫🇷"
    assert Editor.cursor(editor) == 1
    assert Editor.text(edit(editor, :delete_forward)) == "🇦🇬🇸🇫🇷"
    joined = filled("👩x‍🚒") |> edit({:move, :left}) |> edit(:delete_backward)
    assert Editor.text(joined) == "👩🚒"
    assert Editor.text(edit(editor, :undo)) == "🇬🇪🇺🇸🇫🇷"
  end

  test "selection extends from its anchor, reverses, replaces and restores on undo" do
    editor =
      filled("a界éz")
      |> edit({:move, :left})
      |> edit({:extend_selection, :left})
      |> edit({:extend_selection, :left})

    assert Editor.selection(editor) == {1, 3}
    assert Editor.selected_text(editor) == "界é"
    replaced = edit(editor, {:insert, "👩‍💻"})
    assert Editor.text(replaced) == "a👩‍💻z"
    assert Editor.cursor(replaced) == 2
    restored = edit(replaced, :undo)
    assert Editor.text(restored) == "a界éz"
    assert Editor.selection(restored) == {1, 3}
    assert Editor.cursor(restored) == 1

    assert Editor.selection(
             editor
             |> edit({:extend_selection, :right})
             |> edit({:extend_selection, :right})
           ) == nil

    assert Editor.text(editor |> edit(:select_all) |> edit(:delete_forward)) == ""
  end

  test "word and logical line and buffer motions and deletions clamp at boundaries" do
    editor = filled("one  two\n界 end") |> edit({:move, :buffer_start})
    editor = edit(editor, {:move, :word_right})
    assert Editor.cursor(editor) == 5
    assert Editor.cursor(edit(editor, {:move, :line_end})) == 8
    editor = edit(editor, :delete_word_forward)
    assert Editor.text(editor) == "one  界 end"
    editor = editor |> edit({:move, :buffer_end}) |> edit(:delete_word_backward)
    assert Editor.text(editor) == "one  界 "
    assert Editor.cursor(editor |> edit({:move, :line_start}) |> edit({:move, :left})) == 0

    assert Editor.text(editor |> edit({:move, :buffer_start}) |> edit(:delete_backward)) ==
             "one  界 "
  end

  test "vertical movement retains preferred cells across short lines under explicit policies" do
    for {policy, first_target} <- [narrow: 6, wide: 5] do
      editor = filled("abc\n·界z\nx\nabc", ambiguous_width: policy) |> edit({:move, :buffer_start})
      editor = Enum.reduce(1..3, editor, fn _, e -> edit(e, {:move, :right}) end)
      editor = edit(editor, {:move, :down})
      assert Editor.cursor(editor) == first_target
      editor = edit(editor, {:move, :down})
      assert Editor.cursor(editor) == 9
      editor = edit(editor, {:move, :down})
      assert Editor.cursor(editor) == 13
      assert Editor.cursor(edit(editor, {:move, :up})) == 9
    end
  end

  test "stale undo timers cannot split a newer group, exact timers can" do
    a = edit(Editor.new(), {:insert, "a"})
    old_id = Editor.undo_group_id(a)
    ab = edit(a, {:insert, "b"})
    assert is_binary(old_id)
    refute Editor.undo_group_id(ab) == old_id
    assert edit(ab, {:undo_boundary, old_id}) == ab
    closed = edit(ab, {:undo_boundary, Editor.undo_group_id(ab)})
    assert Editor.undo_group_id(closed) == nil
    abc = edit(closed, {:insert, "c"})
    assert Editor.text(edit(abc, :undo)) == "ab"
    assert Editor.text(abc |> edit(:undo) |> edit(:undo)) == ""
    assert Editor.text(abc |> edit(:undo) |> edit({:insert, "d"}) |> edit(:redo)) == "abd"
  end

  test "paste and newline are atomic undo groups and repeated paste never invokes" do
    editor = Enum.reduce(1..100, Editor.new(), fn _, e -> edit(e, {:paste, "ქართული\n👩🏽‍🚒"}) end)
    assert Editor.cursor(editor) == 900
    assert Editor.text(editor) == String.duplicate("ქართული\n👩🏽‍🚒", 100)
    empty = Enum.reduce(1..100, editor, fn _, e -> edit(e, :undo) end)
    assert Editor.text(empty) == ""
    assert Editor.text(filled("x") |> edit(:newline) |> edit(:undo)) == "x"
  end

  test "byte thresholds reject atomically and selection replacement uses resulting size" do
    editor = filled(String.duplicate("x", 262_144))

    assert {:error, :paste_too_large} =
             Editor.apply(editor, {:paste, String.duplicate("y", 262_145)})

    assert {:error, :text_too_large} = Editor.apply(editor, {:insert, "x"})

    assert {:error, :fragment_too_large} =
             Editor.apply(editor, {:insert, String.duplicate("y", 4097)})

    assert Editor.text(edit(editor, :undo)) == ""
    assert Editor.text(editor |> edit(:select_all) |> edit({:paste, "ok"})) == "ok"
    assert {:error, :text_too_large} = Editor.apply(filled("123", max_bytes: 3), {:paste, "4"})
    assert {:ok, _} = Editor.apply(Editor.new(), {:insert, String.duplicate("a", 4096)})

    for op <- [{:insert, <<255>>}, {:paste, <<255>>}, :copy, :cut, {:composition, "x"}] do
      assert {:error, :invalid_editor_operation} = Editor.apply(Editor.new(), op)
      assert {:error, :invalid_editor_operation} = Operation.validate(op)
    end
  end

  test "undo count and exact inverse byte budget evict history without altering text" do
    editor = Enum.reduce(["a", "b", "c"], Editor.new(undo_count: 2), &edit(&2, {:paste, &1}))
    assert Editor.text(editor |> edit(:undo) |> edit(:undo) |> edit(:undo)) == "a"
    editor = filled("é", undo_bytes: 2) |> edit({:paste, "x"})
    assert Editor.text(editor |> edit(:undo) |> edit(:undo)) == "é"
    editor = filled("é", undo_bytes: 2)
    assert Editor.text(edit(editor, :undo)) == ""
    editor = filled("abc", undo_bytes: 2)
    assert Editor.text(edit(editor, :undo)) == "abc"
  end

  test "viewport stays grapheme aligned around cursor and exposes logical cell edges" do
    editor =
      filled("אב·界\nქართული\n👩🏽‍🚒")
      |> edit({:move, :buffer_start})
      |> edit({:extend_selection, :right})
      |> edit({:extend_selection, :right})
      |> edit({:extend_selection, :right})

    for {policy, cell} <- [narrow: 3, wide: 4] do
      slice = Editor.visible_slice(editor, 80, 8, policy)
      assert slice.cursor_row == 0
      assert slice.cursor_cell == cell
      assert slice.selection_edges == {{0, 0}, {0, cell}}
      assert slice.start == 0
    end

    large = filled(String.duplicate("界", 80_000)) |> edit({:move, :left})
    slice = Editor.visible_slice(large, 80, 8, :narrow)
    assert byte_size(slice.text) <= 8192
    assert String.valid?(slice.text)
    assert slice.start <= Editor.cursor(large)
    assert slice.end >= Editor.cursor(large)

    assert slice.text ==
             large
             |> Editor.text()
             |> String.graphemes()
             |> Enum.slice(slice.start, slice.end - slice.start)
             |> Enum.join()

    assert slice.cursor_cell == 159_998
    giant = filled("a" <> String.duplicate("́", 5000))
    assert byte_size(Editor.visible_slice(giant, 80, 8, :narrow).text) <= 8192
  end

  test "inspection redacts live text and derived history" do
    editor = filled("secret-token") |> edit(:select_all) |> edit({:paste, "replacement-secret"})
    refute inspect(editor) =~ "secret"
    refute inspect(editor.buffer) =~ "secret"
    refute inspect(Editor.visible_slice(editor, 80, 8, :narrow)) =~ "secret"
  end

  test "undoing a local edit does not resegment the untouched buffer" do
    small = filled(String.duplicate("a", 100)) |> edit({:insert, "x"})
    large = filled(String.duplicate("a", 50_000)) |> edit({:insert, "x"})
    edit(small, :undo)
    {small_result, small_work} = measured_undo(small)
    {large_result, large_work} = measured_undo(large)
    assert Editor.text(small_result) == String.duplicate("a", 100)
    assert Editor.text(large_result) == String.duplicate("a", 50_000)
    assert large_work < small_work * 4
  end

  test "vertical motion on long lines scales without measuring every growing prefix" do
    small = filled(String.duplicate("a", 100) <> "\n" <> String.duplicate("a", 100))
    large = filled(String.duplicate("a", 2000) <> "\n" <> String.duplicate("a", 2000))
    {_, small_work} = measured_move_up(small)
    {result, large_work} = measured_move_up(large)
    assert Editor.cursor(result) == 2000
    assert large_work < small_work * 50
  end

  test "vertical movement and caret edges measure contextual RTL ligatures" do
    editor = filled("لا\nx") |> edit({:move, :up})
    assert Editor.cursor(editor) == 2
    assert Editor.visible_slice(editor, 20, 2, :narrow).cursor_cell == 1
    assert Editor.cursor(edit(editor, {:move, :left})) == 1
    assert Editor.visible_slice(edit(editor, {:move, :left}), 20, 2, :narrow).cursor_cell == 1
  end

  test "vertical cell search retains a ligature whose prefix temporarily exceeds the target" do
    editor = filled("\u2D4F\u2D7F\u2D3Ex\nx") |> edit({:move, :up})
    assert Editor.cursor(editor) == 2
    assert Editor.visible_slice(editor, 20, 2, :narrow).cursor_cell == 1
  end

  defp measured_move_up(editor) do
    {:reductions, before} = Process.info(self(), :reductions)
    {:ok, result} = Editor.apply(editor, {:move, :up})
    {:reductions, after_count} = Process.info(self(), :reductions)
    {result, after_count - before}
  end

  defp measured_undo(editor) do
    {:reductions, before} = Process.info(self(), :reductions)
    {:ok, result} = Editor.apply(editor, :undo)
    {:reductions, after_count} = Process.info(self(), :reductions)
    {result, after_count - before}
  end

  test "reset clears private draft state but preserves bounds, policy and boundary identity" do
    editor = Editor.new(max_bytes: 3, undo_bytes: 2, undo_count: 1, ambiguous_width: :wide)
    editor = edit(editor, {:insert, "é"})
    stale = Editor.undo_group_id(editor)
    assert Editor.text_bytes(editor) == 2
    reset = Editor.reset(editor)
    assert Editor.text_bytes(reset) == 0
    assert Editor.text(reset) == ""
    assert Editor.cursor(reset) == 0
    assert Editor.selection(reset) == nil
    assert Editor.text(edit(reset, :undo)) == ""
    assert reset.ambiguous_width == :wide
    assert {:error, :text_too_large} = Editor.apply(reset, {:paste, "1234"})
    fresh = edit(reset, {:insert, "x"})
    refute Editor.undo_group_id(fresh) == stale
    assert edit(fresh, {:undo_boundary, stale}) == fresh
  end

  property "vertical movement reaches the final fitting logical cell boundary" do
    parts =
      member_of([
        "a",
        "界",
        "·",
        "ل",
        "ا",
        "א",
        "ל",
        "\u200D",
        "\u2D4F",
        "\u2D7F",
        "\u2D3E",
        "\u17D2",
        "\u1780",
        "🇬",
        "🇪"
      ])

    check all(
            fragments <- list_of(parts, max_length: 24),
            preferred <- integer(0..12),
            policy <- member_of([:narrow, :wide]),
            max_runs: 120
          ) do
      line = Enum.join(fragments)
      gs = String.graphemes(line)

      expected =
        Enum.filter(0..length(gs), fn index ->
          SwarmCodeCLI.UI.Width.cells(Enum.take(gs, index) |> Enum.join(), policy) <= preferred
        end)
        |> Enum.max()

      editor = filled(line <> "\n" <> String.duplicate("x", preferred), ambiguous_width: policy)
      assert Editor.cursor(edit(editor, {:move, :up})) == expected
    end
  end

  property "bounded operations preserve exact zipper reconstruction and selection bounds" do
    operations =
      one_of([
        map(member_of(["a", "é", "́", "👩", "‍", "🚒", "🇬", "🇪", "\n", "界"]), &{:insert, &1}),
        member_of([
          :delete_backward,
          :delete_forward,
          :undo,
          :redo,
          :select_all,
          {:move, :left},
          {:move, :right},
          {:extend_selection, :left},
          {:extend_selection, :right}
        ])
      ])

    check all(ops <- list_of(operations, max_length: 100), max_runs: 80) do
      Enum.reduce(ops, Editor.new(), fn op, editor ->
        updated = edit(editor, op)
        text = Editor.text(updated)
        graphemes = String.graphemes(text)
        assert Editor.text_bytes(updated) == byte_size(text)
        assert updated.buffer.count == length(graphemes)

        assert updated.buffer.left_bytes ==
                 byte_size(Enum.join(Enum.reverse(updated.buffer.left)))

        assert length(updated.undo) + length(updated.redo) <= updated.undo_count
        assert Enum.sum(Enum.map(updated.undo ++ updated.redo, & &1.bytes)) <= updated.undo_bytes

        assert updated.buffer.left |> Enum.reverse() |> Kernel.++(updated.buffer.right) ==
                 graphemes

        assert Editor.cursor(updated) in 0..length(graphemes)

        case Editor.selection(updated) do
          nil ->
            assert Editor.selected_text(updated) == ""

          {from, to} ->
            assert 0 <= from and from < to and to <= length(graphemes)

            assert Editor.selected_text(updated) ==
                     graphemes |> Enum.slice(from, to - from) |> Enum.join()
        end

        updated
      end)
    end
  end
end
