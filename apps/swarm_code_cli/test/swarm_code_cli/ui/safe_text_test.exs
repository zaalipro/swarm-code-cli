defmodule SwarmCodeCLI.UI.SafeTextTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias SwarmCodeCLI.UI.SafeText
  alias SwarmCodeCLI.UI.SafeText.Limits

  test "external controls are inert and named" do
    fixtures =
      __DIR__
      |> Path.join("../../fixtures/safe_text/adversarial.json")
      |> File.read!()
      |> :json.decode()

    for %{"input" => input, "output" => output} <- fixtures do
      assert {:ok, safe} = SafeText.external(input, Limits.content())
      assert SafeText.value(safe) == output
    end
  end

  test "tabs use terminal cells and reset at newline" do
    assert {:ok, safe} = SafeText.external("界\té\t👩‍💻\t\na\t", Limits.content())
    assert SafeText.value(safe) == "界      é       👩‍💻      \na       "
  end

  test "invalid bytes and standalone invisible marks are exposed" do
    assert {:ok, safe} =
             SafeText.external(<<0xFF, 0xC0, 0xAF>> <> "\u0301\u200d\ufe0f", Limits.content())

    assert SafeText.value(safe) == "���⟦COMBINING U+0301⟧⟦ZWJ U+200D⟧⟦VS16 U+FE0F⟧"
    assert {:ok, safe} = SafeText.external("a\u200dZ", Limits.content())
    assert SafeText.value(safe) == "a⟦ZWJ U+200D⟧Z"
    assert {:ok, safe} = SafeText.external("é 👩‍💻 ❤️ ✈︎", Limits.content())
    assert SafeText.value(safe) == "é 👩‍💻 ❤️ ✈︎"
  end

  test "input and output limits reject before returning partial values" do
    assert {:ok, _} = SafeText.external(String.duplicate("x", 65_536), Limits.content())

    assert {:error, :input_too_large} =
             SafeText.external(String.duplicate("x", 65_537), Limits.content())

    assert {:ok, _} = SafeText.external(String.duplicate("x", 8_192), Limits.composer_viewport())

    assert {:error, :input_too_large} =
             SafeText.external(String.duplicate("x", 8_193), Limits.composer_viewport())

    limits = struct!(Limits, input_bytes: 10, escaped_bytes: 9, tab_width: 8)
    assert {:ok, safe} = SafeText.external("\e", limits)
    assert SafeText.value(safe) == "⟦ESC⟧"
    assert {:error, :escaped_output_too_large} = SafeText.external("\ex", limits)
  end

  test "chunks are one bounded field preserving every byte and grapheme split" do
    input = "界\té👩‍💻\n\e\u202e" <> <<0xFF>>
    assert {:ok, expected} = SafeText.external(input, Limits.content())

    for split <- 0..byte_size(input) do
      <<left::binary-size(split), right::binary>> = input

      assert [{:ok, safe}] =
               Enum.to_list(SafeText.external_chunks([left, right], Limits.content()))

      assert SafeText.value(safe) == SafeText.value(expected)
    end

    assert [{:ok, safe}] = Enum.to_list(SafeText.external_chunks([], Limits.content()))
    assert SafeText.value(safe) == ""
  end

  test "oversized chunk streams halt without reading downstream chunks" do
    chunks =
      Stream.map([String.duplicate("x", 8_193), :unreachable], fn
        :unreachable -> flunk("stream consumed after input rejection")
        chunk -> chunk
      end)

    assert [{:error, :input_too_large}] =
             Enum.to_list(SafeText.external_chunks(chunks, Limits.composer_viewport()))
  end

  test "external value boundary rejects forged controls and over-limit representations" do
    {:ok, safe} = SafeText.external("ok", Limits.content())
    assert {:external, "ok"} = safe.token

    for input <- [
          "\e[31m",
          "\r",
          "\t",
          "\u200b",
          "\u0301",
          <<0xFF>>,
          String.duplicate("x", 262_145)
        ] do
      forged = %{safe | token: {:external, input}}
      assert_raise ArgumentError, fn -> SafeText.value(forged) end
    end

    assert_raise FunctionClauseError, fn -> safe |> Map.put(:rogue, true) |> SafeText.value() end
  end

  test "concat validates inputs and numbers expose only nonnegative decimal data" do
    {:ok, mark} = SafeText.external("\u0301", Limits.content())

    assert SafeText.value(SafeText.concat([SafeText.chrome(:main), SafeText.number(42), mark])) ==
             "Main42⟦COMBINING U+0301⟧"

    assert SafeText.value(SafeText.concat([])) == ""
    assert_raise FunctionClauseError, fn -> SafeText.number(-1) end
    assert_raise ArgumentError, fn -> SafeText.concat([%SafeText{token: {:external, "\e"}}]) end
  end

  test "wide ambiguous cells determine tab stops using the same width policy" do
    limits =
      struct!(Limits, input_bytes: 100, escaped_bytes: 200, tab_width: 8, ambiguous_width: :wide)

    assert {:ok, safe} = SafeText.external("·\t·\t\n·\t", limits)
    assert SafeText.value(safe) == "·      ·      \n·      "
  end

  test "emoji keycaps and valid flag tags survive but invisible impostors are named" do
    valid = "1️⃣ #️⃣ *️⃣ 🏴" <> "\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}"
    assert {:ok, safe} = SafeText.external(valid, Limits.content())
    assert SafeText.value(safe) == valid
    assert {:ok, safe} = SafeText.external("a️ a\u034f a\u{E0067}", Limits.content())
    assert SafeText.value(safe) == "a⟦VS16 U+FE0F⟧ a⟦CGJ U+034F⟧ a⟦TAG U+E0067⟧"
  end

  test "pathological graphemes reject at the output ceiling and concat remains bounded" do
    limits = struct!(Limits, input_bytes: 65_536, escaped_bytes: 20, tab_width: 8)

    assert {:error, :escaped_output_too_large} =
             SafeText.external(String.duplicate("\u0301", 30_000), limits)

    assert {:ok, full} = SafeText.external(String.duplicate("x", 65_536), Limits.content())

    assert_raise ArgumentError, fn ->
      SafeText.concat([full, full, full, full, SafeText.chrome(:main)])
    end
  end

  test "forged limits and unknown policies fail closed" do
    for options <- [
          [input_bytes: -1],
          [escaped_bytes: 262_145],
          [tab_width: 0],
          [ambiguous_width: :auto]
        ] do
      limits = struct!(Limits, [input_bytes: 100, escaped_bytes: 100] ++ options)
      assert_raise ArgumentError, fn -> SafeText.external("a", limits) end
    end
  end

  test "variation selectors use pinned Unicode eligibility instead of broad symbol ranges" do
    assert {:ok, safe} = SafeText.external("▫️ ⬁️", Limits.content())
    assert SafeText.value(safe) == "▫️ ⬁⟦VS16 U+FE0F⟧"
  end

  test "escaping a mark or selector invalidates the enclosing emoji join" do
    for {input, expected} <- [
          {"👩\u034f\u200d💻", "👩⟦CGJ U+034F⟧⟦ZWJ U+200D⟧💻"},
          {"👩\u0301\ufe0f\u200d💻", "👩\u0301⟦VS16 U+FE0F⟧⟦ZWJ U+200D⟧💻"}
        ] do
      assert {:ok, safe} = SafeText.external(input, Limits.content())
      assert SafeText.value(safe) == expected
    end
  end

  test "unregistered selector pairs remain visible instead of relying on broad ranges" do
    for {input, expected} <- [
          {"👩\ufe00", "👩⟦VS U+FE00⟧"},
          {"界\ufe00", "界⟦VS U+FE00⟧"},
          {"👩\u{E0100}", "👩⟦VS U+E0100⟧"}
        ] do
      assert {:ok, safe} = SafeText.external(input, Limits.content())
      assert SafeText.value(safe) == expected
    end
  end

  test "attested standardized, Mongolian, emoji and registered ideographic variants survive" do
    valid = "0\ufe00 ∩\ufe00 麗\ufe00 ᠠ\u180b 一\u{E0100} 邉\u{E0100} ❤️ ✈︎"
    assert {:ok, safe} = SafeText.external(valid, Limits.content())
    assert SafeText.value(safe) == valid
    assert {:ok, safe} = SafeText.external("a\u180b", Limits.content())
    assert SafeText.value(safe) == "a⟦FVS1 U+180B⟧"
  end

  test "new chrome tokens round-trip through chrome/1, value/1 and concat" do
    alias SwarmCodeCLI.UI.Width

    tokens = [
      {:swarmcode_wordmark, "SWARMCODE"},
      {:workspace_label, "WORKSPACE"},
      {:nav_conversation, "Conversation"},
      {:nav_activity, "Activity"},
      {:nav_workflows, "Workflows"},
      {:nav_research, "Research"},
      {:nav_memory, "Memory"},
      {:runs_label, "RUNS"},
      {:glyph_selected, "◉"},
      {:glyph_inactive, "◌"},
      {:glyph_workflows, "⧉"},
      {:glyph_research, "⌁"},
      {:glyph_memory, "⌘"},
      {:glyph_changes, "⬡"},
      {:live_run_label, "LIVE RUN"},
      {:agents_label, "AGENTS"},
      {:you_label, "YOU"},
      {:assistant_label, "assistant"},
      {:tool_label, "tool"},
      {:system_label, "system"},
      {:gap_hairline, "╎"},
      {:composer_gutter, "▐"},
      {:pipeline_arrow, "❯"},
      {:persistent_objective, "Persistent objective"},
      {:plan_approve, "Approve"},
      {:plan_revise, "Revise"},
      {:plan_decline, "Decline"},
      {:plan_done, "✓"},
      {:plan_steps_label, "PLAN STEPS"}
    ]

    for {token, expected_value} <- tokens do
      safe = SafeText.chrome(token)
      assert SafeText.value(safe) == expected_value, "value mismatch for #{token}"

      # Round-trip: concat with empty produces the same value
      concatenated = SafeText.concat([safe, SafeText.chrome(:empty)])
      assert SafeText.value(concatenated) == expected_value
    end
  end

  test "new glyph tokens are exactly 1 cell under both width policies" do
    alias SwarmCodeCLI.UI.Width

    glyph_tokens = [
      {:glyph_selected, "◉"},
      {:glyph_inactive, "◌"},
      {:glyph_workflows, "⧉"},
      {:glyph_research, "⌁"},
      {:glyph_memory, "⌘"},
      {:glyph_changes, "⬡"},
      {:gap_hairline, "╎"},
      {:composer_gutter, "▐"},
      {:pipeline_arrow, "❯"},
      {:plan_done, "✓"}
    ]

    ascii_fallbacks = [
      {"*", :glyph_selected},
      {"o", :glyph_inactive},
      {"#", :glyph_workflows},
      {"^", :glyph_research},
      {"@", :glyph_memory},
      {"+", :glyph_changes},
      {"|", :gap_hairline},
      {">", :composer_gutter},
      {">", :pipeline_arrow},
      {"*", :plan_done}
    ]

    for {token, glyph} <- glyph_tokens do
      assert Width.cells(glyph, :narrow) == 1,
             "#{token} glyph #{glyph} is not 1 cell under :narrow"

      assert Width.cells(glyph, :wide) == 1,
             "#{token} glyph #{glyph} is not 1 cell under :wide"
    end

    for {ascii, token} <- ascii_fallbacks do
      assert Width.cells(ascii, :narrow) == 1,
             "ASCII fallback #{ascii} for #{token} is not 1 cell"

      assert Width.cells(ascii, :wide) == 1,
             "ASCII fallback #{ascii} for #{token} is not 1 cell under :wide"
    end
  end

  property "mixed valid Unicode and deceptive scalars produce a stable safe value" do
    check all(
            chunks <-
              list_of(
                member_of([
                  "a",
                  "界",
                  "👩",
                  "💻",
                  "\u200d",
                  "\ufe0f",
                  "\u0301",
                  "\u034f",
                  "\u{E0067}",
                  "\n",
                  "\t",
                  "\e",
                  "\u202e"
                ]),
                max_length: 100
              ),
            max_runs: 100
          ) do
      assert {:ok, safe} = SafeText.external(IO.iodata_to_binary(chunks), Limits.content())
      output = SafeText.value(safe)
      assert {:ok, again} = SafeText.external(output, Limits.content())
      assert SafeText.value(again) == output
    end
  end

  property "arbitrary binaries yield bounded valid inert terminal text" do
    check all(input <- binary(max_length: 4096), max_runs: 100) do
      assert {:ok, safe} = SafeText.external(input, Limits.content())
      output = SafeText.value(safe)
      assert String.valid?(output)
      assert byte_size(output) <= 262_144

      refute Regex.match?(
               ~r/[\x00-\x09\x0B-\x1F\x7F-\x9F\x{202A}-\x{202E}\x{2066}-\x{2069}]/u,
               output
             )
    end
  end
end
