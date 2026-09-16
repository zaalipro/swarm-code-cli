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

  defp at(text, index, opts \\ []) do
    editor = edit(filled(text, opts), {:move, :buffer_start})
    Enum.reduce(1..index//1, editor, fn _, acc -> edit(acc, {:move, :right}) end)
  end

  defp records(editor), do: length(editor.undo)

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

  test "word end and first nonblank resolve at line boundaries, blank lines and the buffer end" do
    for {from, target} <- [{0, 4}, {3, 4}, {4, 7}, {7, 12}, {10, 12}, {11, 12}, {12, 12}] do
      assert Editor.cursor(edit(at("abcd ef\n  gh", from), {:move, :word_end})) == target
    end

    for {from, target} <- [{0, 0}, {5, 0}, {7, 0}, {8, 10}, {10, 10}, {12, 10}] do
      assert Editor.cursor(edit(at("abcd ef\n  gh", from), {:move, :first_nonblank})) == target
    end

    # Only blanks ahead clamps to the buffer end, as forward word motion does.
    assert Editor.cursor(edit(at("abc   ", 3), {:move, :word_end})) == 6
    assert Editor.cursor(edit(at("ab", 2), {:move, :word_end})) == 2
    # `^` on a blank line is its end; on an empty line it is the line itself.
    assert Editor.cursor(edit(at("x\n   \ny", 4), {:move, :first_nonblank})) == 5
    assert Editor.cursor(edit(at("x\n\ny", 2), {:move, :first_nonblank})) == 2
    # Multi-codepoint graphemes and CJK are single logical steps.
    assert Editor.cursor(edit(at("👩🏽‍🚒界 ab", 0), {:move, :word_end})) == 1
    assert Editor.cursor(edit(at("界界 ab", 0), {:move, :word_end})) == 2
    assert Editor.selection(edit(at("abcd ef", 0), {:extend_selection, :word_end})) == {0, 4}
    assert Editor.selection(edit(at("  abc", 5), {:extend_selection, :first_nonblank})) == {2, 5}
  end

  test "motion deletes take the whole span in one record and fill the unnamed register" do
    for {span, from, text, register, cursor} <- [
          {:word_right, 0, "two three", "one ", 0},
          {:word_end, 0, " two three", "one", 0},
          {:word_left, 7, "one  three", "two", 4},
          {:line_start, 4, "two three", "one ", 0},
          {:right, 0, "ne two three", "o", 0},
          {:left, 1, "ne two three", "o", 0}
        ] do
      before = at("one two three", from)
      deleted = edit(before, {:delete, span})
      assert Editor.text(deleted) == text
      assert Editor.register(deleted) == {register, :charwise}
      assert Editor.cursor(deleted) == cursor
      assert records(deleted) == records(before) + 1
      assert Editor.text(edit(deleted, :undo)) == "one two three"
    end

    ends = edit(at("one two\nx", 3), {:delete, :line_end})
    assert Editor.text(ends) == "one\nx"
    assert Editor.register(ends) == {" two", :charwise}
    assert Editor.text(edit(at("   one", 5), {:delete, :first_nonblank})) == "   e"
    # A span that covers nothing changes neither the text nor the register.
    for span <- [:line_end, :word_right, :word_end, :right, :buffer_end] do
      assert edit(at("abc", 3), {:delete, span}) == at("abc", 3)
    end
  end

  test "line delete takes the line and its newline on first, middle, last and only lines" do
    for {from, text, register, cursor} <- [
          {0, "b\nc", "a\n", 0},
          {2, "a\nc", "b\n", 2},
          {4, "a\nb", "c\n", 2}
        ] do
      deleted = edit(at("a\nb\nc", from), {:delete, :line})
      assert Editor.text(deleted) == text
      assert Editor.register(deleted) == {register, :linewise}
      assert Editor.cursor(deleted) == cursor
      assert Editor.text(edit(deleted, :undo)) == "a\nb\nc"
    end

    only = edit(at("abc", 1), {:delete, :line})
    assert Editor.text(only) == ""
    assert Editor.register(only) == {"abc\n", :linewise}
    assert Editor.cursor(only) == 0
    assert Editor.text(edit(only, :undo)) == "abc"
    assert Editor.text(edit(at("abc\n", 0), {:delete, :line})) == ""
    # An empty buffer has no line to take and leaves the register alone.
    assert edit(Editor.new(), {:delete, :line}) == Editor.new()
    # A linewise register is newline-normalised; the splice keeps exact bytes.
    crlf = edit(at("a\r\nb", 0), {:delete, :line})
    assert Editor.text(crlf) == "b"
    assert Editor.register(crlf) == {"a\n", :linewise}
    assert Editor.text(edit(crlf, :undo)) == "a\r\nb"
  end

  test "a span delete undoes to the exact text, caret and selection and redoes forward" do
    editor =
      at("界é👩‍💻 tail", 0)
      |> edit({:extend_selection, :right})
      |> edit({:extend_selection, :right})

    assert Editor.selection(editor) == {0, 2}
    deleted = edit(editor, {:delete, :selection})
    assert Editor.text(deleted) == "👩‍💻 tail"
    assert Editor.register(deleted) == {"界é", :charwise}
    restored = edit(deleted, :undo)
    assert Editor.text(restored) == "界é👩‍💻 tail"
    assert Editor.cursor(restored) == 2
    assert Editor.selection(restored) == {0, 2}
    assert Editor.text(edit(restored, :redo)) == "👩‍💻 tail"
    # Removing one flag pair must not resegment the untouched neighbour.
    flags = edit(at("🇬🇪🇺🇸", 0), {:delete, :right})
    assert Editor.text(flags) == "🇺🇸"
    assert Editor.text(edit(flags, :undo)) == "🇬🇪🇺🇸"
    zwj = edit(at("👩‍💻界", 0), {:delete, :line})
    assert Editor.text(zwj) == ""
    assert Editor.text(edit(zwj, :undo)) == "👩‍💻界"
  end

  test "yank fills the register without editing and put places charwise and linewise text" do
    before = at("one two", 0)
    charwise = edit(before, {:yank, :word_right})
    assert Editor.text(charwise) == "one two"
    assert Editor.register(charwise) == {"one ", :charwise}
    assert records(charwise) == records(before)
    # `p` goes after the caret's grapheme, `P` onto it; both stay in the line.
    assert Editor.text(edit(charwise, :put_after)) == "oone ne two"
    assert Editor.text(edit(charwise, :put_before)) == "one one two"
    assert Editor.cursor(edit(charwise, :put_before)) == 3
    assert Editor.text(edit(at("ab", 2), {:yank, :left}) |> edit(:put_after)) == "abb"

    linewise = edit(at("a\nb", 0), {:yank, :line})
    assert Editor.register(linewise) == {"a\n", :linewise}
    assert Editor.text(edit(linewise, :put_after)) == "a\na\nb"
    assert Editor.cursor(edit(linewise, :put_after)) == 2
    assert Editor.text(edit(linewise, :put_before)) == "a\na\nb"
    assert Editor.cursor(edit(linewise, :put_before)) == 0
    # A last line without a newline of its own borrows one for the new block.
    assert Editor.text(edit(at("a\nb", 2), {:yank, :line}) |> edit(:put_after)) == "a\nb\nb"
    # An empty register is a no-op both ways.
    assert edit(filled("abc"), :put_after) == filled("abc")
    assert edit(filled("abc"), :put_before) == filled("abc")
    # A yank collapses to the start of its span; `yy` holds the caret.
    assert Editor.cursor(edit(at("one two", 7), {:yank, :word_left})) == 4
    assert Editor.cursor(edit(at("one two", 5), {:yank, :line})) == 5
    # Putting a multi-codepoint grapheme keeps it whole.
    emoji = at("👩‍💻界", 0) |> edit({:yank, :right}) |> edit({:move, :buffer_end})
    assert Editor.text(edit(emoji, :put_after)) == "👩‍💻界👩‍💻"
  end

  test "selection spans need a selection and motion spans absorb the one that is open" do
    plain = at("one two three", 0)
    assert edit(plain, {:delete, :selection}) == plain
    assert edit(plain, {:yank, :selection}) == plain
    assert Editor.register(edit(plain, {:yank, :selection})) == nil

    selected =
      plain
      |> edit({:move, :right})
      |> edit({:extend_selection, :right})
      |> edit({:extend_selection, :right})

    assert Editor.selection(selected) == {1, 3}
    yanked = edit(selected, {:yank, :selection})
    assert Editor.text(yanked) == "one two three"
    assert Editor.register(yanked) == {"ne", :charwise}
    assert Editor.selection(yanked) == nil
    assert Editor.cursor(yanked) == 1

    deleted = edit(selected, {:delete, :selection})
    assert Editor.text(deleted) == "o two three"
    assert Editor.register(deleted) == {"ne", :charwise}
    assert records(deleted) == records(selected) + 1

    # A motion span is the open selection extended by that motion.
    extended = edit(selected, {:delete, :word_right})
    assert Editor.text(extended) == "otwo three"
    assert Editor.register(extended) == {"ne ", :charwise}
    assert Editor.selection(extended) == nil
    assert Editor.text(edit(extended, :undo)) == "one two three"
  end

  test "a counted operation folds into one record and repeats history operations" do
    base = at("one two three", 0)
    moved = edit(base, {:times, 3, {:move, :right}})
    assert Editor.cursor(moved) == 3
    assert records(moved) == records(base)
    assert moved.redo == base.redo
    assert Editor.text(edit(moved, :undo)) == ""

    deleted = edit(base, {:times, 2, {:delete, :word_right}})
    assert Editor.text(deleted) == "three"
    assert records(deleted) == records(base) + 1
    # The register grows in document order, so a put restores what was taken.
    assert Editor.register(deleted) == {"one two ", :charwise}
    assert Editor.text(edit(deleted, :undo)) == "one two three"
    assert Editor.text(deleted |> edit(:undo) |> edit(:redo)) == "three"

    backward = edit(at("one two three", 7), {:times, 2, {:delete, :word_left}})
    assert Editor.text(backward) == " three"
    assert Editor.register(backward) == {"one two", :charwise}

    lines = edit(at("a\nb\nc", 0), {:times, 3, {:delete, :line}})
    assert Editor.text(lines) == ""
    assert Editor.register(lines) == {"a\nb\nc\n", :linewise}
    assert records(lines) == records(at("a\nb\nc", 0)) + 1
    assert Editor.text(edit(lines, :undo)) == "a\nb\nc"
    last = edit(at("a\nb\nc", 4), {:times, 2, {:delete, :line}})
    assert Editor.text(last) == "a"
    assert Editor.register(last) == {"b\nc\n", :linewise}
    # A repeated put stays contiguous because the caret ends on the last one.
    assert Editor.text(edit(at("xy", 0), {:yank, :right}) |> edit({:times, 2, :put_after})) ==
             "xxxy"

    # A repeat is atomic: a step that cannot fit rejects the whole fold.
    tight = at("abcd", 4, max_bytes: 6)
    assert {:error, :text_too_large} = Editor.apply(tight, {:times, 3, {:insert, "z"}})
    assert Editor.text(edit(tight, {:times, 2, {:insert, "z"}})) == "abcdzz"
    assert records(edit(tight, {:times, 2, {:insert, "z"}})) == records(tight) + 1

    # Counted history operations walk the stacks instead of folding a record.
    typed = Enum.reduce(["a", "b", "c"], Editor.new(), &edit(&2, {:paste, &1}))
    assert Editor.text(edit(typed, {:times, 2, :undo})) == "a"
    assert Editor.text(typed |> edit({:times, 2, :undo}) |> edit({:times, 2, :redo})) == "abc"

    # One folded record over the byte budget is evicted whole, as a group is.
    evicted = edit(at("abcdef", 0, undo_bytes: 3), {:times, 4, {:delete, :right}})
    assert Editor.text(evicted) == "ef"
    assert evicted.undo == []
    assert Editor.text(edit(evicted, :undo)) == "ef"
  end

  test "the register survives unrelated edits and a put that will not fit is rejected" do
    yanked = edit(at("one two", 0), {:yank, :word_right})

    typed =
      yanked
      |> edit({:insert, "Z"})
      |> edit(:delete_backward)
      |> edit({:paste, "tail"})
      |> edit(:undo)

    assert Editor.text(typed) == "one two"
    assert Editor.register(typed) == {"one ", :charwise}
    assert Editor.text(edit(typed, :put_before)) == "one one two"

    # Insert-mode deletions leave the register alone; span deletes fill it.
    assert Editor.register(edit(yanked, :delete_forward)) == {"one ", :charwise}
    assert Editor.register(edit(yanked, :delete_word_forward)) == {"one ", :charwise}
    assert Editor.register(edit(yanked, {:delete, :right})) == {"o", :charwise}

    # A put is bounded by max_bytes and reports the oversize-insert error.
    full = edit(at("abcdef", 0, max_bytes: 12), {:yank, :line})
    assert Editor.register(full) == {"abcdef\n", :linewise}
    assert {:error, :fragment_too_large} = Editor.apply(full, :put_after)
    assert {:error, :fragment_too_large} = Editor.apply(full, :put_before)

    assert Editor.text(edit(at("abcdef", 0, max_bytes: 13), {:yank, :line}) |> edit(:put_before)) ==
             "abcdef\nabcdef"

    # A register wider than one insert fragment is not an oversize fragment.
    big = edit(filled(String.duplicate("a", 5000)), {:yank, :line})
    assert Editor.text_bytes(edit(big, :put_before)) == 10_001
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
    held = filled("secret-token") |> edit({:yank, :line}) |> edit(:select_all)
    assert Editor.register(held) == {"secret-token\n", :linewise}
    refute inspect(held) =~ "secret"
    refute inspect(Editor.reset(held)) =~ "secret"
    assert Editor.register(Editor.reset(held)) == nil
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
          :put_after,
          :put_before,
          {:move, :left},
          {:move, :right},
          {:move, :word_end},
          {:move, :first_nonblank},
          {:extend_selection, :left},
          {:extend_selection, :right},
          {:delete, :line},
          {:delete, :word_right},
          {:delete, :selection},
          {:yank, :line},
          {:yank, :selection},
          {:times, 2, {:move, :right}},
          {:times, 2, {:delete, :left}}
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
