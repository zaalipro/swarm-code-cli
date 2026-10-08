defmodule SwarmCode.Domain.LLM.OpenAI do
  @moduledoc """
  Client for every OpenAI-compatible `/chat/completions` server (OpenRouter, DeepSeek, vLLM, LM Studio …):
  streaming text deltas, tool calls assembled by `index`, usage capture, model listing.
  """
  @behaviour SwarmCode.Domain.LLM.Provider

  alias SwarmCode.Domain.LLM.{Chunks, Efforts, HTTP, ProviderCaps, Request, Result, SSE, ToolArgs}

  # Servers that rejected `reasoning_effort` or `prompt_cache_key` once are
  # remembered (`ProviderCaps`, ETS) for the rest of the session so every later
  # request skips the parameter (and the retry).

  @generic_rejections ["unknown parameter", "unrecognized"]

  @impl true
  # cli020 L2: one clock for the whole call, its re-attempts included.
  def stream(%Request{} = r, on_event),
    do: HTTP.with_call_clock(fn -> do_stream(r, on_event) end)

  defp do_stream(%Request{} = r, on_event) do
    on_event = on_event || fn _ -> :ok end

    # pass74 (spec 74) BUGS-28: the level is read once, and the keys it put on
    # *this* body ride to `settle_error/3`. Re-reading the caps when the 400
    # came back meant that once a concurrent sibling had remembered "no
    # effort", every other in-flight request saw no level keys and failed.
    # pass74 (spec 74) BUGS-51/52: every retry arm rebuilds the body from the
    # request (`build_body/3`) with the level it chose, instead of taking keys
    # off the rejected body — `Map.drop` also took the caller's `max_tokens`.
    post(base_body(r, continuation?(r)), r, Efforts.level(r), MapSet.new(), on_event)
  end

  # pass74 (spec 74) BUGS-77: whether this model's continuation state is echoed.
  defp continuation?(%Request{provider: provider, model: model}),
    do: ProviderCaps.continuation?(provider, model)

  # The part of the body no retry arm changes (but the continuation one):
  # formatted once per call.
  defp base_body(%Request{} = r, continuation?) do
    body = %{
      "model" => r.model,
      "messages" => format_messages(r.system, r.messages, continuation?),
      "stream" => true,
      "stream_options" => %{"include_usage" => true},
      "max_tokens" => r.max_tokens,
      "temperature" => r.temperature
    }

    if r.tools == [], do: body, else: Map.put(body, "tools", format_tools(r.tools))
  end

  @doc false
  # The body one attempt sends, and the keys its effort level put on it: the
  # level, then the prefix-cache key (spec 66 T18), then what this model is
  # known to need (pass74 BUGS-52) — after the level, so a level's own
  # `max_tokens` is renamed too.
  @spec build_body(map(), Request.t(), Efforts.level() | nil) :: {map(), [String.t()]}
  def build_body(base, %Request{} = r, level) do
    {body, sent_keys} = put_level(base, level)
    {body |> put_cache_key(r) |> put_model_caps(r), sent_keys}
  end

  defp put_level(body, nil), do: {body, []}

  defp put_level(body, level) do
    level_body = if is_map(level["body"]), do: level["body"], else: %{}

    {body |> Efforts.merge(level_body) |> Map.drop(List.wrap(level["drop"])),
     Map.keys(level_body)}
  end

  # pass74 (spec 74) BUGS-52: o-series and gpt-5.x answer 400 to `max_tokens`
  # ("use 'max_completion_tokens'") and to any temperature but the default.
  # Once a model said so, its requests are sent the way it wants from the start.
  defp put_model_caps(body, %Request{provider: provider, model: model}) do
    body =
      if Map.has_key?(body, "max_tokens") and
           ProviderCaps.max_completion_tokens?(provider, model) do
        {n, body} = Map.pop(body, "max_tokens")
        Map.update(body, "max_completion_tokens", n, &max_of(&1, n))
      else
        body
      end

    if ProviderCaps.temperature?(provider, model), do: body, else: Map.delete(body, "temperature")
  end

  defp max_of(a, b) when is_number(a) and is_number(b), do: max(a, b)
  defp max_of(a, _b), do: a

  defp post(base, %Request{} = r, level, tried, on_event) do
    {body, sent_keys} = build_body(base, r, level)
    url = base_url(r.provider) <> "/chat/completions"

    headers = [
      {"authorization", "Bearer " <> key(r.provider)},
      {"content-type", "application/json"}
    ]

    init = %{
      sse: "",
      text: Chunks.new(),
      reasoning: Chunks.new(),
      # pass74 (spec 74) BUGS-77: the reasoning came as `reasoning_content` —
      # the field a thinking model wants back inside its tool loop.
      reasoning_content?: false,
      calls: %{},
      usage: %{input: 0, output: 0, cache_read: 0},
      finish: nil,
      error: nil,
      # Spec 51 §6.1: the `code`/`status` of an in-band error object decides
      # whether the 200 that carried it is retried.
      error_code: nil,
      # spec 55 T13 (55a A1): set by a finish_reason or [DONE]; a 200 without it is retried.
      completed?: false,
      # pass74 (spec 74) BUGS-49: choice deltas so far; `HTTP` resets its idle
      # deadline whenever this moves (keep-alives and empty deltas do not).
      progress: 0
    }

    # What a failed attempt needs to decide on its retry.
    ctx = %{
      base: base,
      body: body,
      keys: sent_keys,
      level: level,
      tried: tried,
      r: r,
      on_event: on_event
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
        settle_error(message, ctx, in_band_kind(acc))

      {:ok, acc} ->
        max_tokens = body["max_tokens"] || body["max_completion_tokens"] || r.max_tokens
        {:ok, to_result(acc, r.model, max_tokens)}

      # spec 67 T30 (G42): the transport's kind survives the one-shot retries.
      {:error, kind, message} ->
        settle_error(message, ctx, kind)

      {:error, message} ->
        settle_error(message, ctx, nil)
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

  # Each arm retries at most once per call (`tried`), after remembering what
  # the 400 taught in `ProviderCaps`, so the next call does not ask again.
  defp settle_error(message, %{body: body, keys: keys, r: r} = ctx, kind) do
    level_key = ctx.level && ctx.level["key"]

    cond do
      # spec 66 T18: the one-shot shape for a server that does not know
      # `prompt_cache_key`. It is an optimisation; it never costs a turn.
      # spec 67 B36: this arm is tested first, and each classifier below only
      # takes a generic "unknown parameter" when the message names none of the
      # other fields — a 400 about `prompt_cache_key` used to turn
      # `reasoning_effort` off for the provider for the whole session.
      untried?(ctx, :cache_key) and Map.has_key?(body, "prompt_cache_key") and
          rejected_cache_key?(message, keys) ->
        remember_no_cache_key(r.provider)
        retry(ctx, :cache_key, ctx.level)

      # pass74 (spec 74) BUGS-77: a server that will not take the continuation
      # state back (the old deepseek-reasoner) — once, and remembered per model.
      untried?(ctx, :continuation) and echoed_continuation?(body) and
          rejected_continuation?(message) ->
        ProviderCaps.remember_no_continuation(r.provider, r.model)
        ctx.on_event.({:text_reset})
        ctx.on_event.({:reasoning_reset})

        post(
          base_body(r, false),
          r,
          ctx.level,
          MapSet.put(ctx.tried, :continuation),
          ctx.on_event
        )

      # pass74 (spec 74) BUGS-52: "Unsupported parameter: 'max_tokens' … use
      # 'max_completion_tokens'". Before the effort arm: the `max` level's own
      # body carries `max_tokens`, and that arm would have dropped the level.
      untried?(ctx, :max_completion_tokens) and Map.has_key?(body, "max_tokens") and
          rejected_max_tokens?(message) ->
        ProviderCaps.remember_max_completion_tokens(r.provider, r.model)
        retry(ctx, :max_completion_tokens, ctx.level)

      # pass74 (spec 74) BUGS-52: "Unsupported value: 'temperature' … Only the
      # default (1) value is supported".
      untried?(ctx, :temperature) and Map.has_key?(body, "temperature") and
          rejected_temperature?(message) ->
        ProviderCaps.remember_no_temperature(r.provider, r.model)
        retry(ctx, :temperature, ctx.level)

      # Older / smaller OpenAI-compatible servers 400 on `reasoning_effort`.
      # Every key the level's body added counts (spec 45 §3.4), and `keys` are
      # the ones this body was sent with (BUGS-28).
      untried?(ctx, {:effort, level_key}) and keys != [] and
        Enum.any?(keys, &Map.has_key?(body, &1)) and rejected_effort?(message, keys) ->
        settle_effort(message, ctx)

      true ->
        # Spec 51 §6.10: this text becomes the op's `error` and the run's message.
        # A gateway that echoes the Authorization header back does not have to
        # have used an `sk-` shaped key for it to be a key.
        # cli020 L2: the exact key, however short.
        text = HTTP.redact_key(message, [key(r.provider)])
        {:error, kind || SwarmCode.Domain.LLM.Error.classify(nil, nil, text), text}
    end
  end

  # pass74 (spec 74) BUGS-51: which effort rejection this is decides how far
  # it reaches. "Unknown parameter" is the server: the provider is remembered.
  # A refused *value* ("does not support 'max' with this model") is one level
  # of one model: that model falls back to its default level, and the llm node
  # says so. Anything else is one model: its requests go without the keys.
  defp settle_effort(message, %{r: r, level: level} = ctx) do
    tag = {:effort, level["key"]}

    cond do
      unknown_parameter?(message) ->
        remember_no_effort(r.provider)
        retry(ctx, tag, nil)

      value_rejected?(message, level) ->
        ProviderCaps.remember_rejected_level(r.provider, r.model, level["key"])
        fallback = Efforts.default_level(r, level)

        used =
          if fallback, do: "used default (#{fallback["key"]})", else: "sent without effort"

        SwarmCode.Domain.LLM.on_retry(ctx.on_event).(
          1,
          1,
          "effort #{level["key"]} not supported by #{r.model}; #{used}",
          true
        )

        post(ctx.base, r, fallback, MapSet.put(ctx.tried, tag), ctx.on_event)

      true ->
        ProviderCaps.remember_no_model_effort(r.provider, r.model)
        retry(ctx, tag, nil)
    end
  end

  # Spec 43 §1.5 (B2): whatever the first attempt streamed before the error
  # object must not stay in front of the second answer — the Anthropic
  # provider resets the same way, and a reset with nothing streamed is a no-op.
  defp retry(ctx, tag, level) do
    ctx.on_event.({:text_reset})
    ctx.on_event.({:reasoning_reset})
    post(ctx.base, ctx.r, level, MapSet.put(ctx.tried, tag), ctx.on_event)
  end

  defp untried?(%{tried: tried}, tag), do: not MapSet.member?(tried, tag)

  defp unknown_parameter?(message) do
    text = String.downcase(to_string(message))
    Enum.any?(@generic_rejections, &String.contains?(text, &1))
  end

  @doc false
  # pass74 (spec 74) BUGS-51: the message quotes one of the level's values, or
  # says the value is unsupported.
  def value_rejected?(message, level) do
    text = String.downcase(to_string(message))

    String.contains?(text, "unsupported value") or String.contains?(text, "does not support") or
      Enum.any?(level_values(level), fn value ->
        Enum.any?(["'#{value}'", "\"#{value}\"", "`#{value}`"], &String.contains?(text, &1))
      end)
  end

  defp level_values(%{"body" => body}) when is_map(body), do: leaf_values(body)
  defp level_values(_level), do: []

  defp leaf_values(map) when is_map(map), do: Enum.flat_map(Map.values(map), &leaf_values/1)
  defp leaf_values(value) when is_binary(value) and value != "", do: [String.downcase(value)]
  defp leaf_values(_value), do: []

  defp echoed_continuation?(%{"messages" => messages}) when is_list(messages) do
    Enum.any?(messages, fn m ->
      Map.has_key?(m, "reasoning_content") or
        Enum.any?(List.wrap(m["tool_calls"]), &Map.has_key?(&1, "extra_content"))
    end)
  end

  defp echoed_continuation?(_body), do: false

  @doc false
  def rejected_continuation?(message) do
    text = String.downcase(to_string(message))

    String.contains?(text, "400") and
      (String.contains?(text, "reasoning_content") or String.contains?(text, "extra_content"))
  end

  @doc false
  def rejected_max_tokens?(message) do
    text = String.downcase(to_string(message))

    String.contains?(text, "400") and String.contains?(text, "max_tokens") and
      String.contains?(text, "max_completion_tokens")
  end

  @temperature_rejections [
    "unsupported value",
    "only the default",
    "does not support",
    "not supported",
    "unsupported parameter"
  ]

  @doc false
  def rejected_temperature?(message) do
    text = String.downcase(to_string(message))

    String.contains?(text, "400") and String.contains?(text, "temperature") and
      Enum.any?(@temperature_rejections, &String.contains?(text, &1))
  end

  @doc """
  spec 66 T18: `prompt_cache_key` keeps one agent's requests on one prefix cache
  for the whole run. Omitted when the request carries no key, and after a server
  has once refused it.
  """
  @spec put_cache_key(map(), Request.t()) :: map()
  # pass74 (spec 74) EFFICIENCY-42: a one-shot request routes on no cache.
  def put_cache_key(body, %Request{cache: :none}), do: body

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
  # always counts (`@generic_rejections` is defined at the top).

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
  @spec format_messages(String.t() | nil, [map()], boolean()) :: [map()]
  def format_messages(system, messages, continuation? \\ true) do
    head = if blank?(system), do: [], else: [%{"role" => "system", "content" => system}]

    # pass74 (spec 74) BUGS-77: continuation state goes back only inside the
    # current tool loop — on assistant turns after the last user message.
    loop_start = if continuation?, do: last_user_index(messages) + 1, else: :none

    body =
      messages
      |> Enum.with_index()
      |> Enum.map(fn {m, i} -> format_message(m, loop_start != :none and i >= loop_start) end)

    head ++ body
  end

  defp last_user_index(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reduce(-1, fn
      {%{role: "user"}, i}, _last -> i
      _other, last -> last
    end)
  end

  # pass74 (spec 74) EFFICIENCY-45: the data URL is spliced into the encoded
  # body as iodata — Req's `json:` step encodes with `Jason.encode_to_iodata!`,
  # which takes fragments — instead of a fresh binary copy of every image's
  # base64 on every call. A MIME type and base64 need no JSON escaping.
  @doc false
  def data_url(image),
    do: Jason.Fragment.new([?", "data:", image.mime, ";base64,", image.data, ?"])

  defp format_message(%{role: "assistant"} = m, true), do: echo_continuation(m)
  defp format_message(m, _in_loop?), do: format_message(m)

  # pass74 (spec 74) BUGS-77: `reasoning_content` on the message, and each
  # call's `extra_content` (Gemini's thought signature) on the call it came
  # with. Only blocks of type "openai" — Anthropic's never reach this wire.
  defp echo_continuation(m) do
    message = format_message(m)

    case Enum.find(Map.get(m, :provider_blocks) || [], &(&1["type"] == "openai")) do
      nil ->
        message

      block ->
        message =
          case block["reasoning_content"] do
            text when is_binary(text) and text != "" ->
              Map.put(message, "reasoning_content", text)

            _other ->
              message
          end

        extras = block["extra_content"] || %{}

        case message do
          %{"tool_calls" => calls} when extras != %{} ->
            %{message | "tool_calls" => Enum.map(calls, &put_extra(&1, extras))}

          _other ->
            message
        end
    end
  end

  defp put_extra(%{"id" => id} = call, extras) do
    case Map.fetch(extras, id) do
      {:ok, extra} -> Map.put(call, "extra_content", extra)
      :error -> call
    end
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
                "image_url" => %{"url" => data_url(image)}
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

    # spec 74 EFFICIENCY-40: the agent keeps only `image_count` on this path.
    count = length(Map.get(m, :images) || []) + (Map.get(m, :image_count) || 0)

    text =
      case count do
        0 -> text
        n -> String.trim_leading(text <> String.duplicate("\n[image omitted]", n), "\n")
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
      {:ok, %{"error" => error}} ->
        put_error(acc, error, name)

      {:ok, %{} = chunk} ->
        apply_chunk(chunk, acc, on_event)

      # cli020 L2: an event that is not JSON fails the call instead of losing
      # its content in silence (a blank `data:` carries none).
      _other ->
        if String.trim(data) == "",
          do: acc,
          else: put_error(acc, "invalid JSON in SSE event", name)
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
    |> note_reasoning_content(delta["reasoning_content"])
    |> apply_content(delta["content"], on_event)
    |> apply_tool_calls(delta["tool_calls"])
    |> apply_finish(choice["finish_reason"])
    |> apply_usage(chunk["usage"])
    |> count_progress(delta, choice["finish_reason"])
  end

  # pass74 (spec 74) BUGS-49: a non-empty choice delta or a finish is progress.
  defp count_progress(acc, delta, finish) when (is_map(delta) and delta != %{}) or finish != nil,
    do: %{acc | progress: acc.progress + 1}

  defp count_progress(acc, _delta, _finish), do: acc

  defp first_choice(%{"choices" => [choice | _rest]}) when is_map(choice), do: choice
  defp first_choice(_chunk), do: %{}

  defp apply_content(acc, content, on_event) when is_binary(content) and content != "" do
    on_event.({:text_delta, content})
    %{acc | text: Chunks.append(acc.text, content)}
  end

  defp apply_content(acc, _content, _on_event), do: acc

  # Reasoning/thinking text. OpenAI-compatible servers use `delta.reasoning_content`
  # (DeepSeek, vLLM); some use plain `delta.reasoning`.
  defp apply_reasoning(acc, text, on_event) when is_binary(text) and text != "" do
    on_event.({:reasoning_delta, text})
    %{acc | reasoning: Chunks.append(acc.reasoning, text)}
  end

  defp apply_reasoning(acc, _text, _on_event), do: acc

  defp note_reasoning_content(acc, text) when is_binary(text) and text != "",
    do: %{acc | reasoning_content?: true}

  defp note_reasoning_content(acc, _text), do: acc

  defp apply_tool_calls(acc, tool_calls) when is_list(tool_calls) do
    Enum.reduce(tool_calls, acc, &put_call/2)
  end

  defp apply_tool_calls(acc, _tool_calls), do: acc

  defp put_call(tool_call, acc) when is_map(tool_call) do
    index = tool_call["index"] || 0
    current = Map.get(acc.calls, index, %{id: nil, name: nil, args: Chunks.new(), extra: nil})
    function = tool_call["function"] || %{}

    updated = %{
      current
      | id: current.id || tool_call["id"],
        name: current.name || function["name"],
        args: Chunks.append(current.args, fragment(function["arguments"])),
        # pass74 (spec 74) BUGS-77: Gemini's per-call thought signature.
        extra: merge_extra(current.extra, tool_call["extra_content"])
    }

    %{acc | calls: Map.put(acc.calls, index, updated)}
  end

  defp put_call(_tool_call, acc), do: acc

  defp merge_extra(nil, %{} = extra), do: extra
  defp merge_extra(%{} = current, %{} = extra), do: Efforts.merge(current, extra)
  defp merge_extra(current, _extra), do: current

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

  defp to_result(acc, model, max_tokens) do
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

    # pass74 (spec 74) BUGS-29: `finish_reason: "length"` — an undecodable
    # call was cut off at the output limit, not malformed.
    tool_calls =
      if acc.finish == "length",
        do: Result.mark_truncated(tool_calls, max_tokens),
        else: tool_calls

    reasoning = Chunks.to_string(acc.reasoning)

    %Result{
      text: Chunks.to_string(acc.text),
      reasoning: reasoning,
      tool_calls: tool_calls,
      provider_blocks: continuation_blocks(acc, reasoning, tool_calls),
      usage: acc.usage,
      stop_reason: stop_reason(acc.finish, tool_calls),
      model: model
    }
  end

  # pass74 (spec 74) BUGS-77: the state a thinking model needs back inside its
  # tool loop, kept (in memory only, like Anthropic's signed blocks) on a turn
  # that called tools. A turn without calls ends the loop: nothing to keep.
  defp continuation_blocks(_acc, _reasoning, []), do: []

  defp continuation_blocks(acc, reasoning, tool_calls) do
    ids = acc.calls |> Enum.sort_by(&elem(&1, 0)) |> Enum.zip(tool_calls)

    extras =
      for {{_index, %{extra: %{} = extra}}, %{id: id}} <- ids,
          extra != %{},
          into: %{},
          do: {id, extra}

    reasoning = if acc.reasoning_content?, do: reasoning, else: ""

    if reasoning == "" and extras == %{} do
      []
    else
      [%{"type" => "openai", "reasoning_content" => reasoning, "extra_content" => extras}]
    end
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
