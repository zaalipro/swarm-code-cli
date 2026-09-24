defmodule SwarmCode.Daemon.Service.Connection do
  @moduledoc false
  use GenServer, restart: :temporary
  require Logger

  alias SwarmCode.Daemon.Service.RequestRouter
  alias SwarmCode.Protocol.{Frame, FrameDecoder, Message, ServiceHandshake, ServiceRequest}

  # Requests in flight, not counting watches (bounded by @watches). pass73
  # T11: a pending watch used to take one of these, and the 33rd request of
  # any kind closed the connection; past the limit a request is now refused.
  @limit 32
  @watches 16
  # pass73 T11: request ids are refused when reused while recent. Every delta
  # the client consumes is acknowledged with a request of its own, so a fixed
  # budget of 4,096 ids per connection ran out in a busy session and closed it.
  @recent_ids 4_096
  # A client that leaves a frame half written is given this long. Our client
  # writes each frame in one send, so only a broken peer trips it.
  @partial_ms 2_000

  def start_link(config), do: GenServer.start_link(__MODULE__, config)

  @impl true
  def init(config) do
    {:ok, workers} = Task.Supervisor.start_link(max_children: @limit + @watches)
    token = make_ref()
    timer = Process.send_after(self(), {:handshake_timeout, token}, 2_000)

    {:ok,
     %{
       config: config,
       socket: nil,
       phase: :hello,
       decoder: FrameDecoder.new(),
       workers: workers,
       requests: %{},
       used: recent(),
       used_watches: recent(),
       watches: %{},
       partial_timer: nil,
       timer: timer,
       token: token,
       backend_monitor: Process.monitor(config.backend)
     }}
  end

  @impl true
  def handle_info({:socket, socket}, %{socket: nil} = state) do
    :ok = :inet.setopts(socket, active: :once)
    {:noreply, %{state | socket: socket}}
  end

  def handle_info({:tcp, socket, bytes}, %{socket: socket} = state) do
    with {:decode, {:ok, messages, decoder}} <-
           {:decode, FrameDecoder.push(state.decoder, bytes)},
         {:ok, state} <- consume(messages, track_partial(%{state | decoder: decoder}, messages)),
         {:arm, :ok} <- {:arm, :inet.setopts(socket, active: :once)} do
      {:noreply, state}
    else
      {:decode, {:error, reason}} ->
        closing("a frame did not decode (#{describe_reason(reason)})")
        {:stop, :normal, state}

      {:close, why} ->
        closing(why)
        {:stop, :normal, state}

      {:arm, reason} ->
        closing("the socket could not be re-armed (#{describe_reason(reason)})")
        {:stop, :normal, state}

      other ->
        closing("a frame could not be handled (#{describe_reason(other)})")
        {:stop, :normal, state}
    end
  end

  # pass73 T11: a write that failed (the client stopped reading past the send
  # timeout, or went away) ends the connection once, with its reason.
  def handle_info({:write_failed, why}, state) do
    closing("a frame could not be written (#{why})")
    {:stop, :normal, state}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.requests, ref) do
      {nil, _} ->
        {:noreply, state}

      {%{message: message, timer: timer, deadline: deadline}, requests} ->
        Process.demonitor(ref, [:flush])
        Process.cancel_timer(timer)
        state = %{state | requests: requests}

        case if(now() >= deadline, do: {:indeterminate, :deadline}, else: result) do
          {:watch, sequence, revision, kind, body} ->
            finish_watch(state, message, sequence, revision, kind, body)

          {:ok, body} when is_map(body) ->
            reply(state, message, :response, body)

          {:error, %{"op" => "error"} = body} ->
            reply(state, message, :error, body)

          {:indeterminate, reason} ->
            # pass70 C4: the backend call may have reached a mutation before
            # its caller failed. The request settles as unknown (a command) or
            # failed (a read); the connection and its watches stay.
            fail_request(state, message, reason)

          _ ->
            # An untyped backend failure proves no particular mutation outcome.
            fail_request(state, message, :untyped)
        end
    end
  end

  def handle_info({:service_delta, backend, ref, delta}, %{config: %{backend: backend}} = state) do
    case state.watches[ref] do
      %{phase: :ready} = entry ->
        sequence = entry.sequence + 1

        message =
          event(entry.scope, state.config.nonce, sequence, %{
            "op" => "delta",
            "watch_ref" => ref,
            "value" => Map.put(delta, "sequence", sequence)
          })

        with {:ok, frame} <- Frame.encode(message),
             size = IO.iodata_length(frame),
             true <- length(entry.in_flight) < 16 and entry.bytes + size <= 524_288,
             :ok <- send_frame(state.socket, frame) do
          entry = %{
            entry
            | sequence: sequence,
              bytes: entry.bytes + size,
              in_flight: entry.in_flight ++ [{sequence, size}]
          }

          {:noreply, %{state | watches: Map.put(state.watches, ref, entry)}}
        else
          {:error, reason} ->
            closing("a delta could not be sent: #{inspect(reason, limit: 20)}")
            {:stop, :normal, state}

          false ->
            # pass70 C4: a slow consumer loses this watch's backlog, never the
            # connection: the client re-snapshots the watch.
            {:noreply, require_snapshot(state, ref, "overflow")}

          _ ->
            closing("a delta could not be sent")
            {:stop, :normal, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  # pass70 C4: the backend dropped a watch's queue (overflow) or its content
  # changed wholesale (another conversation opened); the client re-snapshots.
  def handle_info({:service_overflow, backend, ref}, %{config: %{backend: backend}} = state) do
    if Map.has_key?(state.watches, ref),
      do: {:noreply, require_snapshot(state, ref, "overflow", false)},
      else: {:noreply, state}
  end

  def handle_info({:service_resync, backend, ref}, %{config: %{backend: backend}} = state) do
    if Map.has_key?(state.watches, ref),
      do: {:noreply, require_snapshot(state, ref, "epoch_changed", false)},
      else: {:noreply, state}
  end

  def handle_info({:request_timeout, ref}, state) do
    case Map.pop(state.requests, ref) do
      {nil, _} ->
        {:noreply, state}

      {%{task: task, message: message}, requests} ->
        # pass70 C4 (rel F4): one slow request fails alone; the connection
        # and every other request and watch carry on.
        Task.Supervisor.terminate_child(state.workers, task.pid)
        Process.demonitor(ref, [:flush])
        Logger.warning("SwarmCode daemon: a request timed out (#{describe(message)})")
        fail_request(%{state | requests: requests}, message, :deadline)
    end
  end

  def handle_info({:handshake_timeout, token}, %{phase: :hello, token: token} = state) do
    closing("the client did not complete the handshake in time")
    {:stop, :normal, state}
  end

  def handle_info({:partial_timeout, token}, %{partial_timer: {_, token}} = state) do
    closing("the client left a frame unfinished")
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{backend_monitor: ref} = state) do
    closing("the backend went away: #{inspect(reason, limit: 20)}")
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, state)
      when is_map_key(state.requests, ref) do
    {%{message: message, timer: timer}, requests} = Map.pop(state.requests, ref)
    Process.cancel_timer(timer)

    Logger.warning(
      "SwarmCode daemon: a request worker died (#{describe(message)}): " <>
        inspect(reason, limit: 40, printable_limit: 300)
    )

    fail_request(%{state | requests: requests}, message, :worker_down)
  end

  # pass73 T11: the client's own close is noted too (info: a quit does it), so
  # a log that ends a session always says which side closed.
  def handle_info({:tcp_closed, _socket}, state) do
    Logger.info(
      "SwarmCode daemon: the client closed its connection (#{map_size(state.watches)} watches, " <>
        "#{map_size(state.requests)} requests in flight)"
    )

    {:stop, :normal, state}
  end

  def handle_info({:tcp_error, _socket, reason}, state) do
    closing("socket error #{describe_reason(reason)}")
    {:stop, :normal, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  # A connection that closes on its own says why, once, at warning level:
  # the client only sees a closed socket, and a silent close on the daemon
  # side cannot be reported by anyone. The words name a check or an
  # operation, never a payload, nonce or text.
  defp closing(words),
    do: Logger.warning("SwarmCode daemon closed a client connection: " <> words)

  defp describe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp describe_reason(%{__exception__: true} = error), do: inspect(error.__struct__)
  defp describe_reason(%{code: code}) when is_atom(code), do: Atom.to_string(code)
  defp describe_reason({tag, _}) when is_atom(tag), do: Atom.to_string(tag)
  defp describe_reason(_), do: "unknown"

  defp describe(%Message{body: body}) when is_map(body),
    do:
      "#{Map.get(body, "operation", "?")} #{inspect(Map.get(body, "params", %{}) |> Map.take(["slot", "kind"]))}"

  defp describe(_message), do: "?"

  @impl true
  def terminate(_, state) do
    if state.socket, do: :gen_tcp.close(state.socket)
    Process.cancel_timer(state.timer)
    if state.partial_timer, do: Process.cancel_timer(elem(state.partial_timer, 0))
    Enum.each(state.requests, fn {_, request} -> Process.cancel_timer(request.timer) end)

    Enum.each(state.watches, fn {ref, _} ->
      send(state.config.backend, {:service_unwatch, self(), ref})
    end)

    if Process.alive?(state.workers), do: Supervisor.stop(state.workers, :normal, 3_000)
  end

  @impl true
  def format_status(status), do: %{status | state: %{phase: status.state.phase}}

  defp consume([], state), do: {:ok, state}

  defp consume([message | rest], state),
    do: with({:ok, state} <- receive_message(message, state), do: consume(rest, state))

  defp receive_message(
         %Message{type: :hello, scope: nil, sequence: nil, occurred_at: nil} = message,
         %{phase: :hello} = state
       ) do
    with {:nonce, true} <- {:nonce, secure_equal?(message.nonce, state.config.nonce)},
         {:ok, :hello} <- ServiceHandshake.decode_hello(message.body),
         {:ok, body} <-
           ServiceHandshake.encode_hello_ok(%ServiceHandshake.HelloOk{
             source_epoch: state.config.source_epoch,
             connection_id: uuid(),
             capabilities: state.config.capabilities,
             max_frame_bytes: 1_048_576
           }),
         :ok <- write(state, %{message | type: :hello_ok, body: body}) do
      Process.cancel_timer(state.timer)
      {:ok, %{state | phase: :ready}}
    else
      {:nonce, false} -> {:close, "the hello carried the wrong nonce"}
      _ -> {:close, "the handshake failed"}
    end
  end

  defp receive_message(
         %Message{type: :request, sequence: nil, occurred_at: nil} = message,
         %{phase: :ready} = state
       ) do
    with {:nonce, true} <- {:nonce, secure_equal?(message.nonce, state.config.nonce)},
         {:reused, false} <- {:reused, recent?(state.used, message.request_id)},
         {:decode, {:ok, request}} <-
           {:decode, ServiceRequest.decode(message.body, message.scope)},
         {:capability, true} <- {:capability, capability?(request, state)},
         {:watch, :ok} <- {:watch, watch_capacity(request, state)} do
      state = %{state | used: remember(state.used, message.request_id)}

      case request.operation do
        :ack ->
          handle_ack(message, request, state)

        :unwatch ->
          handle_unwatch(message, request, state)

        :watch ->
          start_request(message, request, state)

        operation ->
          if in_flight(state) < @limit do
            start_request(message, request, state)
          else
            Logger.warning(
              "SwarmCode daemon refused a request: #{@limit} already in flight (#{operation})"
            )

            {:ok, error_reply(state, message, "capacity_exceeded")}
          end
      end
    else
      {:nonce, false} -> {:close, "a request carried the wrong nonce"}
      {:reused, true} -> {:close, "a request reused a recent id"}
      {:decode, _} -> {:close, "a request did not decode (#{op_name(message.body)})"}
      {:capability, false} -> {:close, "a request needs a capability this session lacks"}
      {:watch, why} -> {:close, why}
    end
  end

  defp receive_message(%Message{type: type}, %{phase: phase}),
    do: {:close, "an unexpected #{type} frame in phase #{phase}"}

  defp op_name(%{"op" => op}) when is_binary(op) and byte_size(op) <= 32,
    do: String.replace(op, ~r/[^a-z_.]/, "")

  defp op_name(_), do: "?"

  defp in_flight(state),
    do: Enum.count(state.requests, fn {_, %{operation: operation}} -> operation != :watch end)

  # A bounded window of recent ids (pass73 T11): membership refuses a replay
  # while the id is recent; the oldest id leaves as a new one comes in.
  defp recent, do: %{set: MapSet.new(), order: :queue.new()}
  defp recent?(%{set: set}, id), do: MapSet.member?(set, id)

  defp remember(%{set: set, order: order} = window, id) do
    window = %{window | set: MapSet.put(set, id), order: :queue.in(id, order)}

    if MapSet.size(window.set) > @recent_ids do
      {{:value, oldest}, order} = :queue.out(window.order)
      %{window | set: MapSet.delete(window.set, oldest), order: order}
    else
      window
    end
  end

  defp start_request(message, request, state) do
    connection = self()
    backend = state.config.backend

    task =
      Task.Supervisor.async_nolink(
        state.workers,
        fn ->
          try do
            RequestRouter.call(
              backend,
              connection,
              message.request_id,
              message.scope,
              request
            )
          catch
            _, reason -> {:indeterminate, reason}
          end
        end,
        shutdown: :brutal_kill
      )

    timer = Process.send_after(self(), {:request_timeout, task.ref}, request.timeout_ms)

    next = %{
      state
      | requests:
          Map.put(state.requests, task.ref, %{
            message: message,
            operation: request.operation,
            task: task,
            timer: timer,
            deadline: now() + request.timeout_ms
          })
    }

    case request.operation do
      :watch ->
        ref = request.params["watch_ref"]
        entry = %{scope: message.scope, phase: :pending, request_id: message.request_id}

        {:ok,
         %{
           next
           | watches: Map.put(next.watches, ref, entry),
             used_watches: remember(next.used_watches, ref)
         }}

      _ ->
        {:ok, next}
    end
  end

  defp watch_capacity(%ServiceRequest{operation: :watch, params: params}, state) do
    cond do
      map_size(state.watches) >= @watches -> "a watch past the limit of #{@watches}"
      recent?(state.used_watches, params["watch_ref"]) -> "a watch reused its reference"
      true -> :ok
    end
  end

  defp watch_capacity(_, _), do: :ok

  defp capability?(%ServiceRequest{operation: operation, params: params}, state) do
    capability =
      case operation do
        op when op in [:feature_query, :agent_detail] ->
          :query

        :feature_command ->
          :feature_command

        :question_answer ->
          :question_answer

        op
        when op in [
               :query,
               :detail,
               :watch,
               :conversation_open,
               :conversation_list,
               :conversation_new,
               :mark_seen,
               :project_update
             ] ->
          operation

        op when op in [:ack, :unwatch, :resync] ->
          :watch

        :dispatch_send ->
          :dispatch_send

        :run_steer ->
          :run_steer

        :approval_resolve ->
          :approval_resolve

        :run_control ->
          Map.get(
            %{"pause" => :run_pause, "continue" => :run_continue, "stop" => :run_stop},
            params["action"]
          )

        _ ->
          nil
      end

    capability in state.config.capabilities
  end

  # pass73 T11: the root cause of "the daemon connection closed". When a watch
  # overflows, the daemon drops it and writes `snapshot_required` behind the
  # deltas already on the wire. A client whose delivery queue is full (several
  # live runs, a busy terminal) consumes those deltas and acknowledges them
  # before it has read that frame, so its acks name a watch that is already
  # gone. They were a protocol violation and closed the connection without a
  # word. An ack for a watch that is gone, not ready yet, or already past that
  # sequence is acknowledged and changes nothing.
  defp handle_ack(message, request, state) do
    watch_ref = request.params["watch_ref"]
    sequence = request.params["sequence"]

    case state.watches[watch_ref] do
      %{scope: scope} when scope != message.scope ->
        {:close, "an ack named another scope's watch"}

      %{phase: :ready, sequence: latest} when sequence > latest ->
        {:close, "an ack past the last delta sent"}

      %{phase: :ready, acked: acked} = entry when sequence > acked ->
        remaining = Enum.filter(entry.in_flight, fn {number, _} -> number > sequence end)

        entry = %{
          entry
          | acked: sequence,
            in_flight: remaining,
            bytes: Enum.reduce(remaining, 0, fn {_, value}, acc -> acc + value end)
        }

        send(state.config.backend, {:service_credit, self(), watch_ref, sequence})
        acknowledge(%{state | watches: Map.put(state.watches, watch_ref, entry)}, message)

      _stale_or_gone ->
        acknowledge(state, message)
    end
  end

  defp handle_unwatch(message, request, state) do
    watch_ref = request.params["watch_ref"]

    case state.watches[watch_ref] do
      nil ->
        acknowledge(state, message)

      %{scope: scope} when scope == message.scope ->
        send(state.config.backend, {:service_unwatch, self(), watch_ref})
        acknowledge(%{state | watches: Map.delete(state.watches, watch_ref)}, message)

      _ ->
        {:close, "an unwatch named another scope's watch"}
    end
  end

  defp acknowledge(state, message) do
    case write(state, %{message | type: :response, body: acknowledged()}) do
      :ok -> {:ok, state}
      {:error, reason} -> {:close, "an acknowledgement could not be written (#{reason})"}
    end
  end

  defp finish_watch(state, message, sequence, revision, kind, body) do
    ref = message.body["watch_ref"]

    if Map.has_key?(state.watches, ref) do
      publish_watch(state, message, ref, sequence, revision, kind, body)
    else
      # The request was unwatched while its backend snapshot was pending. Its
      # registration may have happened after the first unwatch was delivered.
      send(state.config.backend, {:service_unwatch, self(), ref})
      {:noreply, state}
    end
  end

  defp publish_watch(state, message, ref, sequence, revision, kind, body) do
    message =
      event(message.scope, state.config.nonce, sequence, %{
        "op" => "watch_ready",
        "watch_ref" => ref,
        "revision" => revision,
        "body_kind" => kind,
        "value" => body
      })

    if map_size(state.watches) <= 16 and Map.get(state.watches, ref, %{})[:phase] == :pending and
         write(state, message) == :ok do
      entry = %{
        scope: message.scope,
        sequence: sequence,
        acked: sequence,
        in_flight: [],
        bytes: 0,
        phase: :ready
      }

      send(state.config.backend, {:service_ready, self(), ref})
      {:noreply, %{state | watches: Map.put(state.watches, ref, entry)}}
    else
      size =
        case Frame.encode(message) do
          {:ok, frame} -> "#{IO.iodata_length(frame)} bytes"
          {:error, reason} -> "encode failed: #{inspect(reason, limit: 20)}"
        end

      closing(
        "a watch snapshot could not be published (#{kind}, #{size}, " <>
          "#{map_size(state.watches)} watches, phase #{inspect(Map.get(state.watches, ref, %{})[:phase])})"
      )

      {:stop, :normal, state}
    end
  end

  @messages %{
    "capacity_exceeded" => "data source admission capacity exceeded",
    "deadline_expired" => "request deadline has expired",
    "source_unavailable" => "data source is unavailable"
  }

  # pass70 C4: settle one request without closing the connection. A command
  # may have reached its mutation, so it reads `outcome_unknown` (the client
  # refreshes); a read fails with a typed error. A watch that never became
  # ready is dropped and its client is told to re-snapshot.
  defp fail_request(state, %Message{body: body} = message, reason) do
    operation =
      case ServiceRequest.decode(body, message.scope) do
        {:ok, request} -> request.operation
        _ -> nil
      end

    code = if reason == :deadline, do: "deadline_expired", else: "source_unavailable"

    cond do
      # A watch has no reply frame but its snapshot: the client re-watches.
      operation == :watch ->
        {:noreply, require_snapshot(state, body["watch_ref"], "overflow")}

      operation in [:query, :detail, :feature_query, :conversation_list, :agent_detail, nil] ->
        {:noreply, error_reply(state, message, code)}

      true ->
        value = %{
          "status" => "outcome_unknown",
          "request_id" => message.request_id,
          "identifiers" => [],
          "interaction" => nil,
          "error" => %{
            "code" => "source_unavailable",
            "message" => @messages["source_unavailable"]
          },
          "corrective_action" => "refresh"
        }

        case write(state, %{
               message
               | type: :response,
                 body: %{"op" => "result", "response_kind" => "outcome", "value" => value}
             }) do
          :ok ->
            {:noreply, state}

          {:error, why} ->
            closing("an unknown outcome could not be written (#{describe(message)}: #{why})")
            {:stop, :normal, state}
        end
    end
  end

  # A failed write here posts `{:write_failed, why}` (see `send_frame/2`),
  # which closes the connection with its reason.
  defp error_reply(state, message, code) do
    body = %{"op" => "error", "code" => code, "message" => @messages[code]}
    _ = write(state, %{message | type: :error, body: body})
    state
  end

  # The client re-watches on `snapshot_required`; its backlog here is gone.
  defp require_snapshot(state, ref, reason, unwatch? \\ true) do
    case state.watches[ref] do
      %{scope: scope} = entry ->
        if unwatch?, do: send(state.config.backend, {:service_unwatch, self(), ref})

        message = %Message{
          version: 1,
          type: :snapshot_required,
          request_id: nil,
          nonce: state.config.nonce,
          scope: scope,
          sequence: Map.get(entry, :sequence, 0) + 1,
          occurred_at: DateTime.to_iso8601(DateTime.utc_now()),
          body: %{"op" => "snapshot_required", "watch_ref" => ref, "reason" => reason}
        }

        _ = write(state, message)
        %{state | watches: Map.delete(state.watches, ref)}

      _ ->
        state
    end
  end

  defp event(scope, nonce, sequence, body),
    do: %Message{
      version: 1,
      type: :event,
      request_id: nil,
      nonce: nonce,
      scope: scope,
      sequence: sequence,
      occurred_at: DateTime.to_iso8601(DateTime.utc_now()),
      body: body
    }

  # pass73 T11: a reply that cannot be encoded (a body past the frame limit)
  # fails its own request; only a socket that cannot be written ends the
  # connection, and it says so.
  defp reply(state, message, type, body) do
    case write(state, %{message | type: type, body: body}) do
      :ok ->
        {:noreply, state}

      {:error, {:encode, why}} ->
        Logger.warning(
          "SwarmCode daemon: a reply could not be encoded (#{describe(message)}: #{why}); " <>
            "the request fails alone"
        )

        fail_request(state, message, :untyped)

      {:error, why} ->
        closing("a reply could not be written (#{describe(message)}: #{why})")
        {:stop, :normal, state}
    end
  end

  defp acknowledged, do: %{"op" => "result", "response_kind" => "acknowledged", "value" => %{}}

  defp track_partial(state, messages) do
    complete = state.decoder.phase == :header and state.decoder.buffered_bytes == 0

    if complete or messages != [] do
      if state.partial_timer, do: Process.cancel_timer(elem(state.partial_timer, 0))
      arm_partial(%{state | partial_timer: nil}, complete)
    else
      arm_partial(state, false)
    end
  end

  defp arm_partial(%{partial_timer: nil} = state, false) do
    token = make_ref()
    timer = Process.send_after(self(), {:partial_timeout, token}, @partial_ms)
    %{state | partial_timer: {timer, token}}
  end

  defp arm_partial(state, _), do: state
  defp now, do: System.monotonic_time(:millisecond)

  defp write(state, message) do
    case Frame.encode(message) do
      {:ok, frame} -> send_frame(state.socket, frame)
      {:error, reason} -> {:error, {:encode, describe_reason(reason)}}
    end
  end

  # Every socket write goes through here. A failure is returned to the caller
  # and also posted to this process, so a caller that cannot stop on its own
  # (a snapshot request, an error reply) still ends the connection with its
  # reason rather than leaving a dead socket to be found later.
  defp send_frame(socket, frame) do
    case :gen_tcp.send(socket, frame) do
      :ok ->
        :ok

      {:error, reason} ->
        why = describe_reason(reason)
        send(self(), {:write_failed, why})
        {:error, why}
    end
  end

  defp secure_equal?(a, b) when is_binary(a) and is_binary(b) and byte_size(a) == byte_size(b) do
    :crypto.hash_equals(a, b)
  end

  defp secure_equal?(_, _), do: false

  defp uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    [hex(a, 8), hex(b, 4), hex(c, 4), hex(d, 4), hex(e, 12)] |> Enum.join("-")
  end

  defp hex(number, size),
    do: number |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(size, "0")
end
