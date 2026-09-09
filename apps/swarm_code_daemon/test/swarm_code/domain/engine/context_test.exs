defmodule SwarmCode.Domain.Engine.ContextTest do
  use ExUnit.Case, async: true

  alias SwarmCode.Domain.Engine.Context

  test "estimate_tokens/1" do
    assert Context.estimate_tokens([%{role: "user", content: String.duplicate("a", 400)}]) == 104
  end

  test "trim/2 drops the oldest messages but keeps two" do
    messages =
      for i <- 1..6, do: %{role: "user", content: String.duplicate("#{i}", 400)}

    trimmed = Context.trim(messages, 150)
    assert length(trimmed) == 2
    assert List.last(trimmed) == List.last(messages)
  end

  test "trim/2 keeps short histories" do
    messages = [%{role: "user", content: "a"}, %{role: "assistant", content: "b"}]
    assert Context.trim(messages, 150) == messages
  end

  test "trim/2 compresses old tool output before dropping messages" do
    big = String.duplicate("x", 4_000)

    messages =
      [%{role: "user", content: "start"}] ++
        for i <- 1..20 do
          %{role: "tool", tool_call_id: "t#{i}", name: "read_file", content: big}
        end

    trimmed = Context.trim(messages, 9_000)

    # Nothing was dropped: compression alone got the history under budget.
    assert length(trimmed) == length(messages)
    assert Context.estimate_tokens(trimmed) <= 9_000

    assert Enum.at(trimmed, 1)[:content] ==
             "[tool output omitted (4000 chars) — re-read the file if needed]"

    # The last 8 messages are never compressed.
    assert trimmed |> Enum.take(-8) |> Enum.all?(&(&1[:content] == big))
  end

  test "trim/2 still drops messages when compression is not enough" do
    big = String.duplicate("x", 4_000)
    messages = for i <- 1..6, do: %{role: "user", content: big <> "#{i}"}

    trimmed = Context.trim(messages, 150)
    assert length(trimmed) == 2
    assert List.last(trimmed) == List.last(messages)
  end

  # -------------------------------------- sakana task 12: exchanges and images

  defp assistant(id, size) do
    %{
      role: "assistant",
      content: String.duplicate("a", size),
      tool_calls: [%{id: id, name: "read_file", args: %{"path" => "lib/a.ex"}}]
    }
  end

  defp result(id, size) do
    %{
      role: "tool",
      tool_call_id: id,
      name: "read_file",
      content: String.duplicate("r", size),
      is_error: false
    }
  end

  defp exchanges(n, size) do
    Enum.flat_map(1..n, fn i ->
      [
        %{role: "user", content: String.duplicate("u", size)},
        assistant("call-#{i}", size),
        result("call-#{i}", size)
      ]
    end)
  end

  test "trimming drops whole tool exchanges, never a lone result" do
    trimmed = Context.trim(exchanges(6, 2_000), 3_000)

    assert Context.estimate_tokens(trimmed) <= 3_000
    refute hd(trimmed)[:role] == "tool"
    assert List.last(trimmed)[:role] == "tool"

    # Every retained result still has the assistant call that produced it.
    ids = for m <- trimmed, m[:role] == "assistant", c <- m[:tool_calls], do: c.id
    results = for m <- trimmed, m[:role] == "tool", do: m[:tool_call_id]
    assert Enum.all?(results, &(&1 in ids))
  end

  test "an assistant message with several calls keeps all of its results" do
    history =
      [%{role: "user", content: String.duplicate("u", 8_000)}] ++
        [
          %{
            role: "assistant",
            content: "",
            tool_calls: [
              %{id: "a", name: "read_file", args: %{}},
              %{id: "b", name: "read_file", args: %{}}
            ]
          },
          result("a", 100),
          result("b", 100),
          %{role: "assistant", content: "done"}
        ]

    trimmed = Context.trim(history, 200)
    refute Enum.any?(trimmed, &(&1[:content] =~ "uuu"))
    ids = for m <- trimmed, m[:role] == "tool", do: m[:tool_call_id]
    assert ids == ["a", "b"] or ids == []
  end

  test "a leading orphan tool result is dropped" do
    history = [
      result("gone", 10),
      %{role: "user", content: "hi"},
      %{role: "assistant", content: "there"}
    ]

    assert Context.trim(history, 120_000) == tl(history)
  end

  test "both provider formatters accept the trimmed history" do
    trimmed = Context.trim(exchanges(6, 2_000), 3_000)

    anthropic = SwarmCode.Domain.LLM.Anthropic.format_messages(trimmed)

    refute match?(
             %{"role" => "user", "content" => [%{"type" => "tool_result"} | _]},
             hd(anthropic)
           )

    openai = SwarmCode.Domain.LLM.OpenAI.format_messages("sys", trimmed)
    tools = Enum.filter(openai, &(&1["role"] == "tool"))
    calls = for m <- openai, m["tool_calls"], c <- m["tool_calls"], do: c["id"]
    assert Enum.all?(tools, &(&1["tool_call_id"] in calls))
  end

  # Spec 51 §6.5: an image costs the tokens the provider charges for it, not
  # `base64_bytes / 4`. An image whose `:tokens` was never stamped is charged
  # the 4 784 ceiling — still bounded, still enough to evict on its own.
  test "images count towards the estimate at the provider's rate, not by their bytes" do
    data = String.duplicate("Z", 40_000)
    plain = %{role: "user", content: "look"}
    with_image = Map.put(plain, :images, [%{mime: "image/png", data: data, name: "a.png"}])

    assert Context.estimate_tokens([with_image]) - Context.estimate_tokens([plain]) == 4_784

    small = Map.put(plain, :images, [%{mime: "image/png", data: data, name: "a.png", tokens: 42}])
    assert Context.estimate_tokens([small]) - Context.estimate_tokens([plain]) == 42

    history = [
      with_image,
      %{role: "user", content: "and this"},
      %{role: "assistant", content: "ok"}
    ]

    trimmed = Context.trim(history, 1_000)
    assert length(trimmed) == 2
    refute Enum.any?(trimmed, &Map.has_key?(&1, :images))
  end

  # ---------------------------------------------------------------- spec 30 §2

  test "a turn with no continuation state estimates exactly as before" do
    plain = %{role: "assistant", content: "hello", tool_calls: []}

    assert Context.estimate_tokens([plain]) ==
             Context.estimate_tokens([Map.put(plain, :provider_blocks, [])])
  end

  test "continuation blocks are counted instead of the content they contain" do
    blocks = [
      %{"type" => "thinking", "thinking" => String.duplicate("t", 400), "signature" => "s"},
      %{"type" => "text", "text" => "hello"}
    ]

    message = %{
      role: "assistant",
      content: "hello",
      tool_calls: [%{id: "c1", name: "read_file", args: %{"path" => "a.ex"}}],
      provider_blocks: blocks
    }

    # The blocks already carry the text and the tool input: counting both would
    # charge this turn twice and evict history that still fits.
    assert Context.estimate_tokens([message]) ==
             div(byte_size(Jason.encode!(blocks)), 4) + 4
  end

  test "an image beside continuation blocks still counts" do
    data = String.duplicate("Z", 4_000)
    blocks = [%{"type" => "text", "text" => "hi"}]

    message = %{
      role: "assistant",
      content: "hi",
      provider_blocks: blocks,
      images: [%{mime: "image/png", data: data, name: "a.png", tokens: 300}]
    }

    assert Context.estimate_tokens([message]) ==
             div(byte_size(Jason.encode!(blocks)), 4) + 300 + 4
  end

  # ------------------------------------------------------------- spec 51 §6.5

  describe "pass45 (spec 51 §6.5)" do
    defp png(width, height) do
      <<0x89, "PNG\r\n", 0x1A, 0x0A, 13::32, "IHDR", width::32, height::32>> <>
        String.duplicate("Z", 64)
    end

    defp screenshot_message(text) do
      binary = png(1_512, 982)

      %{
        role: "user",
        content: text,
        images: [
          %{
            mime: "image/png",
            data: Base.encode64(binary),
            name: "shot.png",
            tokens: SwarmCode.Domain.Attachments.image_tokens(binary, "image/png")
          }
        ]
      }
    end

    # Reader A #10: the finder measured 10 seeded messages at 745 tokens and one
    # 1.5 MB PNG at 500 781 — against a 120 000 budget, which is why turn 1 sent
    # 2 of 12 messages.
    test "one screenshot no longer evicts ten messages" do
      texts = for i <- 1..10, do: %{role: "user", content: "message #{i}"}
      history = texts ++ [screenshot_message("look at this")]

      assert Context.estimate_tokens(history) <= 15_000

      trimmed = Context.trim(history)
      assert length(trimmed) == 11
      assert List.last(trimmed)[:images] != []
    end

    test "24 screenshots and 10 messages still fit the budget" do
      texts = for i <- 1..10, do: %{role: "user", content: "message #{i}"}
      shots = for i <- 1..24, do: screenshot_message("shot #{i}")
      history = texts ++ shots

      assert Context.estimate_tokens(history) < Context.budget()

      trimmed = Context.trim(history)
      assert Enum.all?(texts, &(&1 in trimmed))
    end

    test "budget/0 is the trim budget" do
      assert Context.budget() == 120_000

      assert Context.trim([%{role: "user", content: "hi"}]) ==
               Context.trim([%{role: "user", content: "hi"}], Context.budget())
    end
  end

  # ------------------------------------------------------------- spec 51 §6.7

  describe "pass45 (spec 51 §6.7)" do
    defp max_size_turn(count, chars) do
      calls = for i <- 1..count, do: %{id: "t#{i}", name: "web_fetch", args: %{}}

      [
        %{role: "user", content: "fetch six pages"},
        Context.count(%{role: "assistant", content: "on it", tool_calls: calls})
      ] ++
        for i <- 1..count do
          Context.count(%{
            role: "tool",
            tool_call_id: "t#{i}",
            name: "web_fetch",
            content: String.duplicate("x", chars)
          })
        end
    end

    test "six max-size tool results in one turn degrade instead of failing" do
      messages = max_size_turn(6, 100_000)
      assert Context.estimate_tokens(messages) > Context.budget()

      compressed = Context.compress(messages)

      assert Context.estimate_tokens(compressed) <= Context.budget()
      assert length(compressed) == length(messages)
      assert Enum.map(compressed, & &1[:role]) == Enum.map(messages, & &1[:role])

      # The assistant message that carries the calls is untouched: both
      # providers reject a tool result whose call is gone.
      assert Enum.at(compressed, 1)[:content] == "on it"
      assert Enum.at(compressed, 1)[:tool_calls] == Enum.at(messages, 1)[:tool_calls]

      cut = Enum.filter(compressed, &String.contains?(to_string(&1[:content]), "tool output cut"))
      assert cut != []
      assert Enum.all?(cut, &(&1[:role] == "tool"))
      assert hd(cut)[:content] =~ "(100000 chars)"
    end

    test "a second compress/2 is a no-op" do
      once = Context.compress(max_size_turn(6, 100_000))
      assert Context.compress(once) == once
    end
  end
end
