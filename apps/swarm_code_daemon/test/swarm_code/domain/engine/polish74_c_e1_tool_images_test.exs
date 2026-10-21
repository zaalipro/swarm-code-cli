defmodule SwarmCode.Domain.Engine.Polish74CE1ToolImagesTest do
  @moduledoc """
  Spec 74 EFFICIENCY-40: MCP tool images stop inflating an agent's context
  after the provider has dropped them. `Context.compress/2` reclaims the images
  of old tool results (with a marker) before it rewrites any content or drops
  any exchange, and the OpenAI formatter reads `image_count` exactly as it read
  the images themselves.
  """
  use ExUnit.Case, async: true

  alias SwarmCode.Domain.Engine.Context
  alias SwarmCode.Domain.LLM.{Anthropic, OpenAI}

  defp image(n), do: %{mime: "image/png", data: "iVBORw0K#{n}", tokens: 1_334}

  # 8 screenshot exchanges, then 8 recent messages the first pass never touches.
  defp history do
    shots =
      Enum.flat_map(1..8, fn n ->
        [
          %{
            role: "assistant",
            content: "",
            tool_calls: [%{id: "c#{n}", name: "mcp__b__shot", args: %{}}]
          },
          %{
            role: "tool",
            tool_call_id: "c#{n}",
            name: "mcp__b__shot",
            content: "shot #{n}",
            images: [image(n)]
          }
        ]
      end)

    recent =
      for n <- 1..8,
          do: %{role: if(rem(n, 2) == 0, do: "assistant", else: "user"), content: "recent #{n}"}

    Enum.map([%{role: "user", content: "take screenshots"} | shots] ++ recent, &Context.count/1)
  end

  test "old screenshots are reclaimed before any exchange is dropped" do
    messages = history()
    before = Context.estimate_tokens(messages)
    assert before > 10_000

    compressed = Context.compress(messages, 1_500)
    after_ = Context.estimate_tokens(compressed)

    assert after_ < 1_500, "estimate #{before} → #{after_}"
    assert length(compressed) == length(messages)
    refute Enum.any?(compressed, &Map.has_key?(&1, :images))

    tool = Enum.find(compressed, &(&1[:tool_call_id] == "c1"))
    assert tool.content == "shot 1\n[1 image(s) omitted — take a new screenshot if needed]"

    # A second pass changes nothing (idempotent, so the prefix stays stable).
    assert Context.compress(compressed, 1_500) == compressed
  end

  test "only as many as the budget needs go, oldest first" do
    compressed = Context.compress(history(), 5_000)

    assert Context.estimate_tokens(compressed) <= 5_000
    kept = for m <- compressed, Map.has_key?(m, :images), do: m.tool_call_id
    assert kept != [] and length(kept) < 8
    assert kept == Enum.map((9 - length(kept))..8, &"c#{&1}")
  end

  test "a history under budget keeps its images" do
    messages = history()
    assert Context.compress(messages, 100_000) == messages
  end

  test "the OpenAI formatter reads image_count exactly as it read the images" do
    with_images = %{
      role: "tool",
      tool_call_id: "c1",
      content: "look",
      images: [image(1), image(2)]
    }

    with_count =
      with_images |> Map.delete(:images) |> Map.put(:image_count, 2)

    no_text = %{with_count | content: ""}

    assert OpenAI.format_messages(nil, [with_images]) == OpenAI.format_messages(nil, [with_count])

    assert [%{"content" => "[image omitted]\n[image omitted]"}] =
             OpenAI.format_messages(nil, [no_text])
  end

  test "Anthropic still sends the newest images; a counted result names them" do
    images = for n <- 1..7, do: image(n)
    call = %{role: "assistant", content: "", tool_calls: [%{id: "c1", name: "shot", args: %{}}]}
    tool = %{role: "tool", tool_call_id: "c1", content: "look", images: images}

    [_assistant, %{"content" => [%{"content" => blocks}]}] =
      Anthropic.format_messages([call, tool])

    assert Enum.count(blocks, &(&1["type"] == "image")) == 5

    counted = tool |> Map.delete(:images) |> Map.put(:image_count, 7)

    assert [_assistant, %{"content" => [%{"content" => "look\n[7 image(s) omitted]"}]}] =
             Anthropic.format_messages([call, counted])
  end
end
