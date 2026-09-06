defmodule SwarmCodeCLI.UI.Paint.TextTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.UI.Paint.Text
  alias SwarmCodeCLI.UI.Width
  @plain %{foreground: nil, background: nil, modifiers: []}
  @red %{foreground: {:ansi, :red}, background: nil, modifiers: [:bold]}
  defp run(text, style \\ @plain, action \\ nil),
    do: %{text: text, style: style, action_id: action}

  defp strings(lines), do: Enum.map(lines, fn line -> Enum.map_join(line.units, & &1.text) end)

  test "LF, CRLF across runs, blank lines and final fitting text are retained" do
    assert {:ok, lines} = Text.lines([run("ab\r"), run("\n\ncd\n")], 2, :narrow, 10)
    assert strings(lines) == ["ab", "", "cd", ""]
    assert Enum.map(lines, & &1.cells) == [2, 0, 2, 0]
    assert {:ok, []} = Text.lines([], 4, :narrow, 2)
    assert {:ok, []} = Text.lines([run("")], 4, :narrow, 2)
    assert {:ok, []} = Text.lines([run("a")], 0, :narrow, 2)
    assert {:ok, []} = Text.lines([run("a")], 4, :narrow, 0)
  end

  test "wraps CJK, Georgian, Arabic, combining marks and ambiguous symbols by occupied cells" do
    for {text, width, policy, expected} <- [
          {"界a界", 3, :narrow, ["界a", "界"]},
          {"ქართული", 4, :narrow, ["ქართ", "ული"]},
          {"مرحبا", 3, :narrow, ["مرح", "با"]},
          {"éé", 1, :narrow, ["é", "é"]},
          {"·x", 2, :narrow, ["·x"]},
          {"·x", 2, :wide, ["·", "x"]},
          {"👩‍💻x", 2, :narrow, ["👩‍💻", "x"]}
        ] do
      assert {:ok, lines} = Text.lines([run(text)], width, policy, 10)
      assert strings(lines) == expected

      for line <- lines do
        assert line.cells == Width.cells(Enum.map_join(line.units, & &1.text), policy)
        assert line.cells == Enum.sum(Enum.map(line.units, & &1.width))
        assert line.cells <= width
      end
    end
  end

  test "a grapheme crossing spans belongs to its first contributor" do
    assert {:ok, [line]} =
             Text.lines(
               [run("e", @red, "a"), run("́👩", @plain, "b"), run("‍💻", @red, "c")],
               3,
               :narrow,
               1
             )

    assert line.units == [
             %{text: "é", width: 1, style: @red, action_id: "a"},
             %{text: "👩‍💻", width: 2, style: @plain, action_id: "b"}
           ]
  end

  test "Arabic lam alef combines across styles without losing exact-edge suffix" do
    assert {:ok, lines} = Text.lines([run("ل", @red, "a"), run("اx", @plain, "b")], 1, :narrow, 2)
    assert strings(lines) == ["لا", "x"]
    assert hd(lines).units == [%{text: "لا", width: 1, style: @red, action_id: "a"}]
    assert Enum.map(lines, & &1.cells) == [1, 1]
  end

  test "contextual glyphs that initially exceed the edge still fit when complete" do
    for text <- ["ⴱ⵿ⴲ", "א‍ל", "ᨕᨗ‍ᨐ", "ꓹꓼ", "لَا"] do
      assert Width.cells(text, :narrow) == 1
      assert {:ok, [line]} = Text.lines([run(text)], 1, :narrow, 1)
      assert strings([line]) == [text]
      assert line.cells == 1
      assert Enum.sum(Enum.map(line.units, & &1.width)) == 1
    end
  end

  test "all pinned Unicode vectors retain widths across each scalar span boundary" do
    fixture = Path.expand("../../../fixtures/unicode_width/vectors.json", __DIR__)
    vectors = fixture |> File.read!() |> Jason.decode!() |> Map.fetch!("vectors")

    for vector <- vectors, policy <- [:narrow, :wide] do
      runs =
        vector["text"]
        |> String.codepoints()
        |> Enum.with_index()
        |> Enum.map(fn {cp, i} -> run(cp, if(rem(i, 2) == 0, do: @red, else: @plain)) end)

      assert {:ok, [line]} = Text.lines(runs, 40, policy, 1)
      assert strings([line]) == [vector["text"]]
      assert line.cells == vector[Atom.to_string(policy)]
      assert Enum.sum(Enum.map(line.units, & &1.width)) == line.cells
      assert Enum.map(line.units, & &1.text) == String.graphemes(vector["text"])
    end
  end

  test "regional indicator pairing follows the complete logical text across spans and rows" do
    text = "🇦🇧🇨🇩🇪"
    assert {:ok, lines} = Text.lines([run("🇦"), run("🇧🇨🇩🇪", @red)], 2, :narrow, 5)
    assert strings(lines) == String.graphemes(text)
    assert Enum.flat_map(lines, & &1.units) |> Enum.map(& &1.width) == [2, 2, 1]
  end

  test "oversized single graphemes reject within the unit budget" do
    assert {:error, :capacity_exceeded} =
             Text.lines([run("a" <> :binary.copy("́", 131_072))], 1, :narrow, 1)
  end

  test "a whole glyph wider than the viewport consumes one blank clipped row" do
    assert {:ok, lines} = Text.lines([run("界x")], 1, :narrow, 2)
    assert strings(lines) == ["", "x"]
  end

  test "invalid envelopes, raw controls, invalid UTF-8 and isolated zero width reject" do
    for runs <- [
          [run("\e[1m")],
          [run("\r")],
          [run("\t")],
          [run(<<255>>)],
          [run("́")],
          [Map.put(run("a"), :extra, 1)],
          [run("a", %{oops: true})],
          [run("a", @plain, "")],
          [run("a") | :bad]
        ] do
      assert {:error, :invalid_text} = Text.lines(runs, 8, :narrow, 1)
    end

    assert {:error, :invalid_text} = Text.lines([], -1, :narrow, 1)
    assert {:error, :invalid_text} = Text.lines([], 8, :invalid, 1)
    assert {:error, :capacity_exceeded} = Text.lines([], 501, :narrow, 1)
    assert {:error, :capacity_exceeded} = Text.lines([], 8, :narrow, 201)
    assert {:error, :capacity_exceeded} = Text.lines(List.duplicate(run(""), 4097), 8, :narrow, 1)

    assert {:error, :capacity_exceeded} =
             Text.lines([run(:binary.copy("a", 4 * 1024 * 1024 + 1))], 8, :narrow, 1)
  end

  test "one visible row does not shape the remainder of a 4 MiB run" do
    short = [run(:binary.copy("a", 4096))]
    long = [run(:binary.copy("a", 4 * 1024 * 1024))]
    Text.lines(short, 8, :narrow, 1)
    {short_work, {:ok, short_lines}} = reductions(fn -> Text.lines(short, 8, :narrow, 1) end)
    {long_work, {:ok, long_lines}} = reductions(fn -> Text.lines(long, 8, :narrow, 1) end)
    assert strings(long_lines) == ["aaaaaaaa"]
    assert short_lines == long_lines
    assert long_work < short_work * 3 + 5000
  end

  defp reductions(fun) do
    {:reductions, before} = Process.info(self(), :reductions)
    result = fun.()
    {:reductions, ending} = Process.info(self(), :reductions)
    {ending - before, result}
  end
end
