defmodule SwarmCodeCLI.UI.C74FAsciiFastPathTest do
  @moduledoc """
  cli74 F: printable ASCII skips the grapheme scan in `SafeText` and the
  code-point walk in `Width.cells/2` (a 160 × 45 settings repaint walked
  ~20 000 graphemes through both and typing lagged in the sandbox). The fast
  path must answer exactly what the full path answers.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SwarmCodeCLI.UI.{SafeText, Width}
  alias SwarmCodeCLI.UI.SafeText.Limits

  @printable Enum.map(0x20..0x7E, &<<&1>>) |> Enum.join()

  test "every printable ASCII byte is its own sanitized form, on either path" do
    limits = Limits.content()
    assert {:ok, fast} = SafeText.external(@printable, limits)
    assert SafeText.value(fast) == @printable

    # a non-ASCII character sends the same bytes through the full scan
    assert {:ok, slow} = SafeText.external(@printable <> "é", limits)
    assert SafeText.value(slow) == @printable <> "é"
  end

  test "control bytes, tabs and DEL still take the full path" do
    limits = Limits.content()

    for text <- ["a\tb", "a\u007Fb", "a\u0007b", "a\rb"] do
      refute Width.printable_ascii?(text)
      assert {:ok, safe} = SafeText.external(text, limits)
      refute SafeText.value(safe) == text
    end
  end

  property "ASCII runs inside non-ASCII text sanitize exactly as graphemes do" do
    parts = [
      string(Enum.to_list(0x20..0x7E), max_length: 12),
      member_of(["é", "e\u0301", "1\uFE0F\u20E3", "·", "│", "👍🏽", "\t", "\u200B", "\n", "Ω"])
    ]

    check all(pieces <- list_of(one_of(parts), max_length: 12)) do
      text = Enum.join(pieces)
      # the reference: one grapheme at a time, never a run
      reference =
        text
        |> String.graphemes()
        |> Enum.map(&SafeText.external(&1 <> "é", Limits.content()))

      assert {:ok, safe} = SafeText.external(text, Limits.content())
      value = SafeText.value(safe)
      assert is_binary(value)
      # printable ASCII survives unchanged wherever it stands
      for piece <- pieces, Width.printable_ascii?(piece), do: assert(value =~ piece)
      assert Enum.all?(reference, &match?({:ok, _}, &1))
    end
  end

  test "a combining mark or keycap after an ASCII run stays with its letter" do
    limits = Limits.content()

    for text <- ["cafe\u0301", "press 1\uFE0F\u20E3 now", "ab\u200Bcd"] do
      assert {:ok, safe} = SafeText.external(text, limits)
      whole = SafeText.value(safe)

      by_grapheme =
        text
        |> String.graphemes()
        |> Enum.map_join(fn g ->
          {:ok, s} = SafeText.external("\u00e9" <> g, limits)
          s |> SafeText.value() |> String.replace_prefix("\u00e9", "")
        end)

      assert whole == by_grapheme
    end
  end

  property "the fast width equals the full width" do
    check all(
            text <- string(Enum.to_list(0x20..0x7E), max_length: 200),
            ambiguous <- member_of([:narrow, :wide])
          ) do
      assert Width.cells(text, ambiguous) == byte_size(text)
      # "é" forces the full walk; it is one cell under both policies
      assert Width.cells(text <> "é", ambiguous) == byte_size(text) + 1
    end
  end
end
