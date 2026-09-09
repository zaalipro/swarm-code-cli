defmodule SwarmCode.Domain.Engine.Context do
  @moduledoc "Token estimation and history trimming."

  @budget 120_000
  # Messages this close to the end are never compressed — the model is usually
  # still working with them.
  @keep_recent 8
  @min_compress 200
  # Spec 51 §6.5: an image whose `:tokens` was never stamped (a steer built by
  # hand, an older persisted turn) is charged the provider's ceiling.
  @image_token_cap 4_784
  # Spec 51 §6.7: what is left of a tool result the second pass had to cut.
  @cut_keep 4_000
  @cut_suffix "chars); re-read a range if needed]"

  @doc "The trim budget in estimated tokens (spec 51 §6.6)."
  @spec budget() :: pos_integer()
  def budget, do: @budget

  @doc "The trim budget for `model` (spec 55 T18, 55a A12): 200 k / 1 M contexts minus the output and headroom."
  @spec budget(String.t() | nil) :: pos_integer()
  def budget(model) when is_binary(model) do
    cond do
      String.contains?(model, "[1m]") -> 900_000
      String.starts_with?(model, "claude") -> 160_000
      true -> @budget
    end
  end

  def budget(_model), do: @budget

  @doc """
  A conservative token estimate. Sakana task 12: images count too — a multimodal
  turn used to look free and blew the provider's real limit.
  """
  def estimate_tokens(messages) do
    Enum.sum(for m <- messages, do: m[:tokens] || tokens_of(m))
  end

  @doc """
  Stamps the message with its estimate under `:tokens` (spec 43 §1.4). The
  agent counts a message once, when it appends it; `estimate_tokens/1` then
  reads the number instead of JSON-encoding every tool call of every turn twice
  per LLM call. Anything that changes a message's payload counts it again.
  """
  @spec count(map()) :: map()
  def count(message), do: Map.put(message, :tokens, tokens_of(message))

  # Spec 51 §6.5: an image costs what the provider charges for it — the token
  # count `Attachments.image_tokens/2` read from its header — not
  # `base64_bytes / 4`. At the old rate one 1.5 MB screenshot was worth 500 781
  # tokens against a 120 000 budget, so `drop_groups/2` evicted every message
  # behind it: turn 1 sent 2 of 12 messages, and a steer with a screenshot
  # dropped the Lead's TASK.
  defp tokens_of(m), do: div(payload_bytes(m), 4) + image_tokens(m) + 4

  # Spec 30 §2: an assistant turn carrying provider continuation blocks is
  # *sent* as those blocks — they already contain its text and tool inputs, plus
  # the thinking the user never sees. Counting them beside the content would
  # charge the same turn twice and evict history that still fits.
  defp payload_bytes(%{provider_blocks: [_ | _] = blocks}), do: byte_size(Jason.encode!(blocks))

  defp payload_bytes(m) do
    content = to_string(m[:content] || "")
    byte_size(content) + byte_size(Jason.encode!(m[:tool_calls] || []))
  end

  defp image_tokens(message) do
    message
    |> Map.get(:images)
    |> List.wrap()
    |> Enum.reduce(0, fn image, acc -> acc + (image[:tokens] || @image_token_cap) end)
  end

  @doc """
  Fits `messages` into `budget` estimated tokens.

  Old tool output is compressed first (its content is replaced by a short
  placeholder, oldest first) so the conversation structure survives; only when
  that is not enough are whole messages dropped from the front, as before.

  Spec 53b §4: dropping is from the **oldest end only** (`drop_oldest/2` →
  `drop_groups/2` walks the front), which is the one removal preserved thinking
  permits — "removing a leading run of thinking blocks, oldest first". The
  compression pass does rewrite tool results in the middle of the history, which
  is a history edit, but it is idempotent and its output is written back into the
  agent's state, so it costs one prefix mismatch and one cache reset the first
  time it fires per agent rather than one per request. The documented
  replacement is server-side context editing, which needs a beta this client
  does not send yet.
  """
  def trim(messages, budget \\ @budget) do
    messages |> compress(budget) |> drop_oldest(budget)
  end

  @doc "Replaces the content of old tool messages with a placeholder until under budget."
  def compress(messages, budget \\ @budget) do
    total = estimate_tokens(messages)

    if total <= budget do
      messages
    else
      cutoff = max(length(messages) - @keep_recent, 0)

      {compressed, _total} =
        messages
        |> Enum.with_index()
        |> Enum.map_reduce(total, fn {message, index}, total ->
          if total > budget and index < cutoff and compressible?(message) do
            replaced = message |> Map.put(:content, placeholder(message[:content])) |> count()
            {replaced, total - saving(message[:content], replaced[:content])}
          else
            {message, total}
          end
        end)

      cut_recent(compressed, budget, cutoff)
    end
  end

  # Spec 51 §6.7: six `web_fetch`es at the 100 000-char tool cap in one turn put
  # the next request at ~150 k tokens — over the budget with nothing left to
  # compress, because the first pass never touches the last `@keep_recent`
  # messages and `drop_groups/2` never drops the final exchange. The worker
  # failed and the swarm lost the work. So: the biggest recent tool results are
  # cut, largest first, until it fits. The assistant message that carries the
  # `tool_calls` is never touched — both providers reject a result whose call is
  # gone — and a content that already ends with the marker is skipped, so a
  # second `compress/2` is a no-op.
  defp cut_recent(messages, budget, cutoff) do
    if estimate_tokens(messages) <= budget do
      messages
    else
      messages
      |> Enum.with_index()
      |> Enum.filter(fn {message, index} -> index >= cutoff and cuttable?(message) end)
      |> Enum.sort_by(fn {message, _index} -> -byte_size(message[:content]) end)
      |> Enum.reduce_while(messages, fn {_message, index}, acc ->
        if estimate_tokens(acc) <= budget do
          {:halt, acc}
        else
          {:cont, List.update_at(acc, index, &cut/1)}
        end
      end)
    end
  end

  defp cuttable?(message) do
    message[:role] == "tool" and is_binary(message[:content]) and
      String.length(message[:content]) > @cut_keep and
      not String.ends_with?(message[:content], @cut_suffix)
  end

  defp cut(message) do
    content = message[:content]

    cut =
      String.slice(content, 0, @cut_keep) <>
        "…[tool output cut to fit the context (#{String.length(content)} " <> @cut_suffix

    message |> Map.put(:content, cut) |> count()
  end

  defp compressible?(message) do
    message[:role] == "tool" and is_binary(message[:content]) and
      byte_size(message[:content]) > @min_compress and
      not String.starts_with?(message[:content], "[tool output omitted")
  end

  defp placeholder(content) do
    "[tool output omitted (#{String.length(content)} chars) — re-read the file if needed]"
  end

  defp saving(old, new), do: div(byte_size(old) - byte_size(new), 4)

  # Sakana task 12: dropping one message at a time could cut an assistant
  # message with `tool_calls` away from its results, and both providers reject a
  # tool result whose call is gone. History is grouped into atomic exchanges
  # first, and whole exchanges are dropped from the front.
  defp drop_oldest(messages, budget) do
    groups =
      messages
      |> group()
      |> Enum.map(&{&1, estimate_tokens(&1), length(&1)})

    total = Enum.sum(for {_group, tokens, _count} <- groups, do: tokens)
    count = Enum.sum(for {_group, _tokens, messages} <- groups, do: messages)

    groups
    |> drop_groups({budget, total, count})
    |> Enum.concat()
    |> drop_leading_orphans()
  end

  defp drop_groups([], _state), do: []

  defp drop_groups([{_group, tokens, count} | rest] = groups, {budget, total, remaining}) do
    behind = remaining - count

    # Never drop below the two most recent messages, as before.
    if total > budget and behind >= 2 do
      drop_groups(rest, {budget, total - tokens, behind})
    else
      Enum.map(groups, &elem(&1, 0))
    end
  end

  @doc """
  History as atomic exchanges: an assistant message carrying `tool_calls`
  together with the contiguous tool results that answer it; everything else is
  a group of one.
  """
  @spec group([map()]) :: [[map()]]
  def group([]), do: []

  def group([message | rest]) do
    if calls?(message) do
      {results, tail} = Enum.split_while(rest, &(&1[:role] == "tool"))
      [[message | results] | group(tail)]
    else
      [[message] | group(rest)]
    end
  end

  defp calls?(message) do
    message[:role] == "assistant" and is_list(message[:tool_calls]) and message[:tool_calls] != []
  end

  defp drop_leading_orphans([%{role: "tool"} | rest]), do: drop_leading_orphans(rest)
  defp drop_leading_orphans(messages), do: messages
end
