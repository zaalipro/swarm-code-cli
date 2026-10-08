defmodule SwarmCode.Domain.LLM.HTTP do
  @moduledoc """
  Streaming POST with retries and exact error mapping, shared by the LLM clients.

  Clock model (spec 51 §4.12, verified on OTP 28 defaults `multi_time_warp` +
  `CLOCK_UPTIME_RAW`): the per-call deadline below is monotonic and pauses while
  the machine sleeps; every timestamp is wall-clock and jumps at wake. Keep it
  that way; do not add `+C no_time_warp`.

  Usage totals exclude failed attempts (spec 51 §6.2): a retried attempt streams
  into an accumulator that the next attempt replaces, so whatever the provider
  may have counted for the attempt that failed is never added to the op's tokens.
  """

  # Transport retries (spec 11 §7.3): 5 tries, jittered 1s -> 4s -> 15s -> 60s,
  # under three minutes in total. Only transport-shaped failures are retried;
  # 400/401/403/404/422 and model refusals come straight back.
  require Logger

  alias SwarmCode.Domain.LLM.Error

  @max_attempts 5
  @retry_delays [1_000, 4_000, 15_000, 60_000]
  @retry_statuses [408, 409, 425, 429]
  @got_chunk_key :swarm_code_llm_got_chunk
  # pass74 (spec 74) BUGS-49: when the stream last made progress (monotonic
  # ms). Kept in the caller's process dictionary beside `@got_chunk_key`: the
  # `into` fun runs in this process, and a transport error loses `resp.private`.
  @last_progress_key :swarm_code_llm_last_progress
  # pass74 (spec 74) BUGS-49: the hard cap is this many ms per `max_tokens`
  # token (25 tokens/s), never under the idle deadline.
  @hard_ms_per_token 40

  # Spec 51 §6.2 (b): a name that does not resolve and a port that refuses are
  # not going to answer differently four sleeps later; a TLS alert is a
  # configuration error. Two attempts, then the error.
  @permanent_attempts 2

  # Spec 51 §6.2 (a): a `retry-after` far in the future is a signal to stop
  # asking, not to hold the op for an hour.
  @max_sleep 90_000

  @type on_chunk :: (binary(), term() -> term())
  @typedoc "attempt, of, reason (\"network\" | \"rate limit\" | \"server\"), mid-stream?"
  @type on_retry :: (pos_integer(), pos_integer(), String.t(), boolean() -> any())
  @typedoc """
  Spec 51 §6.1: asked once per 200 response, with the accumulator the stream
  built. `{:retry, reason}` sends that 200 down the same path as a 529.
  """
  @type retry_if :: (term() -> :ok | {:retry, String.t()})

  @no_retry_key :swarm_code_llm_no_retry

  @doc "Process-dictionary key that turns the retries off for one call."
  def no_retry_key, do: @no_retry_key

  defp attempts, do: if(Process.get(@no_retry_key) == true, do: 1, else: @max_attempts)

  @doc """
  The default no-progress bound of one LLM call (spec 51 §6.2 (c); pass74
  (spec 74) BUGS-49).

  Generous on purpose: a thinking model can pause well past a minute before its
  first token, and the per-chunk `receive_timeout` is the tighter bound anyway.
  It is an *idle* deadline: a stream that keeps producing content (a delta, a
  new block) is never cut by it; only keep-alives and silence count against
  it. The whole call is bounded separately by `hard_cap_ms/2`.
  """
  @spec default_deadline_ms() :: pos_integer()
  def default_deadline_ms, do: Application.get_env(:swarm_code_daemon, :llm_deadline_ms, 600_000)

  @spec stream_post(
          String.t(),
          [{String.t(), String.t()}],
          map(),
          String.t(),
          term(),
          on_chunk,
          on_retry | nil,
          retry_if | nil,
          pos_integer() | nil,
          String.t() | nil
        ) :: {:ok, term()} | {:error, atom(), String.t()}
  def stream_post(
        url,
        headers,
        body,
        provider_name,
        init_acc,
        on_chunk,
        on_retry \\ nil,
        retry_if \\ nil,
        deadline_ms \\ nil,
        provider_id \\ nil
      ) do
    # spec 67 G46: a nil deadline (the `%Request{}` default) is resolved here,
    # when the call is made, so `:llm_deadline_ms` set after boot is honoured.
    deadline_ms = deadline_ms || default_deadline_ms()
    started = System.monotonic_time(:millisecond)

    # pass74 (spec 74) BUGS-49: `deadline_ms` is the no-progress bound; the
    # hard cap from the start scales with the answer budget the body asks for.
    clock = %{
      started: started,
      idle_ms: deadline_ms,
      hard: started + hard_cap_ms(deadline_ms, body)
    }

    result =
      do_stream(
        url,
        headers,
        body,
        provider_name,
        init_acc,
        on_chunk,
        on_retry,
        retry_if || (&always_ok/1),
        clock,
        1,
        provider_id
      )

    Process.delete(@last_progress_key)
    result
  end

  defp always_ok(_acc), do: :ok

  @doc """
  pass74 (spec 74) BUGS-49: the hard cap of one call, from its start:
  `max(deadline_ms, max_tokens * 40)` — a 64 000-token answer may run 42 min
  as long as it keeps making progress, an 8 192-token one the idle deadline.
  """
  @spec hard_cap_ms(pos_integer(), map()) :: pos_integer()
  def hard_cap_ms(deadline_ms, body) do
    tokens =
      case body do
        %{"max_tokens" => n} when is_integer(n) -> n
        %{"max_completion_tokens" => n} when is_integer(n) -> n
        _other -> 0
      end

    max(deadline_ms, tokens * @hard_ms_per_token)
  end

  # pass74 (spec 74) BUGS-49: providers count content events in `acc.progress`
  # (Anthropic: `content_block_start`, every `content_block_delta`,
  # `message_delta`; OpenAI: every choice delta). Pings and SSE comments do not.
  defp progress(%{progress: n}), do: n
  defp progress(_acc), do: 0

  defp last_progress(started), do: Process.get(@last_progress_key, started)

  # Past the idle deadline (no progress for `idle_ms`) or the hard cap.
  defp past_deadline?(%{idle_ms: idle, hard: hard}, now, last),
    do: now - last > idle or now > hard

  @redirect_statuses [301, 302, 303, 307, 308]

  @doc """
  spec 60 T10: the one request builder for credentialed calls. Same-origin redirects behave as
  before; a redirect to another `{scheme, host, port}` is not followed (Req forwards `x-api-key`,
  custom headers and the body — `deps/req/lib/req/steps.ex:1556-1564` strips `authorization` only).
  """
  @spec request(String.t()) :: Req.Request.t()
  def request(url) do
    Req.new(url: url)
    |> Req.Request.prepend_response_steps(swarm_code_redirect_guard: &guard_redirect/1)
  end

  @doc false
  def guard_redirect({request, %Req.Response{status: status} = response})
      when status in @redirect_statuses do
    with [location | _] <- Req.Response.get_header(response, "location"),
         %URI{host: host} = target when is_binary(host) <-
           URI.merge(request.url, URI.parse(location)),
         true <- origin(target) != origin(request.url) do
      Logger.warning("swarm_code: refused a cross-origin redirect to #{origin_text(target)}")
      {Req.Request.put_option(request, :redirect, false), response}
    else
      _ -> {request, response}
    end
  end

  def guard_redirect(pair), do: pair

  defp origin(%URI{scheme: s, host: h, port: p}), do: {s, h, p || URI.default_port(s || "http")}
  defp origin_text(%URI{} = u), do: "#{u.scheme}://#{u.host}:#{elem(origin(u), 2)}"

  defp do_stream(
         url,
         headers,
         body,
         name,
         init_acc,
         on_chunk,
         on_retry,
         retry_if,
         clock,
         attempt,
         provider_id
       ) do
    Process.delete(@got_chunk_key)
    %{started: started} = clock
    # pass74 (spec 74) BUGS-49: every attempt gets a full idle window to its
    # first token; a retry is judged against the last progress of the one before.
    Process.put(@last_progress_key, System.monotonic_time(:millisecond))

    into = fn {:data, data}, {req, resp} ->
      if resp.status == 200 do
        Process.put(@got_chunk_key, true)
        before = Map.get(resp.private, :acc, init_acc)
        acc = on_chunk.(data, before)
        resp = %{resp | private: Map.put(resp.private, :acc, acc)}
        now = System.monotonic_time(:millisecond)
        if progress(acc) != progress(before), do: Process.put(@last_progress_key, now)

        # Spec 51 §6.2 (c): a stream that dribbles a keep-alive every few
        # hundred milliseconds never trips the per-chunk idle timeout. The
        # deadline is what ends it, and the 200 clause below turns the halt
        # into the same "gave up after" error a refused retry gives.
        # pass74 (spec 74) BUGS-49: the deadline is "no progress for
        # `idle_ms`" (or the hard cap), so a healthy stream past 10 min lives.
        if past_deadline?(clock, now, last_progress(started)) do
          {:halt, {req, %{resp | private: Map.put(resp.private, :past_deadline, true)}}}
        else
          {:cont, {req, resp}}
        end
      else
        # Spec 20 §9.3: drain provider errors without retaining an unbounded body.
        private =
          Map.update(resp.private, :err_body, bounded_error(data), &bounded_error(&1, data))

        resp = %{resp | private: private}

        # spec 60 T14: the deadline applies to an error body that dribbles too —
        # the halt reaches the >= 500 / 4xx arms below exactly like a plain 503.
        # An error body is never progress.
        now = System.monotonic_time(:millisecond)

        if past_deadline?(clock, now, last_progress(started)) do
          {:halt, {req, %{resp | private: Map.put(resp.private, :past_deadline, true)}}}
        else
          {:cont, {req, resp}}
        end
      end
    end

    result =
      post_stream(url,
        json: body,
        headers: headers,
        retry: false,
        # Spec 51 §6.2 (c): the per-chunk idle timeout never outlives the call's
        # own deadline, so a dribbling stream cannot run past it.
        receive_timeout: receive_timeout(clock),
        # pass74 (spec 74) BUGS-50: the LLM pool (256 connections) instead of
        # Finch's on-demand default of 50; a checkout waits at most this long.
        finch: Keyword.put(finch_options(), :pool_timeout, pool_timeout(clock)),
        into: into
      )

    retry = fn reason, message, hint_ms, max_attempts ->
      now = System.monotonic_time(:millisecond)
      planned = backoff_ms(attempt, hint_ms)

      cond do
        attempt >= max_attempts ->
          text = "#{name} request failed after #{max_attempts} attempts: " <> message
          {:error, Error.classify(nil, reason, text), text}

        # Spec 51 §6.2 (c): a retry that would land past the deadline is not a
        # retry, it is a hang the caller cannot see the end of.
        # pass74 (spec 74) BUGS-49: the idle deadline counts from the last
        # progress the failed attempt made, and the hard cap from the start.
        now + planned > min(last_progress(started) + clock.idle_ms, clock.hard) ->
          text = "#{name} gave up after #{div(now - started, 1000)} s: " <> message
          {:error, Error.classify(nil, reason, text), text}

        true ->
          notify(on_retry, attempt + 1, shown_reason(reason, message), max_attempts)
          sleep_fun().(planned)

          do_stream(
            url,
            headers,
            body,
            name,
            init_acc,
            on_chunk,
            on_retry,
            retry_if,
            clock,
            attempt + 1,
            provider_id
          )
      end
    end

    # spec 67 T33 (G41): every response says how much of the window is left.
    with {:ok, %Req.Response{} = resp} <- result, do: capture_rate_limit(resp, provider_id)

    case result do
      {:ok, %Req.Response{status: 200, private: %{past_deadline: true}} = resp} ->
        retry.("deadline", "the stream made no progress", retry_after_ms(resp), attempts())

      {:ok, %Req.Response{status: 200} = resp} ->
        acc = Map.get(resp.private, :acc, init_acc)

        case retry_if.(acc) do
          :ok ->
            {:ok, acc}

          # Spec 51 §6.1: an in-band error the provider calls transient goes
          # through the same retry as a 529 — the on_retry closure already
          # resets the half-streamed text.
          {:retry, reason} ->
            retry.(reason, "in-band " <> reason, retry_after_ms(resp), attempts())
        end

      {:ok, %Req.Response{status: status} = resp} when status in @retry_statuses ->
        retry.(reason_for(status), "HTTP #{status}", retry_after_ms(resp), attempts())

      {:ok, %Req.Response{status: status} = resp} when status >= 500 ->
        retry.("server", "HTTP #{status}", retry_after_ms(resp), attempts())

      {:ok, %Req.Response{status: status} = resp} ->
        body = Map.get(resp.private, :err_body, "")
        text = status_message(status, name, body)
        {:error, Error.classify(status, nil, text <> " " <> to_string(body)), text}

      {:error, exception} ->
        retry.(transport_reason(exception), Exception.message(exception), nil, max_for(exception))
    end
  end

  # pass74 (spec 74) BUGS-50: a pool checkout that times out *raises* out of
  # Finch (`Finch.HTTP1.Pool.request/6` reraises the NimblePool exit as a
  # RuntimeError) and nothing between Req and here rescued it, so the 51st
  # concurrent stream crashed its op as a SwarmCode bug. It is a transport
  # failure: it goes down the "network" retry like a refused connection.
  defp post_stream(url, options) do
    Req.post(request(url), options)
  rescue
    e in RuntimeError ->
      if String.starts_with?(e.message, "Finch was unable to provide a connection"),
        do: {:error, %Req.TransportError{reason: :pool_timeout}},
        else: reraise(e, __STACKTRACE__)
  end

  @pool_size 256
  @connect_timeout 15_000
  @max_pool_timeout 30_000

  @doc """
  pass74 (spec 74) BUGS-50: the child spec of the named LLM connection pool
  (`SwarmCode.Domain.LLM.Finch`, 256 connections per origin). While it is running
  every LLM stream uses it; without it (it is not in the application tree yet)
  `finch_options/0` asks Req for an on-demand pool of the same size, owned by
  `Req.FinchSupervisor`.
  """
  def finch_child_spec do
    {Finch, name: SwarmCode.Domain.LLM.Finch, pools: %{default: pool_options()}}
  end

  defp pool_options,
    do: [size: @pool_size, conn_opts: [transport_opts: [timeout: @connect_timeout]]]

  @doc false
  # App env `:llm_finch` (Req `finch:` options) wins — tests start a size-1 pool.
  def finch_options do
    case Application.get_env(:swarm_code_daemon, :llm_finch) do
      nil ->
        if Process.whereis(SwarmCode.Domain.LLM.Finch),
          do: [name: SwarmCode.Domain.LLM.Finch],
          else: pool_options()

      options ->
        options
    end
  end

  # pass74 (spec 74) BUGS-50: a checkout never outlives the call's own clock,
  # and never holds the op longer than 30 s before the retry gets its turn.
  defp pool_timeout(%{idle_ms: idle, hard: hard}) do
    left = min(idle, hard - System.monotonic_time(:millisecond))
    cap = Application.get_env(:swarm_code_daemon, :llm_pool_timeout, @max_pool_timeout)
    min(cap, max(left, 100))
  end

  # pass74 (spec 74) BUGS-49: a socket that went silent past `receive_timeout`
  # is the call's own deadline (kind `:timeout`), not a dropped network.
  defp transport_reason(%{reason: :timeout}), do: "timeout"
  defp transport_reason(_exception), do: "network"

  # pass74 (spec 74) BUGS-49: silence (not even a keep-alive) for the idle
  # deadline ends the attempt; never past the hard cap.
  defp receive_timeout(%{idle_ms: idle, hard: hard}) do
    left = hard - System.monotonic_time(:millisecond)
    min(120_000, max(min(idle, left), 1_000))
  end

  ## ------------------------------------------------ rate limits (spec 67 T33)

  # spec 67 T33 (G41): both APIs say on every response how much of the window is
  # gone and when it refills, and SwarmCode read only `retry-after`, only to
  # raise a backoff floor — so the first sign of a limit was a 429 mid-run.
  #
  # Three shapes are understood: a used-percent header (`…-used-percent`, what
  # Codex reads), Anthropic's `anthropic-ratelimit-<scope>-{limit,remaining,reset}`
  # and the OpenAI-compatible `x-ratelimit-{limit,remaining,reset}-<scope>`. The
  # scope that is *most* used wins, because that is the one that will 429.
  @doc false
  @spec capture_rate_limit(Req.Response.t(), String.t() | nil) :: map() | nil
  def capture_rate_limit(_resp, nil), do: nil

  def capture_rate_limit(%Req.Response{headers: headers}, provider_id) when is_map(headers) do
    case rate_limit_snapshot(headers) do
      nil ->
        nil

      snapshot ->
        # spec 74 EFFICIENCY-68: every Anthropic response carries the headers,
        # and every LiveView and the tray woke on the "ui" topic for each one.
        # The snapshot is still cached every time (a mount reads it); the
        # broadcast goes only when the chip would change, on its own topic.
        previous = SwarmCode.Domain.Cache.get({:rate_limit, provider_id})
        SwarmCode.Domain.Cache.put({:rate_limit, provider_id}, snapshot)

        if SwarmCode.Domain.LLM.rate_limit_shown(previous) !=
             SwarmCode.Domain.LLM.rate_limit_shown(snapshot),
           do:
             SwarmCode.Domain.PubSub.broadcast(
               SwarmCode.Domain.PubSub,
               SwarmCode.Domain.LLM.rate_limit_topic(),
               {:rate_limit, provider_id, snapshot}
             )

        snapshot
    end
  end

  def capture_rate_limit(_resp, _provider_id), do: nil

  @doc false
  @spec rate_limit_snapshot(map()) :: map() | nil
  def rate_limit_snapshot(headers) do
    values = for {name, value} <- headers, into: %{}, do: {String.downcase(name), first(value)}

    values
    |> scopes()
    |> Enum.map(&scope_snapshot(values, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(& &1.used_percent, fn -> nil end)
  end

  defp first([value | _]), do: to_string(value)
  defp first(value), do: to_string(value)

  @rate_prefixes ~w(anthropic-ratelimit x-ratelimit)

  # Every `<scope>` the headers speak about, in either naming order.
  defp scopes(values) do
    for {name, _value} <- values,
        prefix <- @rate_prefixes,
        String.starts_with?(name, prefix <> "-"),
        rest = String.replace_prefix(name, prefix <> "-", ""),
        scope = scope_of(rest),
        scope != nil,
        uniq: true,
        do: {prefix, scope}
  end

  defp scope_of(rest) do
    cond do
      String.ends_with?(rest, "-used-percent") -> String.replace_suffix(rest, "-used-percent", "")
      String.ends_with?(rest, "-reset-at") -> String.replace_suffix(rest, "-reset-at", "")
      String.ends_with?(rest, "-limit") -> String.replace_suffix(rest, "-limit", "")
      String.ends_with?(rest, "-remaining") -> String.replace_suffix(rest, "-remaining", "")
      String.ends_with?(rest, "-reset") -> String.replace_suffix(rest, "-reset", "")
      String.starts_with?(rest, "limit-") -> String.replace_prefix(rest, "limit-", "")
      String.starts_with?(rest, "remaining-") -> String.replace_prefix(rest, "remaining-", "")
      String.starts_with?(rest, "reset-") -> String.replace_prefix(rest, "reset-", "")
      true -> nil
    end
  end

  defp scope_snapshot(values, {prefix, scope}) do
    used =
      case number(values["#{prefix}-#{scope}-used-percent"]) do
        nil -> percent_of(values, prefix, scope)
        percent -> percent
      end

    if used do
      %{
        used_percent: min(max(used, 0.0), 100.0),
        resets_at: reset_at(values, prefix, scope),
        scope: scope
      }
    end
  end

  defp percent_of(values, prefix, scope) do
    limit = number(values["#{prefix}-#{scope}-limit"] || values["#{prefix}-limit-#{scope}"])

    remaining =
      number(values["#{prefix}-#{scope}-remaining"] || values["#{prefix}-remaining-#{scope}"])

    if is_number(limit) and is_number(remaining) and limit > 0,
      do: (limit - remaining) / limit * 100.0
  end

  defp reset_at(values, prefix, scope) do
    raw =
      values["#{prefix}-#{scope}-reset-at"] || values["#{prefix}-#{scope}-reset"] ||
        values["#{prefix}-reset-#{scope}"]

    parse_reset(raw)
  end

  # An absolute instant (Anthropic sends RFC 3339) or a duration from now
  # (`6m0s`, `30s`, `120`, `500ms` — the OpenAI-compatible shape).
  defp parse_reset(nil), do: nil

  defp parse_reset(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, at, _offset} -> at
      _error -> duration_from_now(raw)
    end
  end

  defp duration_from_now(raw) do
    seconds =
      ~r/(\d+(?:\.\d+)?)(ms|s|m|h)?/
      |> Regex.scan(raw)
      |> Enum.reduce(nil, fn
        [_all, number], acc -> add_seconds(acc, number, "s")
        [_all, number, unit], acc -> add_seconds(acc, number, unit)
        _other, acc -> acc
      end)

    if seconds, do: DateTime.add(DateTime.utc_now(), round(seconds * 1000), :millisecond)
  end

  defp add_seconds(acc, number, unit) do
    case Float.parse(number) do
      {value, _rest} -> (acc || 0) + value * unit_seconds(unit)
      :error -> acc
    end
  end

  defp unit_seconds("ms"), do: 0.001
  defp unit_seconds("m"), do: 60
  defp unit_seconds("h"), do: 3_600
  defp unit_seconds(_other), do: 1

  defp number(nil), do: nil

  defp number(value) do
    case Float.parse(to_string(value)) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  # Spec 51 §6.2 (a): the provider's own `retry-after`, in milliseconds.
  # `Req.Response.get_retry_after/1`'s docstring says seconds; its body runs the
  # value through `retry_delay_in_ms/1`, and the unit is pinned by a test. An
  # unparsable HTTP-date raises in Req, hence the rescue.
  defp retry_after_ms(%Req.Response{} = resp) do
    Req.Response.get_retry_after(resp)
  rescue
    _error -> nil
  end

  # Spec 51 §6.2 (b): a permanent transport failure gets two attempts, not five.
  defp max_for(%Req.TransportError{reason: reason}), do: max_for_reason(reason)
  defp max_for(%Mint.TransportError{reason: reason}), do: max_for_reason(reason)
  defp max_for(_exception), do: attempts()

  defp max_for_reason(reason) when reason in [:nxdomain, :econnrefused],
    do: min(attempts(), @permanent_attempts)

  defp max_for_reason({:tls_alert, _detail}), do: min(attempts(), @permanent_attempts)
  defp max_for_reason(_reason), do: attempts()

  defp bounded_error(data), do: binary_part(data, 0, min(byte_size(data), 65_536))

  defp bounded_error(current, data) do
    remaining = max(65_536 - byte_size(current), 0)

    if remaining == 0,
      do: current,
      else: current <> binary_part(data, 0, min(byte_size(data), remaining))
  end

  # A stream that died mid-way is retried too — the caller is told so it can
  # drop the half-streamed text before the next attempt replaces it.
  defp notify(nil, _attempt, _reason, _of), do: :ok

  defp notify(on_retry, attempt, reason, of) do
    on_retry.(attempt, of, reason, Process.get(@got_chunk_key) == true)
    :ok
  end

  # cli020 fix S2 (CLI provenance patch): the retry status line names the HTTP
  # status when the provider answered with one (`retrying 2/5 · HTTP 500`), the
  # reason word otherwise (`stream ended early`, `network`). `reason` still
  # classifies the final error; only what the line shows changes.
  defp shown_reason(_reason, "HTTP " <> _ = message), do: message
  defp shown_reason(reason, _message), do: reason

  defp reason_for(429), do: "rate limit"
  defp reason_for(_status), do: "network"

  @spec get_json(String.t(), [{String.t(), String.t()}], String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def get_json(url, headers, name) do
    case Req.get(request(url), headers: headers, retry: false, receive_timeout: 30_000) do
      {:ok, %Req.Response{status: 200, body: %{} = body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: 200}} ->
        {:error, "#{name} returned a non-JSON response"}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, status_message(status, name, inspect_body(body))}

      {:error, exception} ->
        {:error, "#{name} request failed: " <> Exception.message(exception)}
    end
  end

  @doc false
  def status_message(401, name, _body),
    do: "Unauthorized (401): check the API key for provider \"#{name}\""

  def status_message(404, name, _body),
    do: "Not found (404): check the base URL or model for provider \"#{name}\""

  def status_message(403, name, body), do: "Forbidden (403) from #{name}: #{snippet(body)}"

  def status_message(status, name, body) when status in [400, 422],
    do: "Bad request (#{status}) from #{name}: #{snippet(body)}"

  # spec 60 T10
  def status_message(status, name, _body) when status in 301..308,
    do:
      "Redirected (#{status}) to another origin by #{name}: set the base URL to the final address"

  def status_message(status, name, body), do: "HTTP #{status} from #{name}: #{snippet(body)}"

  # Shorter than this is not a credential, it is a flag: `1`, `true`, `json`.
  @min_secret 8

  # Spec 13 §11 A-13: a provider that echoes the Authorization header back in
  # its error body must not put the key in the transcript, the logs or a
  # screenshot.
  @doc false
  def redact(text) do
    text
    |> to_string()
    |> then(&Regex.replace(~r/sk-[A-Za-z0-9_\-]{4,}/, &1, "sk-***"))
    |> then(&Regex.replace(~r/Bearer\s+[A-Za-z0-9_\-\.]{4,}/i, &1, "Bearer ***"))
  end

  @doc """
  `redact/1`, plus the exact values the caller knows are secret (spec 33 §3).

  The patterns above only catch credentials that *look* like one. An MCP server
  is configured with arbitrary header and environment values — a bare
  `glpat-…`, a session cookie — and a server that echoes its own request back
  in an error body would put them in the transcript. Longest first, so a secret
  that contains another is replaced whole.
  """
  @spec redact(term(), [String.t()]) :: String.t()
  def redact(text, secrets) when is_list(secrets) do
    secrets
    |> Enum.map(&to_string/1)
    |> Enum.filter(&(byte_size(&1) >= @min_secret))
    |> Enum.uniq()
    |> Enum.sort_by(&(-byte_size(&1)))
    |> Enum.reduce(to_string(text), &String.replace(&2, &1, "[REDACTED]"))
    |> redact()
  end

  defp snippet(body) do
    body |> to_string() |> redact() |> String.replace(~r/\s+/, " ") |> String.slice(0, 300)
  end

  defp inspect_body(body) when is_binary(body), do: body

  defp inspect_body(body) do
    case Jason.encode(body) do
      {:ok, json} -> json
      _ -> inspect(body)
    end
  end

  # Jittered backoff: two agents that hit the same 429 do not come back in step.
  # Spec 51 §6.2 (a): the provider's `retry-after` raises the floor — asking
  # again before it expires only earns another 429 — and 90 s caps the lot.
  @doc false
  def backoff_ms(attempt, hint_ms \\ nil) do
    base = Enum.at(@retry_delays, attempt - 1, List.last(@retry_delays))
    jittered = round(base * (0.75 + :rand.uniform() * 0.5))
    min(max(jittered, hint_ms || 0), @max_sleep)
  end

  @doc false
  def sleep_fun, do: Application.get_env(:swarm_code_daemon, :llm_retry_sleep, &Process.sleep/1)
end
