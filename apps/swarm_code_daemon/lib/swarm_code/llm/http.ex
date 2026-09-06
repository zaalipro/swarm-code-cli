defmodule SwarmCode.LLM.HTTP do
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

  @max_attempts 5
  @retry_delays [1_000, 4_000, 15_000, 60_000]
  @retry_statuses [408, 409, 425, 429]
  @got_chunk_key :swarm_code_llm_got_chunk

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
  The default wall clock of one LLM call (spec 51 §6.2 (c)).

  Generous on purpose: a thinking model can pause well past a minute before its
  first token, and the per-chunk `receive_timeout` is the tighter bound anyway.
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
          pos_integer()
        ) :: {:ok, term()} | {:error, String.t()}
  def stream_post(
        url,
        headers,
        body,
        provider_name,
        init_acc,
        on_chunk,
        on_retry \\ nil,
        retry_if \\ nil,
        deadline_ms \\ default_deadline_ms()
      ) do
    started = System.monotonic_time(:millisecond)
    clock = Process.get({__MODULE__, :deadline}) || {started, started + deadline_ms}

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
      1
    )
  end

  @doc false
  def with_deadline(milliseconds, fun) do
    key = {__MODULE__, :deadline}
    previous = Process.get(key)
    now = System.monotonic_time(:millisecond)
    Process.put(key, previous || {now, now + milliseconds})

    try do
      fun.()
    after
      if previous, do: Process.put(key, previous), else: Process.delete(key)
    end
  end

  # Finch's receive timeout resets on each chunk. Keep the transport in an owned
  # process so the original absolute deadline also interrupts a silent socket.
  # Relay callbacks synchronously to the caller: its capability/retry state and
  # callback process identity remain unchanged, and at most one chunk is queued.
  defp owned_request(method, url, options, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, %Req.TransportError{reason: :timeout}}
    else
      start_owned_request(method, url, options, deadline)
    end
  end

  defp start_owned_request(method, url, options, deadline) do
    owner = self()
    token = make_ref()
    callback = Keyword.fetch!(options, :into)

    {worker, monitor} =
      spawn_monitor(fn ->
        transport = self()

        guardian =
          spawn(fn ->
            owner_monitor = Process.monitor(owner)
            transport_monitor = Process.monitor(transport)

            receive do
              {:DOWN, ^owner_monitor, :process, ^owner, _} -> Process.exit(transport, :kill)
              {:DOWN, ^transport_monitor, :process, ^transport, _} -> :ok
            end
          end)

        relay = fn data, pair ->
          send(owner, {token, :chunk, data, pair})

          receive do
            {^token, :continue, result} -> result
          end
        end

        try do
          result = Req.request(request(url), Keyword.merge(options, method: method, into: relay))
          send(owner, {token, :result, result})
        rescue
          exception -> send(owner, {token, :result, {:error, exception}})
        after
          Process.exit(guardian, :kill)
        end
      end)

    try do
      await_request(worker, monitor, token, callback, deadline)
    after
      Process.exit(worker, :kill)

      receive do
        {:DOWN, ^monitor, :process, ^worker, _} -> :ok
      end

      flush_request(token)
    end
  end

  defp await_request(worker, monitor, token, callback, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^token, :chunk, data, pair} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, %Req.TransportError{reason: :timeout}}
        else
          send(worker, {token, :continue, callback.(data, pair)})
          await_request(worker, monitor, token, callback, deadline)
        end

      {^token, :result, result} ->
        result

      {:DOWN, ^monitor, :process, ^worker, _reason} = down ->
        # Keep cleanup's single monitor settlement path, including unexpected exits.
        send(self(), down)
        {:error, %Req.TransportError{reason: :closed}}
    after
      remaining -> {:error, %Req.TransportError{reason: :timeout}}
    end
  end

  defp flush_request(token) do
    receive do
      {^token, :chunk, _, _} -> flush_request(token)
      {^token, :result, _} -> flush_request(token)
    after
      0 -> :ok
    end
  end

  defp credentials(headers) do
    for {name, value} <- headers,
        String.downcase(name) in ["authorization", "x-api-key"],
        do: String.replace_prefix(value, "Bearer ", "")
  end

  defp always_ok(_acc), do: :ok

  @redirect_statuses [301, 302, 303, 307, 308]

  @doc """
  spec 60 T10: the one request builder for credentialed calls. Same-origin redirects behave as
  before; a redirect to another `{scheme, host, port}` is not followed (Req forwards `x-api-key`,
  custom headers and the body — `deps/req/lib/req/steps.ex:1556-1564` strips `authorization` only).
  """
  @spec request(String.t()) :: Req.Request.t()
  def request(url) do
    Req.new(url: url, redirect_log_level: false)
    |> Req.Request.prepend_response_steps(swarm_code_redirect_guard: &guard_redirect/1)
  end

  @doc false
  def guard_redirect({request, %Req.Response{status: status} = response})
      when status in @redirect_statuses do
    with [location | _] <- Req.Response.get_header(response, "location"),
         %URI{host: host} = target when is_binary(host) <-
           URI.merge(request.url, URI.parse(location)),
         true <- origin(target) != origin(request.url) do
      Logger.warning("swarm_code: refused a cross-origin credentialed redirect")
      {Req.Request.put_option(request, :redirect, false), response}
    else
      _ -> {request, response}
    end
  end

  def guard_redirect(pair), do: pair

  defp origin(%URI{scheme: s, host: h, port: p}), do: {s, h, p || URI.default_port(s || "http")}

  defp do_stream(url, headers, body, name, init_acc, on_chunk, on_retry, retry_if, clock, attempt) do
    Process.delete(@got_chunk_key)
    {started, deadline} = clock

    max_bytes = Application.get_env(:swarm_code_daemon, :llm_max_response_bytes, 16_777_216)

    into = fn {:data, data}, {req, resp} ->
      received = Map.get(resp.private, :received_bytes, 0) + byte_size(data)
      resp = %{resp | private: Map.put(resp.private, :received_bytes, received)}

      if received > max_bytes do
        {:halt, {req, %{resp | private: Map.put(resp.private, :response_too_large, true)}}}
      else
        if resp.status == 200 do
          Process.put(@got_chunk_key, true)
          acc = on_chunk.(data, Map.get(resp.private, :acc, init_acc))
          resp = %{resp | private: Map.put(resp.private, :acc, acc)}

          # Spec 51 §6.2 (c): a stream that dribbles a keep-alive every few
          # hundred milliseconds never trips the per-chunk idle timeout. The
          # deadline is what ends it, and the 200 clause below turns the halt
          # into the same "gave up after" error a refused retry gives.
          if System.monotonic_time(:millisecond) > deadline do
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
          if System.monotonic_time(:millisecond) > deadline do
            {:halt, {req, %{resp | private: Map.put(resp.private, :past_deadline, true)}}}
          else
            {:cont, {req, resp}}
          end
        end
      end
    end

    result =
      owned_request(
        :post,
        url,
        [
          json: body,
          headers: headers,
          retry: false,
          # Spec 51 §6.2 (c): the per-chunk idle timeout never outlives the call's
          # own deadline, so a dribbling stream cannot run past it.
          receive_timeout: receive_timeout(deadline),
          connect_options: [timeout: min(15_000, receive_timeout(deadline))],
          into: into
        ],
        deadline
      )

    retry = fn reason, message, hint_ms, max_attempts ->
      now = System.monotonic_time(:millisecond)
      planned = backoff_ms(attempt, hint_ms)

      cond do
        attempt >= max_attempts ->
          {:error, "#{name} request failed after #{max_attempts} attempts: " <> message}

        # Spec 51 §6.2 (c): a retry that would land past the deadline is not a
        # retry, it is a hang the caller cannot see the end of.
        now + planned > deadline ->
          {:error, "#{name} gave up after #{div(now - started, 1000)} s: " <> message}

        true ->
          notify(on_retry, attempt + 1, reason, max_attempts)
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
            attempt + 1
          )
      end
    end

    case result do
      {:ok, %Req.Response{private: %{response_too_large: true}}} ->
        {:error, "#{name} response exceeded #{max_bytes} bytes"}

      {:ok, %Req.Response{status: 200, private: %{past_deadline: true}} = resp} ->
        retry.("deadline", "the stream was still open", retry_after_ms(resp), attempts())

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
        {:error,
         status_message(
           status,
           name,
           redact(error_body(resp), credentials(headers))
         )}

      {:error, exception} ->
        retry.("network", Exception.message(exception), nil, max_for(exception))
    end
  end

  defp receive_timeout(deadline) do
    min(120_000, max(deadline - System.monotonic_time(:millisecond), 1))
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

  # An exact secret may straddle the retention boundary. Never render a retained
  # prefix of a capped error body, even after whitespace normalization.
  defp error_body(%Req.Response{private: private}) do
    if Map.get(private, :received_bytes, 0) >= 65_536,
      do: "[response body omitted: size limit reached]",
      else: Map.get(private, :err_body, "")
  end

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

  defp reason_for(429), do: "rate limit"
  defp reason_for(_status), do: "network"

  @spec get_json(String.t(), [{String.t(), String.t()}], String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def get_json(url, headers, name) do
    max_bytes = Application.get_env(:swarm_code_daemon, :llm_max_response_bytes, 16_777_216)

    into = fn {:data, data}, {req, resp} ->
      acc = Map.get(resp.private, :json_chunks, SwarmCode.LLM.Chunks.new())

      if acc.size + byte_size(data) > max_bytes do
        {:halt, {req, %{resp | private: Map.put(resp.private, :response_too_large, true)}}}
      else
        acc = SwarmCode.LLM.Chunks.append(acc, data)
        {:cont, {req, %{resp | private: Map.put(resp.private, :json_chunks, acc)}}}
      end
    end

    deadline = System.monotonic_time(:millisecond) + 30_000

    case owned_request(
           :get,
           url,
           [headers: headers, retry: false, receive_timeout: 30_000, into: into],
           deadline
         ) do
      {:ok, %Req.Response{private: %{response_too_large: true}}} ->
        {:error, "#{name} response exceeded #{max_bytes} bytes"}

      {:ok, %Req.Response{status: status, private: private}} ->
        body =
          private
          |> Map.get(:json_chunks, SwarmCode.LLM.Chunks.new())
          |> SwarmCode.LLM.Chunks.to_string()

        if status == 200 do
          case Jason.decode(body) do
            {:ok, %{} = json} -> {:ok, json}
            _ -> {:error, "#{name} returned a non-JSON response"}
          end
        else
          {:error, status_message(status, name, redact(body, credentials(headers)))}
        end

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
    |> Enum.filter(&(byte_size(&1) > 0))
    |> Enum.uniq()
    |> Enum.sort_by(&(-byte_size(&1)))
    |> Enum.reduce(to_string(text), &String.replace(&2, &1, "[REDACTED]"))
    |> redact()
  end

  defp snippet(body) do
    body |> to_string() |> redact() |> String.replace(~r/\s+/, " ") |> String.slice(0, 300)
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
