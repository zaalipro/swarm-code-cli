defmodule SwarmCodeCLI.UI.Paint.MarkdownTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.UI.Paint.{Markdown, Options}
  @base %{foreground: nil, background: nil, modifiers: []}
  defp lines(text, width \\ 80, rows \\ 100) do
    assert {:ok, lines} = Markdown.lines(text, width, %Options{}, @base, rows, :narrow)
    lines
  end

  defp strings(lines), do: Enum.map(lines, &Enum.map_join(&1.units, fn u -> u.text end))

  test "headings, emphasis, list and fenced code are readable with semantic styles" do
    result =
      lines("# Heading\nA **bold** and *italic* and `code`.\n- item\n```ex\na < b\n```\nafter")

    assert strings(result) == [
             "Heading",
             "A bold and italic and code.",
             "• item",
             "ex",
             "a < b",
             "after"
           ]

    assert Enum.all?(hd(result).units, &(:bold in &1.style.modifiers))
    assert Enum.any?(Enum.at(result, 1).units, &(:italic in &1.style.modifiers))
  end

  test "unsupported syntax and external Unicode remain literal" do
    text = "[link](https://example.com) <b>x</b> ~~strike~~\n界é 👩‍💻\n**unclosed"
    assert strings(lines(text)) == String.split(text, "\n")
  end

  test "a long ordinary paragraph fills its bounded grid without exhausting span budget" do
    result = lines(String.duplicate("a", 10_000), 100, 50)
    assert length(result) == 50
    assert Enum.all?(result, &(&1.cells == 100))
  end

  test "contextual ligatures fill every available cell" do
    assert strings(lines("لالالالا", 3, 1)) == ["لالالا"]
  end

  test "fenced code preserves blank lines and CRLF source line endings" do
    assert strings(lines("```\na\n\nb\n```")) == ["a", "", "b"]
    assert strings(lines("a\r\nb")) == ["a", "b"]
  end

  test "rejects source byte overflow before clipping or markdown parsing" do
    assert {:error, :capacity_exceeded} =
             Markdown.lines(String.duplicate("a", 4 * 1024 * 1024 + 1), 1, %Options{}, @base, 1)
  end

  test "markup removal preserves combining context beyond any source grapheme estimate" do
    source = "a" <> String.duplicate("**́**", 20) <> "x"
    assert strings(lines(source, 2, 1)) == ["a" <> String.duplicate("́", 20) <> "x"]
  end

  test "clipping bounds paragraph output and does not split wide glyphs" do
    assert strings(lines("# 界界界\nnever", 3, 1)) == ["界"]
    assert lines("# title", 3, 0) == []
  end

  test "unsafe or oversized transformed runs preserve the admitted source line literally" do
    for source <- ["**́**", "**́**x", "- a" <> String.duplicate("**́**", 4095)] do
      assert {:ok, safe} =
               SwarmCodeCLI.UI.SafeText.external(
                 source,
                 SwarmCodeCLI.UI.SafeText.Limits.content()
               )

      source = SwarmCodeCLI.UI.SafeText.value(safe)
      expected = SwarmCodeCLI.UI.Width.wrap(source, 80, :narrow) |> Enum.take(100)
      assert strings(lines(source)) == expected
    end
  end
end
