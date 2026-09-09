defmodule SwarmCodeCLI.UI.DataSource.Daemon do
  @moduledoc """
  Client-owned, bounded Unix socket transport.

  Endpoint and nonce must come from an admitted launcher. This module does not
  authenticate peer credentials or launch a daemon. Watch credit is released only
  after the bound owner consumes its delivery receipt.
  """
  use GenServer
  @behaviour SwarmCodeCLI.UI.DataSource

  alias SwarmCode.Protocol.{Frame, FrameDecoder, Message, ServiceHandshake, ServiceRequest}
  alias SwarmCodeCLI.UI.Intent
  alias SwarmCodeCLI.UI.DataSource
  alias SwarmCodeCLI.UI.DataSource.{AdmissionError, Delivery, DTO, Request, Watch}
  alias SwarmCodeCLI.UI.DataSource.Daemon.Codec

  @max_watches 16
  @max_controls 256
  @max_deliveries 32
  @max_wire_bytes 1_048_576
  @max_decoded_bytes 2_097_152

  @impl true
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  @impl true
  defdelegate bind_owner(server, owner, ref), to: DataSource
  @impl true
  defdelegate watch(server, watch), to: DataSource
  @impl true
  defdelegate unwatch(server, ref), to: DataSource
  @impl true
  defdelegate query(server, request), to: DataSource
  @impl true
  defdelegate command(server, request), to: DataSource
  @impl true
  defdelegate cancel(server, id), to: DataSource
  @impl true
  defdelegate consume(server, receipt, disposition), to: DataSource
  @impl true
  defdelegate close(server), to: DataSource

  @impl true
  def init(opts) do
    with true <- valid_options?(opts),
         hello = envelope(:hello, uuid(), opts[:nonce], nil, ServiceHandshake.hello()),
         {:ok, _} <- Frame.encode(hello) do
      {:ok,
       %{
         phase: :unbound,
         path: opts[:socket_path],
         nonce: opts[:nonce],
         epoch: opts[:source_epoch],
         timeout: Keyword.get(opts, :timeout, 1_000),
         socket: nil,
         owner: nil,
         owner_monitor: nil,
         binding: nil,
         hello: hello,
         timer: nil,
         decoder: FrameDecoder.new(),
         partial_since: nil,
         capabilities: [],
         frame_limit: @max_wire_bytes,
         watches: %{},
         used_watches: MapSet.new(),
         controls: %{},
         requests: %{},
         used_requests: MapSet.new(),
         retired_requests: %{},
         queue: :queue.new(),
         receipt: nil,
         delivery_count: 0,
         wire_bytes: 0,
         decoded_bytes: 0,
         closed_notified: false
       }}
    else
      _ -> {:stop, AdmissionError.new(:invalid_request)}
    end
  end

  @impl true
  def handle_call(:close, _from, state), do: {:reply, :ok, shutdown(state)}

  def handle_call({:bind, _, _}, _from, %{phase: :closed} = state),
    do: {:reply, {:error, :closed}, state}

  def handle_call({:bind, _, _}, _from, %{phase: phase} = state) when phase != :unbound,
    do: {:reply, {:error, :already_bound}, state}

  def handle_call({:bind, owner, ref}, from, state) do
    if is_pid(owner) and node(owner) == node() and Process.alive?(owner) and Intent.valid_id?(ref) do
      monitor = Process.monitor(owner)
      state = %{state | owner: owner, owner_monitor: monitor, binding: {from, ref}}

      options = [
        :binary,
        active: false,
        packet: :raw,
        send_timeout: state.timeout,
        send_timeout_close: true,
        buffer: 65_536
      ]

      case :gen_tcp.connect({:local, state.path}, 0, options, state.timeout) do
        {:ok, socket} ->
          state = %{state | socket: socket, phase: :binding}

          case write(state, state.hello) do
            :ok ->
              :ok = :inet.setopts(socket, active: :once)
              token = make_ref()
              timer = Process.send_after(self(), {:deadline, token}, state.timeout)
              {:noreply, %{state | timer: {timer, token}}}

            _ ->
              {:noreply, shutdown(state)}
          end

        _ ->
          {:noreply, shutdown(state)}
      end
    else
      {:reply, {:error, :binding_failed}, state}
    end
  end

  def handle_call({:consume, token, disposition}, {caller, _}, state) do
    case state.receipt do
      %{token: ^token, item: item} when caller == state.owner and disposition == :applied ->
        state = release_receipt(state, item)

        case credit(state, item) do
          {:ok, next} -> {:reply, :ok, next |> dispatch_next() |> arm()}
          :error -> {:reply, {:error, AdmissionError.new(:source_unavailable)}, shutdown(state)}
        end

      %{token: ^token} when caller == state.owner and disposition == :discarded ->
        {:reply, :ok, shutdown(state)}

      _ ->
        {:reply, {:error, AdmissionError.new(:invalid_request)}, state}
    end
  end

  def handle_call(_request, _from, %{phase: phase} = state) when phase != :bound,
    do: failure(if(phase == :closed, do: :closed, else: :not_bound), state)

  def handle_call({:watch, value}, _from, state) do
    with {:ok, watch} <- Watch.validate(value),
         true <- :watch in state.capabilities,
         false <- MapSet.member?(state.used_watches, watch.watch_ref),
         true <- map_size(state.watches) < @max_watches and MapSet.size(state.used_watches) < 256,
         {:ok, message} <- Codec.watch_request(watch, uuid(), state.nonce, state.timeout),
         :ok <- write(state, message) do
      entry = %{
        watch: watch,
        sequence: nil,
        acked: nil,
        phase: :pending,
        wire_id: message.request_id
      }

      {:reply, :ok,
       %{
         state
         | watches: Map.put(state.watches, watch.watch_ref, entry),
           used_watches: MapSet.put(state.used_watches, watch.watch_ref)
       }}
    else
      _ -> failure(:invalid_watch, state)
    end
  end

  def handle_call({:unwatch, ref}, _from, state) do
    case state.watches[ref] do
      nil ->
        {:reply, :ok, state}

      entry ->
        case control(state, entry.watch.scope, %{"op" => "unwatch", "watch_ref" => ref}) do
          {:ok, next} -> {:reply, :ok, %{next | watches: Map.delete(next.watches, ref)}}
          :error -> {:reply, :ok, shutdown(state)}
        end
    end
  end

  def handle_call({:request, kind, value}, _from, state) when kind in [:query, :command] do
    with {:ok, request} <- Request.validate(value),
         true <- kind == :command == (request.expected_response == :outcome),
         :ok <-
           admit_check(
             not MapSet.member?(state.used_requests, request.request_id),
             :request_conflict
           ),
         :ok <-
           admit_check(
             MapSet.size(state.used_requests) < 256 and
               map_size(state.requests) + state.delivery_count < @max_deliveries,
             :capacity_exceeded
           ),
         {:ok, message} <-
           Codec.request(request, wire_id(request.request_id), state.nonce, now()),
         true <- request_capability(message.body) in state.capabilities do
      entry = %{request: request, kind: kind, deadline: request.deadline}

      next = %{
        state
        | requests: Map.put(state.requests, message.request_id, entry),
          used_requests: MapSet.put(state.used_requests, request.request_id)
      }

      # Once a socket write is attempted a mutation may have reached the daemon.
      # Reserve its correlation first and settle uncertain delivery on write error.
      case write(next, message) do
        :ok -> {:reply, :ok, next}
        _ -> {:reply, :ok, shutdown(next)}
      end
    else
      {:error, %AdmissionError{} = error} -> {:reply, {:error, error}, state}
      false -> failure(:invalid_request, state)
      true -> failure(:request_conflict, state)
      _ -> failure(:invalid_request, state)
    end
  end

  def handle_call({:cancel, _}, _from, state), do: failure(:not_allowed, state)
  def handle_call(_, _from, state), do: failure(:invalid_request, state)

  @impl true
  def handle_info({:tcp, socket, bytes}, %{socket: socket} = state) do
    case FrameDecoder.push(state.decoder, bytes) do
      {:ok, messages, decoder} ->
        partial =
          if decoder.phase == :header and decoder.buffered_bytes == 0,
            do: nil,
            else: state.partial_since || now()

        next =
          Enum.reduce_while(
            messages,
            %{state | decoder: decoder, partial_since: partial},
            fn message, acc ->
              case receive_message(message, acc) do
                {:ok, next} -> {:cont, next}
                :error -> {:halt, shutdown(acc)}
              end
            end
          )

        {:noreply, next |> dispatch_next() |> arm()}

      _ ->
        {:noreply, shutdown(state)}
    end
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state),
    do: {:noreply, shutdown(state)}

  def handle_info({:tcp_error, socket, _}, %{socket: socket} = state),
    do: {:noreply, shutdown(state)}

  def handle_info({:DOWN, monitor, :process, _, _}, %{owner_monitor: monitor} = state),
    do: {:noreply, shutdown(state)}

  def handle_info({:deadline, token}, %{timer: {_, token}, phase: :binding} = state),
    do: {:noreply, shutdown(state)}

  def handle_info({:deadline, token}, %{timer: {_, token}, phase: :bound} = state) do
    expired =
      (state.partial_since != nil and now() - state.partial_since >= state.timeout) or
        Enum.any?(state.controls, fn {_, control} -> control.deadline <= now() end) or
        (state.receipt != nil and state.receipt.deadline <= now())

    if expired do
      {:noreply, shutdown(state)}
    else
      next = expire_requests(state)
      {:noreply, next |> dispatch_next() |> schedule_tick()}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    if state.socket, do: :gen_tcp.close(state.socket)
    :ok
  end

  @impl true
  def format_status(status), do: %{status | state: %{phase: status.state.phase}}

  defp receive_message(message, %{phase: :binding} = state) do
    with %Message{type: :hello_ok, sequence: nil, occurred_at: nil, scope: nil} <- message,
         true <- message.request_id == state.hello.request_id and message.nonce == state.nonce,
         {:ok, hello} <- ServiceHandshake.decode_hello_ok(message.body),
         true <- state.epoch == nil or state.epoch == hello.source_epoch do
      {from, ref} = state.binding
      GenServer.reply(from, {:ok, ref})
      cancel_timer(state.timer)

      {:ok,
       schedule_tick(%{
         state
         | phase: :bound,
           binding: nil,
           epoch: hello.source_epoch,
           capabilities: hello.capabilities,
           frame_limit: hello.max_frame_bytes
       })}
    else
      _ -> :error
    end
  end

  defp receive_message(%Message{type: type} = message, %{phase: :bound} = state)
       when type in [:response, :error] and is_map_key(state.requests, message.request_id) do
    %{request: request} = state.requests[message.request_id]

    if message.nonce != state.nonce or message.scope != request.scope or
         message.sequence != nil or message.occurred_at != nil do
      {:ok, shutdown(state)}
    else
      receive_reply(message, request, state)
    end
  end

  defp receive_message(%Message{type: type, request_id: id} = message, %{phase: :bound} = state)
       when type in [:response, :error] and is_map_key(state.retired_requests, id) do
    if message.nonce == state.nonce, do: {:ok, state}, else: :error
  end

  defp receive_message(%Message{type: :response} = message, %{phase: :bound} = state) do
    case state.controls[message.request_id] do
      %{scope: scope} ->
        if message.nonce == state.nonce and message.scope == scope and
             message.sequence == nil and message.occurred_at == nil and
             message.body == %{
               "op" => "result",
               "response_kind" => "acknowledged",
               "value" => %{}
             } do
          {:ok, %{state | controls: Map.delete(state.controls, message.request_id)}}
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp receive_message(%Message{type: :event} = message, %{phase: :bound} = state) do
    ref = message.body["watch_ref"]

    with %{watch: watch} = entry <- state.watches[ref],
         {:ok, delivery} <- Codec.event(message, watch, state.nonce),
         true <- admissible_sequence?(entry, delivery),
         {:ok, frame} <- Frame.encode(message),
         bytes = IO.iodata_length(frame),
         decoded = :erlang.external_size(delivery),
         true <- state.delivery_count < @max_deliveries,
         true <- bytes + state.wire_bytes <= @max_wire_bytes,
         true <- decoded + state.decoded_bytes <= @max_decoded_bytes do
      sequence = if delivery.kind == :watch_ready, do: message.sequence, else: delivery.sequence
      entry = %{entry | phase: :ready, sequence: sequence}
      item = %{delivery: delivery, wire_bytes: bytes, decoded_bytes: decoded}

      {:ok,
       %{
         state
         | watches: Map.put(state.watches, ref, entry),
           queue: :queue.in(item, state.queue),
           delivery_count: state.delivery_count + 1,
           wire_bytes: state.wire_bytes + bytes,
           decoded_bytes: state.decoded_bytes + decoded
       }}
    else
      _ -> :error
    end
  end

  defp receive_message(_, _), do: :error

  defp receive_reply(message, request, state) do
    case Codec.response(message, request, message.request_id, state.nonce) do
      {:ok, delivery} ->
        {:ok, frame} = Frame.encode(message)

        queue_delivery(
          %{state | requests: Map.delete(state.requests, message.request_id)},
          delivery,
          IO.iodata_length(frame)
        )

      {:error, %AdmissionError{} = error} ->
        if message.type == :error and
             message.body == %{
               "op" => "error",
               "code" => Atom.to_string(error.code),
               "message" => error.message
             } do
          delivery = failure_delivery(request, error, :rejected, state.epoch)

          queue_delivery(
            %{state | requests: Map.delete(state.requests, message.request_id)},
            delivery,
            0
          )
        else
          {:ok, shutdown(state)}
        end

      _ ->
        :error
    end
  end

  defp admissible_sequence?(%{phase: :pending}, %Delivery{kind: :watch_ready}), do: true

  defp admissible_sequence?(%{phase: :ready, sequence: n}, %Delivery{kind: :delta, sequence: next}),
       do: next == n + 1

  defp admissible_sequence?(_, _), do: false

  defp dispatch_next(%{phase: phase, receipt: nil} = state) when phase in [:bound, :closed] do
    case :queue.out(state.queue) do
      {{:value, item}, queue} ->
        if item.delivery.kind == :response or Map.has_key?(state.watches, item.delivery.watch_ref) do
          token = make_ref()
          send(state.owner, {:swarm_code_ui_data, state.epoch, token, item.delivery})

          %{
            state
            | queue: queue,
              receipt: %{token: token, item: item, deadline: now() + state.timeout}
          }
        else
          dispatch_next(release_receipt(%{state | queue: queue}, item))
        end

      {:empty, _} ->
        notify_closed(state)
    end
  end

  defp dispatch_next(state), do: state

  defp notify_closed(%{phase: :closed, closed_notified: false} = state) do
    if is_pid(state.owner) and Process.alive?(state.owner),
      do: send(state.owner, {:swarm_code_ui_closed, self(), state.epoch})

    %{state | closed_notified: true}
  end

  defp notify_closed(state), do: state

  defp release_receipt(state, item),
    do: %{
      state
      | receipt: nil,
        delivery_count: state.delivery_count - 1,
        wire_bytes: state.wire_bytes - item.wire_bytes,
        decoded_bytes: state.decoded_bytes - item.decoded_bytes
    }

  defp credit(state, %{delivery: %Delivery{kind: :delta, watch_ref: ref, sequence: sequence}}) do
    case state.watches[ref] do
      nil ->
        {:ok, state}

      entry ->
        if sequence <= entry.sequence and (entry.acked == nil or sequence > entry.acked) do
          case control(state, entry.watch.scope, %{
                 "op" => "ack",
                 "watch_ref" => ref,
                 "sequence" => sequence
               }) do
            {:ok, next} -> {:ok, put_in(next.watches[ref].acked, sequence)}
            :error -> :error
          end
        else
          :error
        end
    end
  end

  defp credit(state, _), do: {:ok, state}

  defp control(state, scope, body) do
    body = Map.put(body, "timeout_ms", state.timeout)
    id = uuid()

    with true <- map_size(state.controls) < @max_controls,
         {:ok, _} <- ServiceRequest.decode(body, scope),
         :ok <- write(state, envelope(:request, id, state.nonce, scope, body)) do
      {:ok,
       %{
         state
         | controls: Map.put(state.controls, id, %{scope: scope, deadline: now() + state.timeout})
       }}
    else
      _ -> :error
    end
  end

  defp arm(%{phase: :bound, socket: socket} = state) do
    if state.delivery_count < @max_deliveries and state.wire_bytes < @max_wire_bytes and
         state.decoded_bytes < @max_decoded_bytes do
      case :inet.setopts(socket, active: :once) do
        :ok -> state
        _ -> shutdown(state)
      end
    else
      state
    end
  end

  defp arm(%{phase: :binding, socket: socket} = state) do
    case :inet.setopts(socket, active: :once) do
      :ok -> state
      _ -> shutdown(state)
    end
  end

  defp arm(state), do: state

  defp shutdown(%{phase: :closed} = state), do: state

  defp shutdown(state) do
    if state.socket, do: :gen_tcp.close(state.socket)
    cancel_timer(state.timer)
    if state.owner_monitor, do: Process.demonitor(state.owner_monitor, [:flush])

    if state.binding do
      {from, _} = state.binding
      GenServer.reply(from, {:error, :binding_failed})
    end

    pending = state.requests
    state = %{state | requests: %{}}

    # A closed transport must settle every request that was written.  When a
    # watch floods the bounded delivery queue, retaining buffered deltas can
    # consume the only slots needed for those terminal outcomes.  Keep the
    # in-flight receipt (the owner still has to consume it), retain already
    # queued responses, and discard only watch deltas; the next connection will
    # resnapshot the watch from its last acknowledged sequence.
    state = retain_shutdown_responses(state)

    state =
      if is_pid(state.owner) and Process.alive?(state.owner) do
        Enum.reduce(pending, state, fn {_, entry}, acc ->
          status = if entry.kind == :command, do: :outcome_unknown, else: :interrupted

          delivery =
            failure_delivery(
              entry.request,
              AdmissionError.new(:source_unavailable),
              status,
              state.epoch
            )

          case queue_delivery(acc, delivery, 0) do
            {:ok, next} -> next
            :error -> acc
          end
        end)
      else
        %{
          state
          | queue: :queue.new(),
            receipt: nil,
            delivery_count: 0,
            wire_bytes: 0,
            decoded_bytes: 0
        }
      end

    %{
      state
      | phase: :closed,
        socket: nil,
        binding: nil,
        owner_monitor: nil,
        watches: %{},
        controls: %{},
        timer: nil
    }
    |> dispatch_next()
  end

  defp retain_shutdown_responses(%{receipt: receipt} = state) do
    kept =
      state.queue
      |> :queue.to_list()
      |> Enum.filter(fn %{delivery: delivery} -> delivery.kind == :response end)

    receipt_bytes = if receipt, do: receipt.item.wire_bytes, else: 0
    receipt_decoded = if receipt, do: receipt.item.decoded_bytes, else: 0

    kept
    |> Enum.reduce(
      %{
        state
        | queue: :queue.new(),
          delivery_count: if(receipt, do: 1, else: 0),
          wire_bytes: receipt_bytes,
          decoded_bytes: receipt_decoded
      },
      fn item, acc ->
        %{
          acc
          | queue: :queue.in(item, acc.queue),
            delivery_count: acc.delivery_count + 1,
            wire_bytes: acc.wire_bytes + item.wire_bytes,
            decoded_bytes: acc.decoded_bytes + item.decoded_bytes
        }
      end
    )
  end

  defp write(state, message) do
    with {:ok, frame} <- Frame.encode(message),
         true <- IO.iodata_length(frame) - 4 <= state.frame_limit do
      :gen_tcp.send(state.socket, frame)
    else
      _ -> {:error, :invalid_frame}
    end
  end

  defp schedule_tick(state) do
    token = make_ref()
    timer = Process.send_after(self(), {:deadline, token}, min(state.timeout, 100))
    %{state | timer: {timer, token}}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer({timer, _}), do: Process.cancel_timer(timer)
  defp failure(code, state), do: {:reply, {:error, AdmissionError.new(code)}, state}
  defp now, do: System.monotonic_time(:millisecond)
  defp admit_check(true, _), do: :ok
  defp admit_check(false, code), do: {:error, AdmissionError.new(code)}
  defp request_capability(%{"op" => "query"}), do: :query
  defp request_capability(%{"op" => "feature.query"}), do: :query
  defp request_capability(%{"op" => "feature.command"}), do: :feature_command
  defp request_capability(%{"op" => "question.answer"}), do: :question_answer
  defp request_capability(%{"op" => "detail"}), do: :detail
  defp request_capability(%{"op" => "dispatch"}), do: :dispatch_send
  defp request_capability(%{"op" => "run.control", "action" => "pause"}), do: :run_pause
  defp request_capability(%{"op" => "run.control", "action" => "continue"}), do: :run_continue
  defp request_capability(%{"op" => "run.control", "action" => "stop"}), do: :run_stop
  defp request_capability(%{"op" => "run.steer"}), do: :run_steer
  defp request_capability(%{"op" => "approval.resolve"}), do: :approval_resolve
  defp request_capability(_), do: nil

  defp expire_requests(state) do
    {expired, pending} =
      Enum.split_with(state.requests, fn {_, entry} -> entry.deadline <= now() end)

    Enum.reduce(expired, %{state | requests: Map.new(pending)}, fn {wire_id, entry}, acc ->
      status = if entry.kind == :command, do: :outcome_unknown, else: :deadline_exceeded

      delivery =
        failure_delivery(entry.request, AdmissionError.new(:deadline_expired), status, acc.epoch)

      next = %{acc | retired_requests: Map.put(acc.retired_requests, wire_id, true)}

      case queue_delivery(next, delivery, 0) do
        {:ok, result} -> result
        :error -> shutdown(next)
      end
    end)
  end

  defp queue_delivery(state, delivery, wire_bytes) do
    decoded = :erlang.external_size(delivery)

    if match?({:ok, _}, Delivery.validate(delivery)) and state.delivery_count < @max_deliveries and
         wire_bytes + state.wire_bytes <= @max_wire_bytes and
         decoded + state.decoded_bytes <= @max_decoded_bytes do
      item = %{delivery: delivery, wire_bytes: wire_bytes, decoded_bytes: decoded}

      {:ok,
       %{
         state
         | queue: :queue.in(item, state.queue),
           delivery_count: state.delivery_count + 1,
           wire_bytes: state.wire_bytes + wire_bytes,
           decoded_bytes: state.decoded_bytes + decoded
       }}
    else
      :error
    end
  end

  defp failure_delivery(request, error, status, epoch) do
    attrs = [state: :error, request_id: request.request_id, error: error]

    body =
      case request.expected_response do
        :outcome ->
          %DTO.Outcome{
            request_id: request.request_id,
            status: status,
            error: error,
            corrective_action: if(status == :outcome_unknown, do: :refresh, else: :none)
          }

        :transcript_window ->
          struct!(DTO.TranscriptWindow, attrs)

        :library_snapshot ->
          struct!(DTO.LibrarySnapshot, attrs ++ [feature: elem(request.kind, 1)])

        :pending_interactions ->
          struct!(DTO.PendingInteractionWindow, attrs)

        :detail_window ->
          struct!(DTO.DetailWindow, attrs ++ [offset: elem(request.kind, 2)])

        :activity_snapshot ->
          struct!(DTO.ActivitySnapshot, attrs ++ [counts: %DTO.Counts{}])

        :shell_snapshot ->
          struct!(
            DTO.ShellSnapshot,
            attrs ++
              [
                counts: %DTO.Counts{},
                connection: %DTO.Connection{state: :disconnected, source_epoch: epoch}
              ]
          )

        :workspace_snapshot ->
          struct!(
            DTO.WorkspaceSnapshot,
            attrs ++
              [
                conversation_id: request.scope.id,
                transcript: %DTO.TranscriptWindow{},
                runs_page: %DTO.PageInfo{},
                interactions_page: %DTO.PageInfo{}
              ]
          )

        :run_detail_snapshot ->
          struct!(DTO.RunDetailSnapshot, attrs ++ [transcript: %DTO.TranscriptWindow{}])
      end

    %Delivery{
      kind: :response,
      watch_ref: nil,
      request_id: request.request_id,
      scope: request.scope,
      generation: request.generation,
      revision: nil,
      sequence: nil,
      body: body
    }
  end

  defp envelope(type, id, nonce, scope, body),
    do: %Message{
      version: 1,
      type: type,
      request_id: id,
      nonce: nonce,
      scope: scope,
      sequence: nil,
      occurred_at: nil,
      body: body
    }

  defp uuid do
    <<a::32, b::16, _::4, c::12, _::2, d::14, e::48>> = :crypto.strong_rand_bytes(16)

    Base.encode16(<<a::32, b::16, 4::4, c::12, 2::2, d::14, e::48>>, case: :lower)
    |> then(fn hex ->
      <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
        e::binary-size(12)>> = hex

      Enum.join([a, b, c, d, e], "-")
    end)
  end

  # Stable per-client identity: retries/reconnects preserve the durable local
  # request identity while the wire still carries a canonical UUID.
  defp wire_id(request_id) do
    <<a::32, b::16, _::4, c::12, _::2, d::14, e::48, _::binary>> =
      :crypto.hash(:sha256, request_id)

    [hex(a, 8), hex(b, 4), "4" <> hex(c, 3), hex(Bitwise.bor(d, 0x8000), 4), hex(e, 12)]
    |> Enum.join("-")
  end

  defp hex(value, size),
    do: value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(size, "0")

  defp valid_options?(opts) when is_list(opts) do
    Keyword.keyword?(opts) and
      Enum.sort(Keyword.keys(opts)) in [
        Enum.sort([:socket_path, :nonce, :source_epoch]),
        Enum.sort([:socket_path, :nonce, :source_epoch, :timeout])
      ] and is_binary(opts[:socket_path]) and byte_size(opts[:socket_path]) in 1..1_024 and
      String.valid?(opts[:socket_path]) and not String.contains?(opts[:socket_path], <<0>>) and
      Path.type(opts[:socket_path]) == :absolute and
      (opts[:source_epoch] == nil or Intent.valid_id?(opts[:source_epoch])) and
      is_integer(Keyword.get(opts, :timeout, 1_000)) and
      Keyword.get(opts, :timeout, 1_000) in 1..60_000
  end

  defp valid_options?(_), do: false
end
