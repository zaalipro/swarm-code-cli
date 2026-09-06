defmodule SwarmCodeCLI.Plain.Session do
  @moduledoc """
  Owns one plain input reader, the bound client and serialized output records.
  EOF/interrupt detach the client; they never stop canonical work. The containing
  application owns the process lifetime after the session reaches :closed.
  """
  use GenServer
  alias SwarmCode.Protocol.Scope
  alias SwarmCodeCLI.Plain.{Command, LineReader, Options, Presenter}
  alias SwarmCodeCLI.UI.{Intent, RequestResolver, SafeText}
  alias SwarmCodeCLI.UI.DataSource.{DataBridge, Delivery, DTO, Fake, Request, Watch}

  def start_link(options), do: GenServer.start_link(__MODULE__, options)
  def snapshot(server), do: GenServer.call(server, :snapshot)

  def close(server, reason) when reason in [:eof, :interrupt, :detach],
    do: GenServer.call(server, {:close, reason})

  @impl true
  def init(options) do
    epoch = Keyword.fetch!(options, :source_epoch)
    conversation = Keyword.fetch!(options, :conversation_id)
    now = Keyword.fetch!(options, :now)
    presenter_options = Keyword.fetch!(options, :options)
    output_timeout = Keyword.get(options, :output_timeout, 1000)

    if Intent.valid_id?(epoch) and Intent.valid_id?(conversation) and is_integer(now) and now >= 0 and
         match?(%Options{}, presenter_options) and is_integer(output_timeout) and
         output_timeout in 1..5000 do
      client = Keyword.fetch!(options, :data_source)

      state = %{
        phase: :binding,
        client: client,
        client_monitor: Process.monitor(client),
        epoch: epoch,
        input: Keyword.fetch!(options, :input),
        output: Keyword.fetch!(options, :output),
        output_timeout: output_timeout,
        error: Keyword.fetch!(options, :error),
        observer: Keyword.get(options, :observer),
        reader: nil,
        reader_monitor: nil,
        read_pending?: false,
        saved_input: nil,
        presenter: Presenter.new(presenter_options),
        startup_conversation: conversation,
        scope: %Scope{kind: :global, id: nil, generation: 0},
        history: [],
        watch: nil,
        sequence: 0,
        now: now,
        requests: %{},
        detail: nil,
        ready_notified?: false
      }

      {:ok, state, {:continue, :bind}}
    else
      {:stop, :invalid_plain_session}
    end
  end

  @impl true
  def handle_continue(:bind, state) do
    bind_ref = "plain-bind"

    case Fake.bind_owner(state.client, self(), bind_ref) do
      {:ok, ^bind_ref} ->
        state = write(state, [{:stdout, [SafeText.value(SafeText.chrome(:fake_banner)), "\n"]}])
        {:noreply, open_watch(state, :shell, state.scope)}

      _ ->
        {:noreply, finish(state, :binding_failed)}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state, state}
  def handle_call({:close, reason}, _from, state), do: {:reply, :ok, finish(state, reason)}
  def handle_call(_, _from, state), do: {:reply, {:error, :invalid_request}, state}

  @impl true
  def handle_info({:swarm_code_ui_data, _, _} = message, %{phase: phase} = state)
      when phase != :closed do
    case DataBridge.normalize(message, state.epoch) do
      {:ok, {:data, delivery}} ->
        if matches?(state, delivery) do
          {presenter, records} = Presenter.present(state.presenter, state.epoch, delivery)
          next = write(%{state | presenter: presenter}, records)
          notify(state, {:delivery, delivery})

          next =
            if delivery.kind == :response,
              do: %{next | requests: Map.delete(next.requests, delivery.request_id)},
              else: next

          {:noreply, next |> ready(delivery) |> request_read()}
        else
          {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:plain_input, reader, result}, %{reader: reader, phase: :ready} = state) do
    state = %{state | read_pending?: false}

    next =
      case result do
        :eof -> finish(state, :eof)
        {:line, line} -> process_line(state, line)
        {:error, :line_too_large} -> report(state, "Plain input line exceeds 16384 bytes.")
        {:error, _} -> finish(report(state, "Plain input failed."), :input_failed)
      end

    {:noreply, request_read(next)}
  end

  def handle_info({:plain_input, reader, result}, %{reader: reader, phase: phase} = state)
      when phase != :closed,
      do: {:noreply, %{state | read_pending?: false, saved_input: result}}

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{client_monitor: monitor} = state),
    do: {:noreply, finish(state, :source_unavailable)}

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{reader_monitor: monitor} = state),
    do: {:noreply, finish(state, :eof)}

  def handle_info(_, state), do: {:noreply, state}

  defp matches?(state, %Delivery{
         kind: :response,
         request_id: id,
         scope: scope,
         generation: generation,
         body: body
       }) do
    case Map.get(state.requests, id) do
      %Request{scope: ^scope, generation: ^generation} = request ->
        response_matches?(request, body)

      _ ->
        false
    end
  end

  defp matches?(state, delivery),
    do:
      state.watch != nil and delivery.watch_ref == state.watch.watch_ref and
        delivery.scope == state.watch.scope and delivery.generation == state.watch.generation

  defp response_matches?(%{expected_response: :outcome}, %DTO.Outcome{}), do: true

  defp response_matches?(%{expected_response: :detail_window}, %DTO.DetailWindow{state: :error}),
    do: true

  defp response_matches?(
         %{expected_response: :detail_window, kind: {:query_detail, ref, offset, limit}},
         %DTO.DetailWindow{state: :idle, detail_ref: %{id: ref}, offset: offset, text: text}
       ),
       do: byte_size(text) <= limit

  defp response_matches?(_, _), do: false

  defp ready(%{phase: :closed} = state, _), do: state

  defp ready(%{startup_conversation: conversation} = state, %{kind: :watch_ready})
       when conversation != nil do
    scope = %Scope{kind: :conversation, id: conversation, generation: state.scope.generation + 1}
    open_watch(%{state | startup_conversation: nil}, :workspace, scope)
  end

  defp ready(state, %{kind: :watch_ready, watch_ref: ref}) do
    requests =
      Map.reject(state.requests, fn {_, request} -> request.kind == {:resync_watch, ref} end)

    state = %{
      state
      | phase: if(map_size(requests) == 0, do: :ready, else: :awaiting_outcome),
        requests: requests
    }

    state =
      if state.reader do
        state
      else
        {reader, monitor} = LineReader.start(self(), state.input)
        %{state | reader: reader, reader_monitor: monitor}
      end

    if not state.ready_notified?, do: notify(state, :ready)
    %{state | ready_notified?: true}
  end

  defp ready(state, %{kind: :response, body: %DTO.DetailWindow{} = body}) do
    detail =
      case {state.detail, body.state} do
        {nil, _} ->
          nil

        {detail, :error} ->
          %{detail | state: :error}

        {detail, :idle} ->
          %{detail | state: :idle, offset: body.offset, next_offset: body.next_offset}
      end

    %{
      state
      | detail: detail,
        phase:
          if(
            map_size(state.requests) == 0 and state.presenter.status == :ready and
              state.phase == :awaiting_outcome,
            do: :ready,
            else: state.phase
          )
    }
  end

  defp ready(%{phase: :awaiting_outcome} = state, %{kind: :response}) do
    if map_size(state.requests) == 0, do: %{state | phase: :ready}, else: state
  end

  defp ready(state, %{kind: :resyncing}) do
    if Enum.any?(state.requests, fn {_, request} ->
         request.kind == {:resync_watch, state.watch.watch_ref}
       end) do
      %{state | phase: :awaiting_ready}
    else
      {id, state} = id(state, "resync")

      request = %Request{
        request_id: id,
        kind: {:resync_watch, state.watch.watch_ref},
        scope: state.scope,
        generation: state.scope.generation,
        origin: {:watch, state.watch.watch_ref},
        deadline: state.now + 30_000,
        expected_response: :watch_snapshot
      }

      case Fake.query(state.client, request) do
        :ok -> %{state | phase: :awaiting_ready, requests: Map.put(state.requests, id, request)}
        # Recovery of an initial watch or repeated canonical gap may already
        # be owned by the adapter. Its ready/error delivery settles that path.
        {:error, _} -> %{state | phase: :awaiting_ready}
      end
    end
  end

  defp ready(state, %{kind: :error}), do: finish(state, :watch_failed)
  defp ready(state, %{kind: :closed}), do: finish(state, :source_unavailable)
  defp ready(state, _), do: state

  defp process_line(state, line) do
    case Command.parse(line, state.presenter, state.scope) do
      {:ok, {:intent, intent}} ->
        invoke(state, intent)

      {:ok, {:local, action}} ->
        local(state, action)

      {:error, safe} ->
        write(
          state,
          [{:stderr, [SafeText.value(safe), "\n"]}] ++ Presenter.prompt_records(state.presenter)
        )
    end
  end

  defp invoke(state, intent) do
    {request_id, state} = id(state, "request")

    with {:ok, context} <- Presenter.context(state.presenter, intent, state.scope),
         {:ok, request} <-
           RequestResolver.resolve(intent, context, request_id, state.now + 30_000),
         :ok <- Fake.command(state.client, request) do
      notify(state, {:command, request})
      %{state | phase: :awaiting_outcome, requests: Map.put(state.requests, request_id, request)}
    else
      _ -> report(state, "Command was not admitted; refresh its state and retry.")
    end
  end

  defp local(state, {:open_detail, run, ref}) do
    detail = %{
      run_id: run,
      ref: ref,
      offset: 0,
      next_offset: nil,
      requested_offset: 0,
      state: :idle
    }

    query_detail(%{state | detail: detail}, 0)
  end

  defp local(%{detail: %{state: :idle, next_offset: offset}} = state, {:detail_page, :next})
       when is_integer(offset),
       do: query_detail(state, offset)

  defp local(
         %{detail: %{state: :error, requested_offset: offset}} = state,
         {:detail_page, :retry}
       ),
       do: query_detail(state, offset)

  defp local(state, {:detail_page, _}),
    do: report(state, "No detail page is available for that command.")

  defp local(state, {:quit_requested, :detach}), do: finish(state, :detach)
  defp local(state, {:navigate, :activity}), do: navigate(state, :activity, :global, nil)

  defp local(state, {:navigate, {:conversation, id}}),
    do: navigate(state, :workspace, :conversation, id)

  defp local(state, {:navigate, {:run, id}}),
    do: local(state, {:open_layer, {:run_inspector, id, :overview}})

  defp local(state, {:open_layer, {:run_inspector, id, tab}}),
    do:
      navigate(
        %{state | presenter: Presenter.inspector_tab(state.presenter, tab)},
        :inspector,
        :run,
        id
      )

  defp local(%{history: [{slot, scope} | rest]} = state, :back),
    do:
      open_watch(%{state | history: rest}, slot, %{scope | generation: state.scope.generation + 1})

  defp local(state, :back), do: state

  defp local(state, {:scroll, _region, :follow}) do
    write(state, [{:stdout, "FOLLOWING LATEST\n"}])
  end

  defp local(state, {:open_layer, :help}) do
    write(state, [
      {:stdout,
       "Commands: send -- TEXT; queue -- TEXT; answer ID@REV OPTION; pause RUN; continue RUN; stop RUN; retry RUN@REV; stop-agent RUN AGENT@REV; go conversation ID; activity; inspect RUN [overview|agents|timeline|changes]; detail REF; detail next; detail retry; back; detach\n"}
    ])
  end

  defp local(state, _), do: report(state, "This local action is unavailable in plain mode.")

  defp query_detail(state, offset) do
    {id, state} = id(state, "detail")

    request = %Request{
      request_id: id,
      kind: {:query_detail, state.detail.ref, offset, 16_384},
      origin: {:query, :detail},
      expected_response: :detail_window,
      scope: state.scope,
      generation: state.scope.generation,
      deadline: state.now + 30_000
    }

    case Fake.query(state.client, request) do
      :ok ->
        notify(state, {:query, request})

        %{
          state
          | phase: :awaiting_outcome,
            requests: Map.put(state.requests, id, request),
            detail: %{state.detail | state: :loading, requested_offset: offset}
        }

      _ ->
        report(
          %{state | detail: %{state.detail | state: :error, requested_offset: offset}},
          "Could not load detail; use detail retry."
        )
    end
  end

  defp navigate(state, slot, kind, id) do
    scope = %Scope{kind: kind, id: id, generation: state.scope.generation + 1}

    history =
      if state.watch,
        do: Enum.take([{state.watch.slot, state.scope} | state.history], 32),
        else: state.history

    open_watch(%{state | history: history}, slot, scope)
  end

  defp open_watch(%{phase: :closed} = state, _, _), do: state

  defp open_watch(state, slot, scope) do
    if state.watch, do: Fake.unwatch(state.client, state.watch.watch_ref)
    {ref, state} = id(state, "watch")

    watch = %Watch{
      watch_ref: ref,
      slot: slot,
      scope: scope,
      generation: scope.generation,
      page_size: 100,
      byte_limit: 1_048_576
    }

    case Fake.watch(state.client, watch) do
      :ok ->
        %{
          state
          | phase: :awaiting_ready,
            scope: scope,
            watch: watch,
            detail: nil,
            presenter: Presenter.focus_scope(state.presenter, scope)
        }

      _ ->
        finish(report(state, "Could not open the requested plain view."), :watch_failed)
    end
  end

  defp id(state, kind) do
    sequence = state.sequence + 1
    {"plain-" <> kind <> "-" <> Integer.to_string(sequence), %{state | sequence: sequence}}
  end

  defp request_read(%{phase: :ready, saved_input: result} = state) when result != nil do
    send(self(), {:plain_input, state.reader, result})
    %{state | saved_input: nil, read_pending?: true}
  end

  defp request_read(%{phase: :ready, read_pending?: false, reader: reader} = state)
       when is_pid(reader) do
    send(reader, :read_next)
    %{state | read_pending?: true}
  end

  defp request_read(state), do: state

  defp finish(%{phase: :closed} = state, _), do: state

  defp finish(state, reason) do
    stop_reader(state)
    Process.demonitor(state.client_monitor, [:flush])

    try do
      Fake.close(state.client)
    catch
      :exit, _ -> :ok
    end

    if reason != :output_failed,
      do: emit_records(state, [{:stdout, "DETACHED — RUNS CONTINUE\n"}])

    notify(state, {:closed, reason})
    %{state | phase: :closed, reader: nil, reader_monitor: nil, requests: %{}, watch: nil}
  end

  defp report(state, text) do
    write(state, [{:stderr, [text, "\n"]}] ++ Presenter.prompt_records(state.presenter))
  end

  defp write(state, records) do
    case emit_records(state, records) do
      :ok ->
        state

      :error ->
        emit_records(state, [{:stderr, "Plain output failed.\n"}])
        finish(state, :output_failed)
    end
  end

  defp emit_records(state, records) do
    owner = self()
    token = make_ref()
    output = state.output
    error = state.error

    {worker, monitor} =
      :erlang.spawn_opt(
        fn ->
          send(owner, {:plain_output, token, write_records(output, error, records)})
        end,
        [:link, :monitor]
      )

    result =
      receive do
        {:plain_output, ^token, result} -> result
        {:DOWN, ^monitor, :process, ^worker, _} -> :error
      after
        state.output_timeout -> :error
      end

    Process.unlink(worker)
    Process.exit(worker, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^worker, _} -> :ok
    after
      1000 -> Process.demonitor(monitor, [:flush])
    end

    # A timed-out worker may have finished at the deadline. Its correlated
    # acknowledgement has no authority after this serialized write ends.
    receive do
      {:plain_output, ^token, _} -> :ok
    after
      0 -> :ok
    end

    result
  end

  defp write_records(output, error, records) do
    Enum.reduce_while(records, :ok, fn {stream, content}, :ok ->
      device = if stream == :stderr, do: error, else: output

      case IO.write(device, IO.iodata_to_binary(content)) do
        :ok -> {:cont, :ok}
        _ -> {:halt, :error}
      end
    end)
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  defp notify(%{observer: nil}, _), do: :ok
  defp notify(state, event), do: send(state.observer, {:plain_session, self(), event})

  @impl true
  def terminate(_, state) do
    stop_reader(state)

    try do
      Fake.close(state.client)
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  defp stop_reader(%{reader: nil}), do: :ok

  defp stop_reader(%{reader: reader, reader_monitor: monitor}) do
    Process.unlink(reader)
    Process.exit(reader, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^reader, _} -> :ok
    after
      1000 -> Process.demonitor(monitor, [:flush])
    end
  end

  @impl true
  def format_status(status) do
    %{
      status
      | state: %{phase: status.state.phase, requests: map_size(status.state.requests)},
        message: :redacted,
        reason: :redacted,
        log: []
    }
  end
end
