defmodule SwarmCode.LLM.Anthropic do
  @moduledoc """
  Client for the Anthropic Messages API: event-typed SSE streaming, `tool_use` block
  assembly, cumulative usage, model listing.
  """
  @behaviour SwarmCode.LLM.Provider

  alias SwarmCode.LLM.{Chunks, HTTP, Request, Result, SSE, ToolArgs}

  @anthropic_version "2023-06-01"

  @impl true
  def stream(%Request{} = r, on_event) do
    HTTP.with_deadline(r.deadline_ms, fn -> do_stream(r, on_event) end)
  end

  defp do_stream(%Request{} = r, on_event) do
    case attempt(r, on_event) do
      {:error, message} = error ->
        cond do
          # Spec 30 §1.4: the request carried continuation state the server would
          # not take (a trimmed history, a model without extended thinking, an
          # older gateway). Rather than fail the turn, drop the state and the
          # thinking parameter and ask once more — the same shape as the
          # OpenAI-compatible `reasoning_effort` fallback.
          thinking_rejected?(message, r) ->
            SwarmCode.LLM.on_retry(on_event).(1, 1, "continuation state", true)
            attempt(without_thinking(r), on_event)

          # Spec 51 §6.4: a gateway in front of the Messages API that does not
          # know `cache_control` 400s on it. Ask once more without the markers,
          # and remember that for the rest of this op's calls the way
          # `remember_no_effort/1` does on the OpenAI side.
          cache_rejected?(message, r) ->
            Process.put(no_cache_key(r.provider), true)
            SwarmCode.LLM.on_retry(on_event).(1, 1, "prompt cache", true)
            attempt(r, on_event)

          # Spec 53b §3: same shape for the server-side fallback beta.
          # A gateway that does not know `fallbacks` must not cost the turn.
          fallback_rejected?(message, r) ->
            Process.put(no_fallback_key(r.provider), true)
            SwarmCode.LLM.on_retry(on_event).(1, 1, "refusal fallback", true)
            attempt(r, on_event)

          true ->
            error
        end

      ok ->
        ok
    end
  end

  @doc false
  # Spec 51 §6.4: the "this server does not do prompt caching" flag is per
  # provider row, in the process dictionary of the op task that makes the call.
  def no_cache_key(%{id: id}), do: {:sc_no_cache, id}
  def no_cache_key(_provider), do: {:sc_no_cache, nil}

  defp cache?(%Request{provider: provider}), do: Process.get(no_cache_key(provider)) != true

  @doc false
  def cache_rejected?(message, %Request{} = r) do
    text = String.downcase(to_string(message))

    cache?(r) and String.contains?(text, "400") and String.contains?(text, "cache_control")
  end

  @doc false
  def thinking_rejected?(message, %Request{} = r) do
    text = String.downcase(to_string(message))

    (r.effort != nil or Enum.any?(r.messages, &(Map.get(&1, :provider_blocks, []) != []))) and
      String.contains?(text, "400") and String.contains?(text, "thinking")
  end

  defp without_thinking(%Request{} = r) do
    %{r | effort: nil, messages: Enum.map(r.messages, &Map.delete(&1, :provider_blocks))}
  end

  defp attempt(%Request{} = r, on_event) do
    on_event = on_event || fn _ -> :ok end
    name = r.provider.name
    url = base_url(r.provider) <> "/v1/messages"

    headers =
      [
        {"x-api-key", key(r.provider)},
        {"anthropic-version", @anthropic_version},
        {"content-type", "application/json"}
      ] ++ beta_headers(r)

    # Spec 53b §1: `temperature`/`top_p`/`top_k` are rejected outright
    # from Opus 4.7 on (Opus 5, Fable 5.1), so the sampling fields go on the body
    # by *model wire shape*, never unconditionally. Before this the only thing
    # that removed them was an effort level's `drop` list, which
    # `Efforts.apply/2` skips entirely for `%Request{effort: nil}` — so the
    # label request, the watchdog probe and the `without_thinking/1` retry all
    # 400'd on a current model.
    body =
      %{
        "model" => r.model,
        "max_tokens" => r.max_tokens,
        "messages" => r.messages |> format_messages() |> mark_last_block(cache?(r)),
        "stream" => true
      }
      |> put_sampling(r)
      |> put_thinking(r)
      |> put_fallbacks(r)

    body = if blank?(r.system), do: body, else: Map.put(body, "system", system_block(r))
    body = if r.tools == [], do: body, else: Map.put(body, "tools", format_tools(r.tools))

    init = %{
      sse: "",
      text: Chunks.new(),
      reasoning: Chunks.new(),
      # `blocks` holds the one content block that is open right now, by index;
      # `done_blocks` and `done_calls` are built newest-first and reversed once
      # (spec 30 §4).
      blocks: %{},
      done_blocks: [],
      done_calls: [],
      thinking?: false,
      signed?: true,
      usage: %{input: 0, output: 0, cache_read: 0, cache_write: 0},
      stop: nil,
      # Spec 53b §3: the refusal category rides beside the stop reason.
      stop_details: nil,
      error: nil,
      # Spec 51 §6.1: the `type` of an in-band `error` event decides whether the
      # 200 that carried it is retried.
      error_type: nil,
      # spec 55 T13 (55a A1): set by message_stop; a 200 without it is retried.
      completed?: false
    }

    on_chunk = fn data, acc -> handle_chunk(data, acc, on_event, name) end

    case HTTP.stream_post(
           url,
           headers,
           body,
           name,
           init,
           on_chunk,
           SwarmCode.LLM.on_retry(on_event),
           &retry_if/1,
           r.deadline_ms
         ) do
      # Spec 51 §6.10: this text becomes the op's `error` and the run's message.
      # Redact it with the key the client actually sent, not only with the
      # `sk-`/`Bearer` shapes `redact/1` can guess at.
      {:ok, %{error: error}} when is_binary(error) -> {:error, redact(error, r)}
      {:ok, acc} -> {:ok, to_result(acc, r.model)}
      {:error, message} -> {:error, redact(message, r)}
    end
  end

  defp redact(message, %Request{} = r), do: HTTP.redact(message, [key(r.provider)])

  @doc """
  The sampling fields (spec 53b §1).

  `temperature` exists only on the legacy (pre-4.6) wire shape. Opus 4.7 and
  every model after it — Opus 5, Fable 5.1 — return a 400 for
  `temperature`/`top_p`/`top_k`, whatever the effort level is, so they are put
  on the body by model rather than removed by an effort level's `drop` list.
  """
  @spec put_sampling(map(), Request.t()) :: map()
  def put_sampling(body, %Request{} = r) do
    case thinking_mode(r.model) do
      :legacy -> Map.put(body, "temperature", r.temperature)
      :adaptive -> body
    end
  end

  # Spec 51 §6.1: the Messages API documents `overloaded_error` as an event
  # inside a 200 stream — the capacity blip that used to cost an eight-worker
  # swarm every worker's history. What the API calls the caller's fault
  # (`invalid_request_error`, `authentication_error`, `permission_error`,
  # `not_found_error`) comes straight back.
  #
  # spec 55 T13 (55a A1): the body ended before `message_stop` — a proxy idle-timeout or a
  # dropped connection, not an answer. Same in-band retry as an overloaded_error.
  defp retry_if(%{error: nil, completed?: false}), do: {:retry, "stream ended early"}

  defp retry_if(%{error_type: type}) when type in ["overloaded_error", "api_error"],
    do: {:retry, "server"}

  defp retry_if(%{error_type: "rate_limit_error"}), do: {:retry, "rate limit"}
  defp retry_if(_acc), do: :ok

  @impl true
  def list_models(provider) do
    url = base_url(provider) <> "/v1/models"
    headers = [{"x-api-key", key(provider)}, {"anthropic-version", @anthropic_version}]

    case HTTP.get_json(url, headers, provider.name) do
      {:ok, %{"data" => data}} when is_list(data) ->
        {:ok, for(m <- data, is_map(m), is_binary(m["id"]), do: m["id"])}

      {:ok, _body} ->
        {:error, "unexpected models response"}

      {:error, message} ->
        {:error, HTTP.redact(message, [key(provider)])}
    end
  end

  @doc """
  Reasoning effort on the Messages API wire — the request's level merged into
  the body (spec 45 §3.4, `SwarmCode.LLM.Efforts.apply/2`).

  The built-in defaults: current Claude models (4.6 and newer, Claude 5, and
  every unknown/future model id) take adaptive thinking — `thinking: {"type":
  "adaptive", "display": "summarized"}` plus `output_config: {"effort": level}`
  and a `max_tokens` floor (spec 53b §2) — and reject the sampling fields, so
  `temperature`/`top_p`/`top_k` are dropped. Known pre-4.6 families keep the
  legacy fixed budget: `thinking: {"type": "enabled", "budget_tokens": n}` with
  `max_tokens` inflated to leave room for the answer on top of the budget.
  `thinking_mode/1` and `budget/1` are what those defaults are built from.

  Whatever the level produced then goes through `sanitise_thinking/2`, which
  takes off the two shapes the target models answer with a 400.
  """
  @spec put_thinking(map(), Request.t()) :: map()
  def put_thinking(body, %Request{} = r),
    do: body |> SwarmCode.LLM.Efforts.apply(r) |> sanitise_thinking(r.model)

  # Spec 53b §2: whatever the level list produced, two shapes are a
  # documented 400 on the target models and neither can ever help, so they are
  # taken back off here rather than trusted to the row that configured them.
  #
  #   * Fable/Mythos think always. `{"type": "disabled"}` and
  #     `{"type": "enabled", "budget_tokens": n}` are both rejected; removing
  #     the key leaves the always-on adaptive default.
  #   * On any adaptive-wire model, disabled thinking above `high` effort is
  #     rejected (Opus 5 breaking change 2). The guide's own preference is to
  #     let it think rather than to lower the effort, which is what dropping
  #     the key does.
  #
  # A legacy (pre-4.6) body is passed through untouched.
  defp sanitise_thinking(%{"thinking" => %{"type" => type}} = body, model) do
    cond do
      thinking_mode(model) == :legacy -> body
      always_thinking?(model) and type != "adaptive" -> Map.delete(body, "thinking")
      type == "disabled" and effort_of(body) in ["xhigh", "max"] -> Map.delete(body, "thinking")
      true -> body
    end
  end

  defp sanitise_thinking(body, _model), do: body

  defp effort_of(%{"output_config" => %{"effort" => effort}}) when is_binary(effort), do: effort
  defp effort_of(_body), do: nil

  @doc """
  True for the model families whose thinking is always on and whose only legal
  `thinking` value is `{"type": "adaptive"}` — `claude-fable-*` and
  `claude-mythos-*` (spec 53b §2).
  """
  @spec always_thinking?(String.t() | nil) :: boolean()
  def always_thinking?(model) when is_binary(model) do
    id = String.downcase(model)
    String.starts_with?(id, "claude-fable-") or String.starts_with?(id, "claude-mythos-")
  end

  def always_thinking?(_model), do: false

  # ------------------------------------------------- server-side fallbacks §3

  @fallback_beta "server-side-fallback-2026-07-01"

  @doc """
  True for the model families the Messages API accepts `fallbacks` for
  (spec 53b §3): Claude Opus 5, Claude Fable 5.x, Claude Mythos 5.x.
  Anything older or unknown is left alone — an unknown parameter is a 400 on a
  strict gateway and there is nothing to gain.
  """
  @spec fallback_family?(String.t() | nil) :: boolean()
  def fallback_family?(model) when is_binary(model) do
    id = String.downcase(model)

    String.starts_with?(id, "claude-opus-5") or String.starts_with?(id, "claude-fable-5") or
      String.starts_with?(id, "claude-mythos-5")
  end

  def fallback_family?(_model), do: false

  @doc false
  # The "this server does not know `fallbacks`" flag, per provider row, in the
  # process dictionary of the op task — the same shape as `no_cache_key/1`.
  def no_fallback_key(%{id: id}), do: {:sc_no_fallback, id}
  def no_fallback_key(_provider), do: {:sc_no_fallback, nil}

  @doc """
  Whether this request carries `fallbacks: "default"` (spec 53b §3):
  the provider row's toggle (default on), a model family the API accepts it
  for, and no 400 about it earlier in this op.
  """
  @spec fallbacks?(Request.t()) :: boolean()
  def fallbacks?(%Request{provider: provider, model: model}) do
    Map.get(provider || %{}, :fallbacks, true) != false and fallback_family?(model) and
      Process.get(no_fallback_key(provider)) != true
  end

  # A refusal is a 200, not an error — the server re-runs the declined request
  # on Anthropic's recommended substitute and returns its answer instead. The
  # scalar `"default"` form is preferred over pinning a model: routing is per
  # refusal category, and a pinned target is a migration owed later.
  defp put_fallbacks(body, %Request{} = r) do
    if fallbacks?(r), do: Map.put(body, "fallbacks", "default"), else: body
  end

  defp beta_headers(%Request{} = r) do
    if fallbacks?(r), do: [{"anthropic-beta", @fallback_beta}], else: []
  end

  @doc false
  def fallback_rejected?(message, %Request{} = r) do
    text = String.downcase(to_string(message))

    fallbacks?(r) and String.contains?(text, "400") and
      (String.contains?(text, "fallback") or String.contains?(text, @fallback_beta))
  end

  @doc """
  Which thinking wire shape a model id takes.

  `:legacy` only for model ids that name a known pre-4.6 family (`claude-3*`,
  `claude-opus-4*`/`claude-sonnet-4*`/`claude-haiku-4*` up to minor 5). Anything
  else — including every unknown or future id — is `:adaptive`.
  """
  @spec thinking_mode(String.t() | nil) :: :adaptive | :legacy
  def thinking_mode(model) when is_binary(model) do
    id = String.downcase(model)

    cond do
      String.starts_with?(id, "claude-3") ->
        :legacy

      true ->
        # A trailing date snapshot (`claude-opus-4-20250514`) is not a minor
        # version, hence the one-or-two-digit group with a no-more-digits guard.
        case Regex.run(~r/^claude-(?:opus|sonnet|haiku)-(\d+)(?:-(\d{1,2})(?!\d))?/, id) do
          [_, major, minor] -> version_mode(String.to_integer(major), String.to_integer(minor))
          [_, major] -> version_mode(String.to_integer(major), 0)
          _ -> :adaptive
        end
    end
  end

  def thinking_mode(_model), do: :adaptive

  defp version_mode(major, _minor) when major < 4, do: :legacy
  defp version_mode(4, minor) when minor < 6, do: :legacy
  defp version_mode(_major, _minor), do: :adaptive

  @doc "Legacy (pre-4.6) thinking budget in tokens per effort level."
  def budget("low"), do: 1024
  def budget("medium"), do: 4096
  def budget("high"), do: 16_000
  def budget("max"), do: 32_000
  def budget(_other), do: 4096

  @doc """
  Maps messages to the Messages API format; consecutive `"tool"` messages are merged
  into one user message holding all their `tool_result` blocks, in order.
  """
  @spec format_messages([map()]) :: [map()]
  def format_messages(messages) do
    messages |> Enum.reduce([], &add_message/2) |> Enum.reverse()
  end

  # Spec 51 §6.4: prompt caching. 90.9 % of every input token this app has ever
  # sent was a re-send of the previous call's prefix — the system prompt and the
  # tool specs are written once per agent and the history only grows at the end.
  # Two breakpoints do it: one after the system prompt, one on the last content
  # block of the last message, which is the whole prefix of the *next* turn.
  @ephemeral %{"type" => "ephemeral"}

  @doc """
  The `system` field: one text block carrying the cache breakpoint (spec 51 §6.4),
  or the plain string once this provider has 400'd on `cache_control`.
  """
  @spec system_block(Request.t()) :: [map()] | String.t()
  def system_block(%Request{} = r) do
    if cache?(r) do
      [%{"type" => "text", "text" => r.system, "cache_control" => @ephemeral}]
    else
      r.system
    end
  end

  @doc """
  Puts the cache breakpoint on the last content block of the last message
  (spec 51 §6.4).

  A string `content` becomes a one-element text block so it can carry the
  marker; a `tool_result` block takes it as it is. An empty string is left
  alone — the Messages API rejects an empty text block.
  """
  @spec mark_last_block([map()], boolean()) :: [map()]
  def mark_last_block(messages, cache? \\ true)
  def mark_last_block(messages, false), do: messages
  def mark_last_block([], _cache?), do: []

  def mark_last_block(messages, true) do
    {init, [last]} = Enum.split(messages, -1)
    init ++ [%{last | "content" => mark_content(last["content"])}]
  end

  defp mark_content(""), do: ""

  defp mark_content(content) when is_binary(content),
    do: [%{"type" => "text", "text" => content, "cache_control" => @ephemeral}]

  defp mark_content([_ | _] = blocks) do
    {init, [last]} = Enum.split(blocks, -1)
    init ++ [Map.put(last, "cache_control", @ephemeral)]
  end

  defp mark_content(other), do: other

  @doc "Maps tool specs to Anthropic tools (`input_schema` instead of `parameters`)."
  @spec format_tools([map()]) :: [map()]
  def format_tools(tools) do
    Enum.map(tools, fn tool ->
      %{"name" => tool.name, "description" => tool.description, "input_schema" => tool.parameters}
    end)
  end

  defp add_message(%{role: "tool"} = m, [%{"role" => "user", "content" => blocks} = last | rest])
       when is_list(blocks) do
    [%{last | "content" => blocks ++ [tool_result(m)]} | rest]
  end

  defp add_message(%{role: "tool"} = m, acc) do
    [%{"role" => "user", "content" => [tool_result(m)]} | acc]
  end

  # A steered user message can land right after tool results; the Messages API
  # wants one user turn, so consecutive user messages are merged.
  defp add_message(%{role: "user"} = m, [%{"role" => "user", "content" => blocks} = last | rest])
       when is_list(blocks) do
    [%{last | "content" => blocks ++ user_blocks(m)} | rest]
  end

  defp add_message(%{role: "user"} = m, [%{"role" => "user", "content" => text} = last | rest])
       when is_binary(text) do
    case Map.get(m, :images) || [] do
      [] ->
        [%{last | "content" => text <> "\n\n" <> (Map.get(m, :content) || "")} | rest]

      _images ->
        [%{last | "content" => [%{"type" => "text", "text" => text}] ++ user_blocks(m)} | rest]
    end
  end

  defp add_message(%{role: "user"} = m, acc) do
    case Map.get(m, :images) || [] do
      [] -> [%{"role" => "user", "content" => Map.get(m, :content) || ""} | acc]
      _images -> [%{"role" => "user", "content" => user_blocks(m)} | acc]
    end
  end

  defp add_message(%{role: "assistant"} = m, acc) do
    case assistant_blocks(m) do
      [] -> acc
      blocks -> [%{"role" => "assistant", "content" => blocks} | acc]
    end
  end

  defp add_message(%{role: role} = m, acc) do
    [%{"role" => role, "content" => Map.get(m, :content) || ""} | acc]
  end

  defp user_blocks(m) do
    text = Map.get(m, :content) || ""
    text_blocks = if text == "", do: [], else: [%{"type" => "text", "text" => text}]

    image_blocks =
      for image <- Map.get(m, :images) || [] do
        %{
          "type" => "image",
          "source" => %{"type" => "base64", "media_type" => image.mime, "data" => image.data}
        }
      end

    case text_blocks ++ image_blocks do
      [] -> [%{"type" => "text", "text" => ""}]
      blocks -> blocks
    end
  end

  # The provider's own blocks win: they are the turn Anthropic sent, signatures
  # and all, and the Messages API wants them back unaltered (spec 30 §1).
  defp assistant_blocks(%{provider_blocks: [_ | _] = blocks}), do: blocks

  defp assistant_blocks(m) do
    content = Map.get(m, :content)
    text = if blank?(content), do: [], else: [%{"type" => "text", "text" => content}]

    tool_use =
      for call <- Map.get(m, :tool_calls) || [] do
        %{"type" => "tool_use", "id" => call.id, "name" => call.name, "input" => call.args || %{}}
      end

    text ++ tool_use
  end

  defp tool_result(m) do
    %{
      "type" => "tool_result",
      "tool_use_id" => Map.get(m, :tool_call_id),
      "content" => Map.get(m, :content) || "",
      "is_error" => Map.get(m, :is_error) == true
    }
  end

  defp handle_chunk(data, acc, on_event, name) do
    {events, rest} = SSE.parse(acc.sse, data)

    Enum.reduce(events, %{acc | sse: rest}, fn event, acc ->
      handle_event(event.data, acc, on_event, name)
    end)
  end

  defp handle_event(data, acc, on_event, name) do
    case Jason.decode(data) do
      {:ok, %{} = json} ->
        apply_event(json["type"], json, acc, on_event, name)

      _other ->
        %{acc | error: "#{name} invalid JSON in SSE event", error_type: "invalid_response"}
    end
  end

  # Spec 51 §6.4: a cached prefix is billed under two other counters, so
  # `input_tokens` alone would report a 6 k prompt as 300. `input` stays "the
  # size of the prompt" — the sum of the three — and the two cache counters ride
  # beside it; cost is charged at the input rate for the whole sum.
  defp apply_event("message_start", json, acc, _on_event, _name) do
    usage = get_in(json, ["message", "usage"]) || %{}
    read = count(usage["cache_read_input_tokens"])
    write = count(usage["cache_creation_input_tokens"])

    %{
      acc
      | usage: %{
          acc.usage
          | input: count(usage["input_tokens"]) + read + write,
            cache_read: read,
            cache_write: write
        },
        # A classifier that declines before any output can name the reason on
        # the opening message; `message_delta` wins when both carry it.
        stop: get_in(json, ["message", "stop_reason"]) || acc.stop,
        stop_details: details(get_in(json, ["message", "stop_details"])) || acc.stop_details
    }
  end

  defp apply_event("content_block_start", json, acc, _on_event, _name) do
    block = json["content_block"] || %{}
    index = json["index"]

    case block["type"] do
      "tool_use" ->
        open(acc, index, %{
          type: :tool_use,
          id: block["id"],
          name: block["name"],
          json: Chunks.new()
        })

      "text" ->
        open(acc, index, %{type: :text, text: chunks(block["text"])})

      "thinking" ->
        open(acc, index, %{
          type: :thinking,
          text: chunks(block["thinking"]),
          signature: chunks(block["signature"])
        })

      "redacted_thinking" ->
        open(acc, index, %{type: :redacted_thinking, data: to_string(block["data"] || "")})

      _other ->
        acc
    end
  end

  defp apply_event("content_block_delta", json, acc, on_event, _name) do
    delta = json["delta"] || %{}

    index = json["index"]

    case delta["type"] do
      "text_delta" ->
        acc |> append_text(delta["text"], on_event) |> append_block(index, :text, delta["text"])

      "thinking_delta" ->
        acc
        |> append_reasoning(delta["thinking"], on_event)
        |> append_block(index, :text, delta["thinking"])

      # Never shown and never persisted: the signature only travels back to
      # Anthropic beside the thinking it signs.
      "signature_delta" ->
        append_block(acc, index, :signature, delta["signature"])

      "input_json_delta" ->
        append_json(acc, index, delta["partial_json"])

      _other ->
        acc
    end
  end

  defp apply_event("content_block_stop", json, acc, _on_event, _name) do
    index = json["index"]

    case Map.pop(acc.blocks, index) do
      {nil, _blocks} -> acc
      {block, blocks} -> close_block(%{acc | blocks: blocks}, index, block)
    end
  end

  # Spec 51 §6.3: no `{:usage, …}` event — nothing acted on it, and the agent
  # reads `Result.usage` when the op is done.
  defp apply_event("message_delta", json, acc, _on_event, _name) do
    stop = get_in(json, ["delta", "stop_reason"]) || acc.stop
    output = get_in(json, ["usage", "output_tokens"])
    usage = %{acc.usage | output: if(is_integer(output), do: output, else: acc.usage.output)}
    details = details(get_in(json, ["delta", "stop_details"])) || acc.stop_details
    %{acc | stop: stop, stop_details: details, usage: usage}
  end

  defp apply_event("error", json, acc, _on_event, name) do
    message = get_in(json, ["error", "message"]) || "unknown error"

    %{
      acc
      | error: "#{name} stream error: " <> HTTP.redact(message),
        # Spec 51 §6.1: `retry_if/1` reads the type, not the prose.
        error_type: get_in(json, ["error", "type"])
    }
  end

  # spec 55 T13 (55a A1): the terminal event; only after it is the 200 an answer.
  defp apply_event("message_stop", _json, acc, _on_event, _name), do: %{acc | completed?: true}

  defp apply_event(_type, _json, acc, _on_event, _name), do: acc

  defp open(acc, index, entry), do: %{acc | blocks: Map.put(acc.blocks, index, entry)}

  defp chunks(nil), do: Chunks.new()
  defp chunks(text) when is_binary(text), do: Chunks.new(text)
  defp chunks(_other), do: Chunks.new()

  defp append_block(acc, index, field, text) when is_binary(text) and text != "" do
    case Map.fetch(acc.blocks, index) do
      {:ok, block} when is_map_key(block, field) ->
        entry = Map.put(block, field, Chunks.append(Map.fetch!(block, field), text))
        %{acc | blocks: Map.put(acc.blocks, index, entry)}

      _other ->
        acc
    end
  end

  defp append_block(acc, _index, _field, _text), do: acc

  defp close_block(acc, index, %{type: :tool_use} = block) do
    raw = Chunks.to_string(block.json)
    base = %{id: block.id || "toolu_#{index}", name: block.name || ""}

    call =
      case ToolArgs.decode(raw) do
        {:ok, args} ->
          Map.put(base, :args, args)

        {:error, reason} ->
          Map.merge(base, %{args: %{}, args_error: reason, args_raw: raw})
      end

    wire = %{
      "type" => "tool_use",
      "id" => call.id,
      "name" => call.name,
      "input" => call.args
    }

    %{acc | done_calls: [call | acc.done_calls], done_blocks: [wire | acc.done_blocks]}
  end

  defp close_block(acc, _index, %{type: :text} = block) do
    case Chunks.to_string(block.text) do
      # The Messages API rejects an empty text block, so an empty one is simply
      # not part of the continuation state.
      "" -> acc
      text -> %{acc | done_blocks: [%{"type" => "text", "text" => text} | acc.done_blocks]}
    end
  end

  defp close_block(acc, _index, %{type: :thinking} = block) do
    signature = Chunks.to_string(block.signature)

    wire = %{
      "type" => "thinking",
      "thinking" => Chunks.to_string(block.text),
      "signature" => signature
    }

    %{
      acc
      | done_blocks: [wire | acc.done_blocks],
        thinking?: true,
        # An unsigned thinking block cannot be sent back, and a partial set is
        # worse than none: the whole turn falls back to the plain formatter.
        signed?: acc.signed? and signature != ""
    }
  end

  defp close_block(acc, _index, %{type: :redacted_thinking} = block) do
    wire = %{"type" => "redacted_thinking", "data" => block.data}
    %{acc | done_blocks: [wire | acc.done_blocks], thinking?: true}
  end

  defp append_text(acc, text, on_event) when is_binary(text) and text != "" do
    on_event.({:text_delta, text})
    %{acc | text: Chunks.append(acc.text, text)}
  end

  defp append_text(acc, _text, _on_event), do: acc

  # `thinking` content blocks (extended thinking) stream as `thinking_delta`.
  defp append_reasoning(acc, text, on_event) when is_binary(text) and text != "" do
    on_event.({:reasoning_delta, text})
    %{acc | reasoning: Chunks.append(acc.reasoning, text)}
  end

  defp append_reasoning(acc, _text, _on_event), do: acc

  defp append_json(acc, index, partial) when is_binary(partial) do
    case Map.fetch(acc.blocks, index) do
      {:ok, block} ->
        %{
          acc
          | blocks:
              Map.put(acc.blocks, index, %{block | json: Chunks.append(block.json, partial)})
        }

      :error ->
        acc
    end
  end

  defp append_json(acc, _index, _partial), do: acc

  defp to_result(acc, model) do
    calls = Enum.reverse(acc.done_calls)

    %Result{
      text: Chunks.to_string(acc.text),
      reasoning: Chunks.to_string(acc.reasoning),
      tool_calls: calls,
      # Only a turn that actually thought needs its blocks back; every ordinary
      # turn keeps the existing formatter byte for byte.
      provider_blocks:
        if(acc.thinking? and acc.signed?, do: Enum.reverse(acc.done_blocks), else: []),
      usage: acc.usage,
      stop_reason: map_stop(acc.stop, calls),
      stop_details: acc.stop_details,
      model: model
    }
  end

  # Spec 53b §3: `refusal` is a 200 with an empty (pre-output) or
  # partial (mid-stream) body. Flattening it to "other" is what made a declined
  # request look like a finished turn that said nothing.
  defp map_stop(stop, _calls) when stop in ["end_turn", "tool_use", "max_tokens", "refusal"],
    do: stop

  defp map_stop(nil, []), do: "end_turn"
  defp map_stop(nil, _calls), do: "tool_use"
  defp map_stop(_other, _calls), do: "other"

  defp count(value) when is_integer(value), do: value
  defp count(_value), do: 0

  # Spec 53b §3: `stop_details` is informational and can be `null` even
  # on a real refusal, so anything that is not an object is simply absent.
  defp details(%{} = map), do: map
  defp details(_other), do: nil

  defp base_url(provider), do: String.trim_trailing(provider.base_url, "/")

  defp key(provider), do: provider.api_key || ""

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false
end
