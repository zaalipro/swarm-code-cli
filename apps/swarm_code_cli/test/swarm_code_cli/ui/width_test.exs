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

  test "take_cells and wrap keep lam-alef contextual units together" do
    for mode <- [:narrow, :wide] do
      assert Width.take_cells("لاx", 1, mode) == {"لا", "x", 1}
      assert Width.wrap("لاx", 1, mode) == ["لا", "x"]
    end
  end

  test "all reverse-state dependency families form additive contextual units" do
    sequences = [
      {"ل\u0651ا", 1},
      {"א\u200Dל", 1},
      {"\u1A15\u1A17\u200D\u1A10", 1},
      {"\u2D4F\u2D7F\u2D3E", 1},
      {"\u2D4F\u2D7F\u034F\u2D3E", 1},
      {"\u2D4F\u200D\u2D3E", 1},
      {"\u{10C32}\u200D\u{10C03}", 1},
      {"\u17D2\u1780", 0},
      {"\u17D2\u034F\u1780", 0},
      {"\uA4F9\uA4FC", 1},
      {"\uA4F9\u034F\uA4FC", 1},
      {"\u{16D63}\u{16D67}", 1},
      {"👩‍💻", 2},
      {"🏻‍👩", 2},
      {"1️⃣‍👩", 2},
      {"🇬🇪‍👩", 2}
    ]

    for mode <- [:narrow, :wide], {unit, expected} <- sequences do
      assert Enum.to_list(Width.units(unit <> "x", mode)) == [{unit, expected}, {"x", 1}]
      assert Width.take_cells(unit <> "x", expected, mode) == {unit, "x", expected}

      assert Width.wrap(unit <> "x", 1, mode) ==
               if(expected == 0, do: [unit <> "x"], else: [unit, "x"])
    end
  end

  test "emoji chains retain regional-indicator parity across grapheme boundaries" do
    for mode <- [:narrow, :wide], count <- 1..7 do
      chain = String.duplicate("🇬", count) <> "‍👩"
      units = Enum.to_list(Width.units(chain, mode))
      assert Enum.sum(Enum.map(units, &elem(&1, 1))) == Width.cells(chain, mode)
      assert Width.wrap(chain, 1, mode) == [chain]
    end
  end

  test "unit sums and every returned prefix agree with the unchanged width oracle" do
    texts = Enum.map(WidthFixtures.vectors(), & &1["text"])
    pairs = for a <- texts, b <- texts, do: a <> b

    for text <- texts ++ pairs, mode <- [:narrow, :wide] do
      units = Enum.to_list(Width.units(text, mode))
      assert Enum.map_join(units, &elem(&1, 0)) == text

      assert Enum.sum(Enum.map(units, &elem(&1, 1))) == Width.cells(text, mode),
             inspect({text, mode, units})

      Enum.reduce(units, {"", 0}, fn {unit, cells}, {prefix, used} ->
        prefix = prefix <> unit
        assert used + cells == Width.cells(prefix, mode), inspect({text, prefix, mode})
        {prefix, used + cells}
      end)
    end
  end

  test "a transparent scalar may start another overlapping contextual dependency" do
    for mode <- [:narrow, :wide] do
      text = "ل\u17D2\u1780x"
      assert Enum.to_list(Width.units(text, mode)) == [{"ل\u17D2\u1780", 1}, {"x", 1}]
      assert Width.take_cells(text, 1, mode) == {"ل\u17D2\u1780", "x", 1}
    end
  end

  test "wrapping every vector preserves units and fits non-forced rows" do
    for %{"text" => text} <- WidthFixtures.vectors(),
        mode <- [:narrow, :wide],
        width <- 1..4 do
      for source <- String.split(text, ["\r\n", "\n"]), source != "" do
        units = Enum.map(Width.units(source, mode), &elem(&1, 0))
        rows = Width.wrap(source, width, mode)
        assert Enum.join(rows) == source

        assert Enum.reduce(rows, units, fn row, remaining ->
                 {row_units, rest} = row_units(row, remaining, [])
                 assert Enum.join(row_units) == row
                 assert Width.cells(row, mode) <= width or row_units == [row]
                 rest
               end) == []
      end
    end
  end

  defp row_units("", rest, acc), do: {Enum.reverse(acc), rest}

  defp row_units(row, [unit | rest], acc) do
    assert String.starts_with?(row, unit)
    tail = binary_part(row, byte_size(unit), byte_size(row) - byte_size(unit))
    row_units(tail, rest, [unit | acc])
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

  # Measure whole prefixes only in the reference, at independent unit boundaries.
  test "take_cells cuts where the whole-unit-prefix measure cut" do
    texts = Enum.map(WidthFixtures.vectors(), & &1["text"])
    pairs = for a <- Enum.take(texts, 40), b <- Enum.take(texts, 40), do: a <> b

    for text <- texts ++ pairs, policy <- [:narrow, :wide], limit <- 0..8 do
      assert Width.take_cells(text, limit, policy) == reference(text, limit, policy, "", 0),
             inspect({text, limit, policy})
    end
  end

  test "take_cells is linear in the text it takes (it was quadratic)" do
    text = String.duplicate("abcde fghij ", 400)
    short = reductions(fn -> Width.take_cells(String.slice(text, 0, 2000), 2000, :narrow) end)
    long = reductions(fn -> Width.take_cells(String.slice(text, 0, 4000), 4000, :narrow) end)
    assert long < 3 * short
    assert long < 1_000_000
  end

  test "contextual traversal is linear and lazy in the consumed prefix" do
    short = String.duplicate("لا", 1_000)
    long = String.duplicate("لا", 2_000)
    short_work = reductions(fn -> Width.take_cells(short, 1_000, :narrow) end)
    long_work = reductions(fn -> Width.take_cells(long, 2_000, :narrow) end)
    assert long_work < 3 * short_work

    small = "لاx" <> String.duplicate("א\u200Dל", 100)
    large = "لاx" <> String.duplicate("א\u200Dל", 10_000)
    small_work = reductions(fn -> Enum.take(Width.units(small, :wide), 1) end)
    large_work = reductions(fn -> Enum.take(Width.units(large, :wide), 1) end)
    assert large_work < 4 * small_work
    assert Enum.take(Width.units(large, :wide), 1) == [{"لا", 1}]
  end

  defp reductions(fun) do
    fun.()
    {:reductions, before} = Process.info(self(), :reductions)
    fun.()
    {:reductions, after_count} = Process.info(self(), :reductions)
    after_count - before
  end

  defp reference(remaining, limit, policy, prefix, used) do
    case Enum.take(Width.units(remaining, policy), 1) do
      [] ->
        {prefix, "", used}

      [{grapheme, _}] ->
        tail =
          binary_part(remaining, byte_size(grapheme), byte_size(remaining) - byte_size(grapheme))

        candidate = prefix <> grapheme
        width = Width.cells(candidate, policy)

        if width <= limit,
          do: reference(tail, limit, policy, candidate, width),
          else: {prefix, remaining, used}
    end
  end
end
