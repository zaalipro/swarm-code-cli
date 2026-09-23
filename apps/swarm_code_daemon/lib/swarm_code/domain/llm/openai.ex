defmodule SwarmCode.Domain.LLM.OpenAI do
  @moduledoc """
  Client for every OpenAI-compatible `/chat/completions` server (llmotions included):
  streaming text deltas, tool calls assembled by `index`, usage capture, model listing.
  """
  @behaviour SwarmCode.Domain.LLM.Provider

  alias SwarmCode.Domain.LLM.{Chunks, Efforts, HTTP, Request, Result, SSE, ToolArgs}

  # Servers that rejected `reasoning_effort` or `prompt_cache_key` once are
  # remembered (`ProviderCaps`, ETS) for the rest of the session so every later
  # request skips the parameter (and the retry).

  @impl true
  def stream(%Request{} = r, on_event) do
    on_event = on_event || fn _ -> :ok end
    base = base_url(r.provider)
    url = base <> "/chat/completions"

    headers = [
      {"authorization", "Bearer " <> key(r.provider)},
      {"content-type", "application/json"}
    ]

    body = %{
      "model" => r.model,
      "messages" => format_messages(r.system, r.messages),
      "stream" => true,
      "stream_options" => %{"include_usage" => true},
      "max_tokens" => r.max_tokens,
      "temperature" => r.temperature
    }

    body = if r.tools == [], do: body, else: Map.put(body, "tools", format_tools(r.tools))
    body = put_effort(body, r)
    # spec 66 T18: prefix-cache affinity across a run.
    body = put_cache_key(body, r)

    post(body, url, headers, r, on_event)
  end

  defp post(body, url, headers, %Request{} = r, on_event) do
    init = %{
      sse: "",
      text: Chunks.new(),
      reasoning: Chunks.new(),
      calls: %{},
      usage: %{input: 0, output: 0, cache_read: 0},
      finish: nil,
      error: nil,
      # Spec 51 §6.1: the `code`/`status` of an in-band error object decides
      # whether the 200 that carried it is retried.
      error_code: nil,
      # spec 55 T13 (55a A1): set by a finish_reason or [DONE]; a 200 without it is retried.
      completed?: false
    }

    case HTTP.stream_post(
           url,
           headers,
           body,
           r.provider.name,
           init,
           &handle_chunk(&1, &2, on_event, r.provider.name),
           SwarmCode.Domain.LLM.on_retry(on_event),
           &retry_if/1,
           r.deadline_ms,
           # spec 67 T33 (G41): the row the rate-limit snapshot is filed under.
           provider_id(r)
         ) do
      # Spec 30 §3: a 200 whose stream carries an `error` object is a failed
      # call, not a short answer. It goes down the same path as a transport
      # error, so a server that names `reasoning_effort` in-band still gets the
      # existing one-shot retry without it.
      {:ok, %{error: message} = acc} when is_binary(message) ->
        settle_error(message, body, url, headers, r, on_event, in_band_kind(acc))

      {:ok, acc} ->
        {:ok, to_result(acc, r.model)}

      # spec 67 T30 (G42): the transport's kind survives the one-shot retries.
      {:error, kind, message} ->
        settle_error(message, body, url, headers, r, on_event, kind)

      {:error, message} ->
        settle_error(message, body, url, headers, r, on_event, nil)
    end
  end

  defp provider_id(%Request{provider: %{id: id}}) when is_binary(id), do: id
  defp provider_id(_request), do: nil

  # Spec 51 §6.1: the `code`/`status` of the in-band error object.
  defp in_band_kind(acc) do
    SwarmCode.Domain.LLM.Error.classify(
      status_code(acc[:error_code]),
      acc[:error_code],
      acc[:error]
    )
  end

  defp status_code(code) when is_integer(code), do: code

  defp status_code(code) when is_binary(code) do
    case Integer.parse(code) do
      {status, ""} -> status
      _other -> nil
    end
  end

  defp status_code(_code), do: nil

  defp settle_error(message, body, url, headers, %Request{} = r, on_event, kind) do
    # Older / smaller OpenAI-compatible servers 400 on `reasoning_effort`.
    # Drop the level's keys (spec 45 §3.4 — every key its body added, not only
    # `reasoning_effort`), remember that for this provider and try exactly
    # once more.
    keys = level_keys(r)

    cond do
      # spec 66 T18: the one-shot shape for a server that does not know
      # `prompt_cache_key`. It is an optimisation; it never costs a turn.
      # spec 67 B36: this arm is tested first, and each classifier below only
      # takes a generic "unknown parameter" when the message names none of the
      # other fields — a 400 about `prompt_cache_key` used to turn
      # `reasoning_effort` off for the provider for the whole session.
      Map.has_key?(body, "prompt_cache_key") and rejected_cache_key?(message, keys) ->
        remember_no_cache_key(r.provider)
        # Spec 43 §1.5 (B2): whatever the first attempt streamed before the error
        # object must not stay in front of the second answer — the Anthropic
        # provider resets the same way, and a reset with nothing streamed is a no-op.
        on_event.({:text_reset})
        on_event.({:reasoning_reset})
        post(Map.delete(body, "prompt_cache_key"), url, headers, r, on_event)

      keys != [] and Enum.any?(keys, &Map.has_key?(body, &1)) and
          rejected_effort?(message, keys) ->
        remember_no_effort(r.provider)
        on_event.({:text_reset})
        on_event.({:reasoning_reset})
        post(Map.drop(body, keys), url, headers, r, on_event)

      true ->
        # Spec 51 §6.10: this text becomes the op's `error` and the run's message.
        # A gateway that echoes the Authorization header back does not have to
        # have used an `sk-` shaped key for it to be a key.
        text = HTTP.redact(message, [key(r.provider)])
        {:error, kind || SwarmCode.Domain.LLM.Error.classify(nil, nil, text), text}
    end
  end

  @doc """
  spec 66 T18: `prompt_cache_key` keeps one agent's requests on one prefix cache
  for the whole run. Omitted when the request carries no key, and after a server
  has once refused it.
  """
  @spec put_cache_key(map(), Request.t()) :: map()
  def put_cache_key(body, %Request{cache_key: key} = r) when is_binary(key) and key != "" do
    if cache_key?(r.provider), do: Map.put(body, "prompt_cache_key", key), else: body
  end

  def put_cache_key(body, _request), do: body

  @doc "False once this provider has 400'd on `prompt_cache_key` in this session (spec 67 B37)."
  defdelegate cache_key?(provider), to: SwarmCode.Domain.LLM.ProviderCaps

  @doc false
  defdelegate remember_no_cache_key(provider), to: SwarmCode.Domain.LLM.ProviderCaps

  @doc false
  # `level_keys` are the keys the request's effort level put on the body
  # (spec 45 §3.4); a message naming one of them is about the level, not the key.
  def rejected_cache_key?(message, level_keys \\ []) do
    rejected_field?(message, ["prompt_cache_key"], ["reasoning_effort" | level_keys])
  end

  # spec 67 B36: "unknown parameter" / "unrecognized" are shared by every field a
  # server can refuse, so a classifier takes them only when the message names
  # none of the *other* fields this request may carry. Its own field name
  # always counts.
  @generic_rejections ["unknown parameter", "unrecognized"]

  defp rejected_field?(message, fields, other_fields) do
    text = String.downcase(to_string(message))
    names? = fn field -> String.contains?(text, field) end

    String.contains?(text, "400") and
      (Enum.any?(field_names(fields), names?) or
         (Enum.any?(@generic_rejections, names?) and
            not Enum.any?(field_names(other_fields), names?)))
  end

  defp field_names(fields) do
    for field <- fields, is_binary(field), field != "", do: String.downcase(field)
  end

  # Spec 51 §6.1: an OpenAI-compatible gateway answers 200 and then sends
  # `{"error": {"code": 429 | 502}}` — the same transient failure a status code
  # would have been retried for. Everything else keeps `settle_error/6`'s path.
  # spec 55 T13 (55a A1): the body ended before a finish_reason / [DONE] — a proxy
  # idle-timeout or a dropped connection, not an answer. Same in-band retry as a 5xx.
  defp retry_if(%{error: nil, completed?: false}), do: {:retry, "stream ended early"}

  defp retry_if(%{error_code: 429}), do: {:retry, "rate limit"}

  defp retry_if(%{error_code: code}) when is_integer(code) and code >= 500,
    do: {:retry, "server"}

  defp retry_if(_acc), do: :ok

  defp level_keys(%Request{} = r) do
    case Efforts.level(r) do
      %{"body" => body} when is_map(body) -> Map.keys(body)
      _none -> []
    end
  end

  @doc """
  Merges the request's effort level into the body (spec 45 §3.4) unless this
  provider already rejected it. The built-in defaults send `reasoning_effort`
  verbatim; `max` also raises the answer budget to 16 384.
  """
  def put_effort(body, %Request{} = r), do: Efforts.apply(body, r)

  @doc false
  # `level_keys` are the keys the request's effort level put on the body
  # (spec 45 §3.4): a message naming any of them is about the level.
  def rejected_effort?(message, level_keys \\ []) do
    rejected_field?(message, ["reasoning_effort" | level_keys], ["prompt_cache_key"])
  end

  @doc "False once this provider has 400'd on `reasoning_effort` in this session."
  defdelegate effort?(provider), to: SwarmCode.Domain.LLM.ProviderCaps

  @doc false
  defdelegate remember_no_effort(provider), to: SwarmCode.Domain.LLM.ProviderCaps

  @impl true
  def list_models(provider) do
    url = base_url(provider) <> "/models"

    case HTTP.get_json(url, [{"authorization", "Bearer " <> key(provider)}], provider.name) do
      {:ok, %{"data" => data}} when is_list(data) ->
        {:ok, for(m <- data, is_map(m), is_binary(m["id"]), do: m["id"])}

      {:ok, _body} ->
        {:error, "unexpected models response"}

      {:error, message} ->
        {:error, message}
    end
  end

  @doc "Prefixes the optional system message and maps every message to the wire format."
  @spec format_messages(String.t() | nil, [map()]) :: [map()]
  def format_messages(system, messages) do
    head = if blank?(system), do: [], else: [%{"role" => "system", "content" => system}]
    head ++ Enum.map(messages, &format_message/1)
  end

  @doc "Maps tool specs to OpenAI `function` tools."
  @spec format_tools([map()]) :: [map()]
  def format_tools(tools) do
    Enum.map(tools, fn tool ->
      %{
        "type" => "function",
        "function" => %{
          "name" => tool.name,
          "description" => tool.description,
          "parameters" => tool.parameters
        }
      }
    end)
  end

  defp format_message(%{role: "user"} = m) do
    case Map.get(m, :images) || [] do
      [] ->
        %{"role" => "user", "content" => Map.get(m, :content)}

      images ->
        text = Map.get(m, :content) || ""

        parts =
          if(text == "", do: [], else: [%{"type" => "text", "text" => text}]) ++
            Enum.map(images, fn image ->
              %{
                "type" => "image_url",
                "image_url" => %{"url" => "data:#{image.mime};base64,#{image.data}"}
              }
            end)

        %{"role" => "user", "content" => parts}
    end
  end

  defp format_message(%{role: "assistant"} = m) do
    content = Map.get(m, :content)
    message = %{"role" => "assistant", "content" => if(content == "", do: nil, else: content)}

    case Map.get(m, :tool_calls) || [] do
      [] -> message
      calls -> Map.put(message, "tool_calls", Enum.map(calls, &format_call/1))
    end
  end

  # spec 67 T34 (G35): the Chat Completions `tool` message takes a string, not
  # content parts — an image result is named rather than carried, so the model
  # knows a screenshot exists and can ask for it another way.
  defp format_message(%{role: "tool"} = m) do
    text = Map.get(m, :content) || ""

    text =
      case Map.get(m, :images) || [] do
        [] ->
          text

        images ->
          String.trim_leading(text <> String.duplicate("\n[image omitted]", length(images)), "\n")
      end

    %{
      "role" => "tool",
      "tool_call_id" => Map.get(m, :tool_call_id),
      "content" => text
    }
  end

  defp format_message(%{role: role} = m),
    do: %{"role" => role, "content" => Map.get(m, :content) || ""}

  defp format_call(call) do
    %{
      "id" => call.id,
      "type" => "function",
      "function" => %{"name" => call.name, "arguments" => Jason.encode!(call.args || %{})}
    }
  end

  defp handle_chunk(data, acc, on_event, name) do
    {events, rest} = SSE.parse(acc.sse, data)

    Enum.reduce(events, %{acc | sse: rest}, fn event, acc ->
      handle_event(event.data, acc, on_event, name)
    end)
  end

  # spec 55 T13 (55a A1): the terminal marker; only after it is the 200 an answer.
  defp handle_event("[DONE]", acc, _on_event, _name), do: %{acc | completed?: true}

  defp handle_event(data, acc, on_event, name) do
    case Jason.decode(data) do
      {:ok, %{"error" => error}} -> put_error(acc, error, name)
      {:ok, %{} = chunk} -> apply_chunk(chunk, acc, on_event)
      _other -> acc
    end
  end

  # The first error object wins, and its code travels with it (spec 51 §6.1).
  defp put_error(%{error: existing} = acc, _error, _name) when is_binary(existing), do: acc

  defp put_error(acc, error, name),
    do: %{acc | error: stream_error(error, name), error_code: error_code(error)}

  defp error_code(%{"code" => code}) when is_integer(code), do: code
  defp error_code(%{"status" => status}) when is_integer(status), do: status

  defp error_code(%{"code" => code}) when is_binary(code) do
    case Integer.parse(code) do
      {number, ""} -> number
      _other -> nil
    end
  end

  defp error_code(_error), do: nil

  defp stream_error(error, name) do
    message =
      case error do
        %{"message" => message} when is_binary(message) -> message
        message when is_binary(message) -> message
        other -> inspect(other)
      end

    "#{name} stream error: " <> HTTP.redact(message)
  end

  defp apply_chunk(chunk, acc, on_event) do
    choice = first_choice(chunk)
    delta = choice["delta"] || %{}

    acc
    |> apply_reasoning(delta["reasoning_content"] || delta["reasoning"], on_event)
    |> apply_content(delta["content"], on_event)
    |> apply_tool_calls(delta["tool_calls"])
    |> apply_finish(choice["finish_reason"])
    |> apply_usage(chunk["usage"])
  end

  defp first_choice(%{"choices" => [choice | _rest]}) when is_map(choice), do: choice
  defp first_choice(_chunk), do: %{}

  defp apply_content(acc, content, on_event) when is_binary(content) and content != "" do
    on_event.({:text_delta, content})
    %{acc | text: Chunks.append(acc.text, content)}
  end

  defp apply_content(acc, _content, _on_event), do: acc

  # Reasoning/thinking text. OpenAI-compatible servers use `delta.reasoning_content`
  # (DeepSeek, vLLM, llmotions); some use plain `delta.reasoning`.
  defp apply_reasoning(acc, text, on_event) when is_binary(text) and text != "" do
    on_event.({:reasoning_delta, text})
    %{acc | reasoning: Chunks.append(acc.reasoning, text)}
  end

  defp apply_reasoning(acc, _text, _on_event), do: acc

  defp apply_tool_calls(acc, tool_calls) when is_list(tool_calls) do
    Enum.reduce(tool_calls, acc, &put_call/2)
  end

  defp apply_tool_calls(acc, _tool_calls), do: acc

  defp put_call(tool_call, acc) when is_map(tool_call) do
    index = tool_call["index"] || 0
    current = Map.get(acc.calls, index, %{id: nil, name: nil, args: Chunks.new()})
    function = tool_call["function"] || %{}

    updated = %{
      current
      | id: current.id || tool_call["id"],
        name: current.name || function["name"],
        args: Chunks.append(current.args, fragment(function["arguments"]))
    }

    %{acc | calls: Map.put(acc.calls, index, updated)}
  end

  defp put_call(_tool_call, acc), do: acc

  defp fragment(value) when is_binary(value), do: value
  defp fragment(_value), do: ""

  defp apply_finish(acc, nil), do: acc
  # spec 55 T13 (55a A1): a finish_reason is the provider's terminal event.
  defp apply_finish(acc, finish), do: %{acc | finish: finish, completed?: true}

  # Spec 51 §6.3: no `{:usage, …}` event — nothing acted on it, and the agent
  # reads `Result.usage` when the op is done.
  defp apply_usage(acc, usage) when is_map(usage) do
    # spec 55 T13 (55a A10): cached prompt tokens are billed at the cache-read rate.
    %{
      acc
      | usage: %{
          input: count(usage["prompt_tokens"]),
          output: count(usage["completion_tokens"]),
          cache_read: count(get_in(usage, ["prompt_tokens_details", "cached_tokens"]))
        }
    }
  end

  defp apply_usage(acc, _usage), do: acc

  defp to_result(acc, model) do
    tool_calls =
      acc.calls
      |> Enum.sort_by(fn {index, _call} -> index end)
      |> Enum.map(fn {index, call} ->
        raw = Chunks.to_string(call.args)

        case ToolArgs.decode(raw) do
          {:ok, args} ->
            %{id: call.id || "call_#{index}", name: clean_name(call.name), args: args}

          {:error, reason} ->
            %{
              id: call.id || "call_#{index}",
              name: clean_name(call.name),
              args: %{},
              args_error: reason,
              args_raw: raw
            }
        end
      end)

    %Result{
      text: Chunks.to_string(acc.text),
      reasoning: Chunks.to_string(acc.reasoning),
      tool_calls: tool_calls,
      usage: acc.usage,
      stop_reason: stop_reason(acc.finish, tool_calls),
      model: model
    }
  end

  @doc """
  Spec 23 §5: the tool name, as a name and nothing else.

  A proxy in front of a model that emits its tool calls as text
  (`<tool_call>{…}</tool_call>`) can re-serialise them badly and leak the
  delimiters — and sometimes the whole next call — into `function.name`. The op
  then failed with `unknown tool workflow_list</tool_call><…><tool_call><…>list_dir`
  and the model, told its tool does not exist, gave up and did the work inline.
  The leading identifier is the call it meant.
  """
  @spec clean_name(String.t() | nil) :: String.t()
  def clean_name(name) when is_binary(name) do
    if Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_.\-]*$/, name) do
      name
    else
      case Regex.run(~r/[A-Za-z_][A-Za-z0-9_.\-]*/, name) do
        [first] -> first
        _other -> name
      end
    end
  end

  def clean_name(_name), do: ""

  defp stop_reason("tool_calls", _tool_calls), do: "tool_use"
  defp stop_reason("stop", _tool_calls), do: "end_turn"
  defp stop_reason("length", _tool_calls), do: "max_tokens"
  defp stop_reason(nil, []), do: "end_turn"
  defp stop_reason(nil, _tool_calls), do: "tool_use"
  defp stop_reason(_other, _tool_calls), do: "other"

  defp count(value) when is_integer(value), do: value
  defp count(_value), do: 0

  defp base_url(provider), do: String.trim_trailing(provider.base_url, "/")

  defp key(provider), do: provider.api_key || ""

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false
end
