defmodule SwarmCode.Daemon.Service.Connection do
  @moduledoc false
  use GenServer, restart: :temporary
  require Logger

  alias SwarmCode.Daemon.Service.RequestRouter
  alias SwarmCode.Protocol.{Frame, FrameDecoder, Message, ServiceHandshake, ServiceRequest}

  @limit 32
  # A client that leaves a frame half written is given this long. Our client
  # writes each frame in one send, so only a broken peer trips it.
  @partial_ms 2_000

  def start_link(config), do: GenServer.start_link(__MODULE__, config)

  @impl true
  def init(config) do
    {:ok, workers} = Task.Supervisor.start_link(max_children: @limit)
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
       used: MapSet.new(),
       used_watches: MapSet.new(),
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
    with {:ok, messages, decoder} <- FrameDecoder.push(state.decoder, bytes),
         {:ok, state} <- consume(messages, track_partial(%{state | decoder: decoder}, messages)),
         :ok <- :inet.setopts(socket, active: :once) do
      {:noreply, state}
    else
      _ -> {:stop, :normal, state}
    end
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
             :ok <- :gen_tcp.send(state.socket, frame) do
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

  def handle_info({:tcp_closed, _socket}, state), do: {:stop, :normal, state}
  def handle_info({:tcp_error, _socket, _reason}, state), do: {:stop, :normal, state}
  def handle_info(_, state), do: {:noreply, state}

  # A connection that closes on its own says why, once, at warning level:
  # the client only sees a closed socket, and a silent close on the daemon
  # side cannot be reported by anyone.
  defp closing(words),
    do: Logger.warning("SwarmCode daemon closed a client connection: " <> words)

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
    with true <- secure_equal?(message.nonce, state.config.nonce),
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
      _ -> :error
    end
  end

  defp receive_message(
         %Message{type: :request, sequence: nil, occurred_at: nil} = message,
         %{phase: :ready} = state
       ) do
    with true <- secure_equal?(message.nonce, state.config.nonce),
         false <- MapSet.member?(state.used, message.request_id),
         true <- map_size(state.requests) < @limit and MapSet.size(state.used) < 4096,
         {:ok, request} <- ServiceRequest.decode(message.body, message.scope),
         true <- capability?(request, state),
         true <- watch_capacity?(request, state) do
      case request.operation do
        :ack ->
          handle_ack(message, request, %{state | used: MapSet.put(state.used, message.request_id)})

        :unwatch ->
          handle_unwatch(message, request, %{
            state
            | used: MapSet.put(state.used, message.request_id)
          })

        _ ->
          start_request(message, request, state)
      end
    else
      _ -> :error
    end
  end

  defp receive_message(_, _), do: :error

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
            task: task,
            timer: timer,
            deadline: now() + request.timeout_ms
          }),
        used: MapSet.put(state.used, message.request_id)
    }

    case request.operation do
      :watch ->
        ref = request.params["watch_ref"]
        entry = %{scope: message.scope, phase: :pending, request_id: message.request_id}

        {:ok,
         %{
           next
           | watches: Map.put(next.watches, ref, entry),
             used_watches: MapSet.put(next.used_watches, ref)
         }}

      _ ->
        {:ok, next}
    end
  end

  defp watch_capacity?(%ServiceRequest{operation: :watch, params: params}, state),
    do:
      map_size(state.watches) < 16 and not MapSet.member?(state.used_watches, params["watch_ref"])

  defp watch_capacity?(_, _), do: true

  defp capability?(%ServiceRequest{operation: operation, params: params}, state) do
    capability =
      case operation do
        :feature_query ->
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

  defp handle_ack(message, request, state) do
    watch_ref = request.params["watch_ref"]
    sequence = request.params["sequence"]

    case state.watches[watch_ref] do
      %{scope: scope, sequence: latest, acked: acked} = entry
      when scope == message.scope and sequence > acked and sequence <= latest ->
        remaining = Enum.filter(entry.in_flight, fn {number, _} -> number > sequence end)

        entry = %{
          entry
          | acked: sequence,
            in_flight: remaining,
            bytes: Enum.reduce(remaining, 0, fn {_, value}, acc -> acc + value end)
        }

        send(state.config.backend, {:service_credit, self(), watch_ref, sequence})

        with :ok <- write(state, %{message | type: :response, body: acknowledged()}) do
          {:ok, %{state | watches: Map.put(state.watches, watch_ref, entry)}}
        end

      _ ->
        :error
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
        :error
    end
  end

  defp acknowledge(state, message) do
    with :ok <- write(state, %{message | type: :response, body: acknowledged()}), do: {:ok, state}
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

      operation in [:query, :detail, :feature_query, :conversation_list, nil] ->
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
          :ok -> {:noreply, state}
          _ -> {:stop, :normal, state}
        end
    end
  end

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

  defp reply(state, message, type, body) do
    if write(state, %{message | type: type, body: body}) == :ok,
      do: {:noreply, state},
      else: {:stop, :normal, state}
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
    with {:ok, frame} <- Frame.encode(message), do: :gen_tcp.send(state.socket, frame)
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
