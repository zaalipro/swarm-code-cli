defmodule SwarmCodeCLI.UI.WidthTest do
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.Width

  defmodule WidthFixtures do
    @path Path.expand("../../fixtures/unicode_width/vectors.json", __DIR__)
    @external_resource @path
    @vectors @path |> File.read!() |> Jason.decode!() |> Map.fetch!("vectors")

    def vectors, do: @vectors

    def expected!(text) do
      vector = Enum.find(@vectors, &(&1["text"] == text)) || raise "missing width vector"
      Map.fetch!(vector, "narrow")
    end
  end

  test "width agrees with committed upstream-derived vectors" do
    Enum.each(WidthFixtures.vectors(), fn %{
                                            "name" => name,
                                            "text" => text,
                                            "narrow" => narrow,
                                            "wide" => wide
                                          } ->
      assert Width.cells(text, :narrow) == narrow, name
      assert Width.cells(text, :wide) == wide, name
    end)

    assert WidthFixtures.expected!("ქართული") == 7
    assert Width.cells("ქართული", :narrow) == 7
  end

  test "graphemes preserve extended user-perceived characters" do
    assert Width.graphemes("é👩‍💻🇬🇪") == ["é", "👩‍💻", "🇬🇪"]
  end

  test "cells ports unicode-width string state rather than summing codepoints" do
    assert Width.cells("\r\n", :narrow) == 1
    assert Width.cells("لا", :narrow) == 1
    assert Width.cells("א\u200Dל", :narrow) == 1
    assert Width.cells("\u1A15\u1A17\u200D\u1A10", :narrow) == 1
    assert Width.cells("\u17D2\u1780", :narrow) == 0
    assert Width.cells("\uA4F9\uA4FC", :narrow) == 1
    assert Width.cells("\u{10C32}\u200D\u{10C03}", :narrow) == 1
    assert Width.cells("\u2D4F\u2D7F\u2D3E", :narrow) == 1
  end

  test "cells ports presentation, modifier, flag, keycap, tag, and ZWJ state" do
    scotland = "🏴\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}"

    assert Width.cells("1️⃣", :narrow) == 2
    assert Width.cells(scotland, :narrow) == 2
    assert Width.cells("🇬🇪🇺", :narrow) == 3
    assert Width.cells("❤︎", :narrow) == 1
    assert Width.cells("❤︎", :wide) == 2
    assert Width.cells("A️", :narrow) == 1
    assert Width.cells("AB\u200DC", :narrow) == 3
  end

  test "wide mode ports CJK presentation and solidus-overlay rules" do
    assert Width.cells("“𘀀”", :narrow) == 4
    assert Width.cells("“𘀀”", :wide) == 6
    assert Width.cells("<\u0338", :narrow) == 1
    assert Width.cells("<\u0338", :wide) == 2
  end

  test "take_cells observes one cell below, at, and above every boundary" do
    text = "A界·Z"

    assert Width.take_cells(text, 0, :narrow) == {"", text, 0}
    assert Width.take_cells(text, 1, :narrow) == {"A", "界·Z", 1}
    assert Width.take_cells(text, 2, :narrow) == {"A", "界·Z", 1}
    assert Width.take_cells(text, 3, :narrow) == {"A界", "·Z", 3}
    assert Width.take_cells(text, 4, :narrow) == {"A界·", "Z", 4}
    assert Width.take_cells(text, 5, :narrow) == {text, "", 5}
    assert Width.take_cells(text, 6, :narrow) == {text, "", 5}

    assert Width.take_cells(text, 3, :wide) == {"A界", "·Z", 3}
    assert Width.take_cells(text, 4, :wide) == {"A界", "·Z", 3}
    assert Width.take_cells(text, 5, :wide) == {"A界·", "Z", 5}
  end

  test "take_cells never splits an extended grapheme" do
    text = "é👩‍💻X"

    assert Width.take_cells(text, 1, :narrow) == {"é", "👩‍💻X", 1}
    assert Width.take_cells(text, 2, :narrow) == {"é", "👩‍💻X", 1}
    assert Width.take_cells(text, 3, :narrow) == {"é👩‍💻", "X", 3}
  end

  test "take_cells is exact below, at, and above each grapheme boundary" do
    text = "A·界👩‍💻éZ"

    for ambiguous <- [:narrow, :wide], boundary <- 1..length(Width.graphemes(text)) do
      prefix = text |> Width.graphemes() |> Enum.take(boundary) |> Enum.join()
      expected_cells = Width.cells(prefix, ambiguous)

      if expected_cells > 0 do
        {below, _, below_cells} = Width.take_cells(text, expected_cells - 1, ambiguous)
        refute below == prefix
        assert below_cells == Width.cells(below, ambiguous)
      end

      {at, _, at_cells} = Width.take_cells(text, expected_cells, ambiguous)
      assert String.starts_with?(at, prefix)
      assert at_cells == Width.cells(at, ambiguous)

      {above, _, above_cells} = Width.take_cells(text, expected_cells + 1, ambiguous)
      assert String.starts_with?(above, prefix)
      assert above_cells == Width.cells(above, ambiguous)
    end
  end

  test "wrap uses terminal cells and never splits graphemes" do
    assert Width.wrap("A界B👩‍💻C", 3, :narrow) == ["A界", "B👩‍💻", "C"]
    assert Width.wrap("界", 1, :narrow) == ["界"]
  end

  test "wrap preserves hard line breaks, empty lines, and the final empty line" do
    assert Width.wrap("A\n\n界B\n", 2, :narrow) == ["A", "", "界", "B", ""]
    assert Width.wrap("AB\r\nC", 2, :narrow) == ["AB", "C"]
    assert Width.wrap("\r\n", 2, :narrow) == ["", ""]
    assert Width.wrap("", 2, :narrow) == []
  end

  test "a viewport measures only its visible prefix, independent of the hidden tail" do
    # A full-transcript prefix list used to allocate and remeasure every growing
    # prefix, even when the viewport fits only eight cells.
    small = "é👩‍💻" <> String.duplicate("x", 100)
    large = "é👩‍💻" <> String.duplicate("x", 10_000)
    Width.take_cells(small, 8, :narrow)
    {small_result, small_work} = measured_take(small)
    {large_result, large_work} = measured_take(large)

    assert elem(small_result, 0) == "é👩‍💻xxxxx"
    assert elem(large_result, 0) == "é👩‍💻xxxxx"
    assert large_work < small_work * 4
  end

  test "end elision stays within the limit without splitting graphemes" do
    assert Width.elide("A👩‍💻BC", 0, :end, :narrow) == ""
    assert Width.elide("A👩‍💻BC", 1, :end, :narrow) == "…"
    assert Width.elide("A👩‍💻BC", 3, :end, :narrow) == "A…"
    assert Width.elide("A👩‍💻BC", 5, :end, :narrow) == "A👩‍💻BC"
  end

  test "middle elision balances retained graphemes and stays within the limit" do
    assert Width.elide("AB👩‍💻CD", 4, :middle, :narrow) == "A…CD"
    assert Width.cells(Width.elide("AB👩‍💻CD", 4, :middle, :narrow), :narrow) <= 4
    refute String.contains?(Width.elide("AB👩‍💻CD", 4, :middle, :narrow), "‍")
  end

  test "middle elision retains original flag boundaries in its suffix" do
    assert Width.elide("ABXYZ🇬🇪🇺CD", 6, :middle, :narrow) == "AB…🇺CD"
  end

  defp measured_take(text) do
    {:reductions, before} = Process.info(self(), :reductions)
    result = Width.take_cells(text, 8, :narrow)
    {:reductions, after_count} = Process.info(self(), :reductions)
    {result, after_count - before}
  end
end
