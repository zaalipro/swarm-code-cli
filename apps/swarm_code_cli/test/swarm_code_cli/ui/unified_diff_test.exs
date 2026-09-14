defmodule SwarmCodeCLI.UI.UnifiedDiffTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.UI.{SafeText, UnifiedDiff}
  alias SwarmCodeCLI.UI.Paint.{Blocks, Options}
  alias SwarmCodeCLI.UI.Scene.Block

  @base %{foreground: nil, background: nil, modifiers: []}

  defp value(safe), do: SafeText.value(safe)

  defp kinds(%Block.Diff{hunks: hunks}),
    do: Enum.flat_map(hunks, fn {_, lines} -> Enum.map(lines, &elem(&1, 0)) end)

  defp texts(%Block.Diff{hunks: hunks}),
    do: Enum.flat_map(hunks, fn {_, lines} -> Enum.map(lines, fn {_, t} -> value(t) end) end)

  @sample """
  diff --git a/lib/foo.ex b/lib/foo.ex
  index 111..222 100644
  --- a/lib/foo.ex
  +++ b/lib/foo.ex
  @@ -1,3 +1,4 @@
   context
  -removed
  +added
  \\ No newline at end of file
  """

  describe "empty and boundary inputs" do
    test "nil yields no files and no note" do
      assert UnifiedDiff.blocks(nil) == {[], nil}
    end

    test "empty and whitespace input reports no textual changes" do
      assert {[], "No textual changes."} = UnifiedDiff.blocks("")
      assert {[], "No textual changes."} = UnifiedDiff.blocks("\n\n")
    end

    test "the daemon's too-large note passes through verbatim" do
      note = UnifiedDiff.too_large_note()
      assert {[], ^note} = UnifiedDiff.blocks(note)
    end

    test "content before any file header is dropped" do
      assert {[], "No textual changes."} =
               UnifiedDiff.blocks("index abc..def\n--- a/x\n+++ b/x\n+orphan")
    end
  end

  describe "parsing" do
    test "classifies every line kind and counts only additions and deletions" do
      assert {[file], nil} = UnifiedDiff.blocks(@sample)
      assert value(file.path) == "lib/foo.ex"
      assert file.added == 1
      assert file.removed == 1
      refute file.truncated?
      assert [{header, _}] = file.hunks
      assert value(header) == "@@ -1,3 +1,4 @@"
      # The trailing newline contributes a final empty context line.
      assert kinds(file) == [:ctx, :del, :add, :meta, :ctx]
    end

    test "header lines before the first hunk are not counted as content" do
      assert {[file], nil} = UnifiedDiff.blocks(@sample)
      refute "+++ b/lib/foo.ex" in texts(file)
      refute "--- a/lib/foo.ex" in texts(file)
      refute "index 111..222 100644" in texts(file)
    end

    test "a hunk header is never mistaken for an addition or deletion" do
      assert {[file], nil} = UnifiedDiff.blocks("diff --git a/f b/f\n@@ -1 +1 @@\n ctx\n")
      assert file.added == 0
      assert file.removed == 0
    end

    test "splits multiple files and keeps their own counts" do
      two =
        @sample <>
          "diff --git a/lib/bar.ex b/lib/bar.ex\n+++ b/lib/bar.ex\n@@ -9,2 +9,2 @@\n-a\n-b\n+c\n"

      assert {[foo, bar], nil} = UnifiedDiff.blocks(two)
      assert value(foo.path) == "lib/foo.ex"
      assert {bar.added, bar.removed} == {1, 2}
      assert value(bar.path) == "lib/bar.ex"
    end

    test "resolves the path for renames and for headers without a b/ segment" do
      assert {[renamed], nil} =
               UnifiedDiff.blocks("diff --git a/old.ex b/new.ex\nrename from old.ex\n")

      assert value(renamed.path) == "new.ex"

      assert {[odd], nil} = UnifiedDiff.blocks("diff --git weird\n@@ -1 +1 @@\n ctx\n")
      assert value(odd.path) == "weird"
    end

    test "multiple hunks in one file are kept in source order" do
      text = "diff --git a/f b/f\n@@ -1 +1 @@\n+one\n@@ -5 +5 @@\n+two\n"
      assert {[file], nil} = UnifiedDiff.blocks(text)
      assert [{first, _}, {second, _}] = file.hunks
      assert value(first) == "@@ -1 +1 @@"
      assert value(second) == "@@ -5 +5 @@"
      assert file.added == 2
    end
  end

  describe "line budget" do
    test "truncates at the budget and marks the file" do
      assert {[file], nil} = UnifiedDiff.blocks(@sample, max_lines: 2)
      assert file.truncated?
      assert length(texts(file)) == 2
    end

    test "a hunk emptied by the cut is dropped rather than shown as a bare header" do
      two = @sample <> "diff --git a/lib/bar.ex b/lib/bar.ex\n@@ -9 +9 @@\n+c\n"
      assert {[only], nil} = UnifiedDiff.blocks(two, max_lines: 3)
      assert value(only.path) == "lib/foo.ex"
    end

    test "a zero budget yields no files" do
      assert {[], "No textual changes."} = UnifiedDiff.blocks(@sample, max_lines: 0)
    end

    test "an untruncated diff never sets the marker" do
      assert {[file], nil} = UnifiedDiff.blocks(@sample, max_lines: 10_000)
      refute file.truncated?
    end
  end

  describe "painting" do
    defp lines(blocks, opts \\ %Options{}, rows \\ 50),
      do: elem(Blocks.lines(blocks, 60, opts, @base, rows), 1)

    defp strings(rendered),
      do: Enum.map(rendered, &Enum.map_join(&1.units, fn unit -> unit.text end))

    test "renders a header, the hunk and each line" do
      {blocks, nil} = UnifiedDiff.blocks(@sample)

      # The trailing empty context line occupies no row once rendered.
      assert strings(lines(blocks)) == [
               "lib/foo.ex  +1  -1",
               "@@ -1,3 +1,4 @@",
               " context",
               "-removed",
               "+added",
               "\\ No newline at end of file"
             ]
    end

    test "additions, deletions, hunks and metadata are visually distinct" do
      {blocks, nil} = UnifiedDiff.blocks(@sample)

      colors =
        blocks
        |> lines()
        |> Enum.map(fn line ->
          line.units |> Enum.map(& &1.style[:foreground]) |> Enum.uniq() |> List.last()
        end)

      [_header, hunk, ctx, del, add, meta | _] = colors
      assert add == {:rgb, 0x3D, 0xDC, 0x5A}
      assert del == {:rgb, 0xFF, 0x4D, 0x4F}
      assert hunk == {:rgb, 0x4D, 0xA3, 0xFF}
      assert meta == {:rgb, 0x8C, 0x8B, 0x88}
      assert ctx == {:rgb, 0xF3, 0xF2, 0xF0}
    end

    test "monochrome keeps every line readable without color" do
      {blocks, nil} = UnifiedDiff.blocks(@sample)
      rendered = lines(blocks, %Options{color_mode: :monochrome})

      assert Enum.all?(rendered, fn line ->
               Enum.all?(line.units, &is_nil(&1.style[:foreground]))
             end)

      # The +/- prefixes survive, so the kinds stay distinguishable.
      assert "+added" in strings(rendered)
      assert "-removed" in strings(rendered)
    end

    test "the elision marker appears only when lines were cut" do
      {cut, nil} = UnifiedDiff.blocks(@sample, max_lines: 2)
      assert List.last(strings(lines(cut))) == "…"

      {whole, nil} = UnifiedDiff.blocks(@sample)
      refute "…" in strings(lines(whole))
    end

    test "ascii mode uses an ascii elision marker" do
      {cut, nil} = UnifiedDiff.blocks(@sample, max_lines: 2)
      assert List.last(strings(lines(cut, %Options{ascii?: true}))) == "..."
    end

    test "the caller's row budget is never exceeded" do
      {blocks, nil} = UnifiedDiff.blocks(@sample)

      for rows <- 0..8 do
        assert length(lines(blocks, %Options{}, rows)) <= rows
      end
    end

    test "a diff with no hunks still renders its header" do
      {blocks, nil} = UnifiedDiff.blocks("diff --git a/old.ex b/new.ex\nrename from old.ex\n")
      assert strings(lines(blocks)) == ["new.ex  +0  -0"]
    end
  end

  describe "scene admission" do
    test "a parsed diff is a valid scene block" do
      {blocks, nil} = UnifiedDiff.blocks(@sample)
      assert :ok = SwarmCodeCLI.UI.Paint.Budget.check_display_list(blocks)
    end

    test "malformed hunks and line kinds are rejected" do
      bad_kind = %Block.Diff{
        path: elem(SafeText.external("f", SafeText.Limits.content()), 1),
        hunks: [{elem(SafeText.external("@@", SafeText.Limits.content()), 1), [{:bogus, "x"}]}]
      }

      assert {:error, _} = Blocks.lines([bad_kind], 60, %Options{}, @base, 10)
    end
  end
end
