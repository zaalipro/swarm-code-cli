defmodule SwarmCodeCLI.UI.DataSource.Fake.Source do
  @moduledoc """
  Separately owned deterministic fake-daemon analogue. Attaching a client never
  links its lifetime to canonical facts. All data is synthetic and process local.

  Subscribers receive `{:fake_source, client_id, deltas}` in canonical order,
  and `{:fake_source, client_id, Delivery.t()}` for ready/query/command replies.
  This source does not perform the client synchronization contract (Task 9).
  Byte limits use the uncompressed external-term size of the typed DTO body.
  """
  use GenServer
  alias SwarmCodeCLI.UI.DataSource.{AdmissionError, Delivery, DTO, Request, Watch}
  alias SwarmCodeCLI.UI.DataSource.Fake.{Script, Session}
  alias SwarmCodeCLI.UI.Intent
  @max_clients 32
  @max_watches 16
  @max_requests 256

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def attach(server, client_id, pid), do: GenServer.call(server, {:attach, client_id, pid})
  def detach(server, client_id), do: GenServer.call(server, {:detach, client_id})
  def watch(server, client_id, watch), do: GenServer.call(server, {:watch, client_id, watch})

  def request(server, client_id, request),
    do: GenServer.call(server, {:request, client_id, request})

  def advance(server, barrier), do: GenServer.call(server, {:advance, barrier})
  def metadata(server), do: GenServer.call(server, :metadata)
  def unwatch(server, client_id, ref), do: GenServer.call(server, {:unwatch, client_id, ref})

  def snapshot(server), do: GenServer.call(server, :snapshot)

  @impl true
  def init(opts) do
    with true <- is_list(opts) and Keyword.keyword?(opts),
         true <- Enum.all?(Keyword.keys(opts), &(&1 in [:script, :source_epoch])),
         {:ok, script} <- Script.validate(Keyword.get(opts, :script)),
         epoch <- Keyword.get(opts, :source_epoch),
         true <- Intent.valid_id?(epoch) do
      {:ok, %{script: script, epoch: epoch, clients: %{}}}
    else
      _ -> {:stop, AdmissionError.new(:invalid_fixture)}
    end
  end

  @impl true
  def handle_call(:metadata, _, state),
    do: {:reply, %{source_epoch: state.epoch, sequence: state.script.sequence}, state}

  def handle_call({:unwatch, id, ref}, _, state),
    do: {:reply, :ok, unwatch_client(state, id, ref)}

  def handle_call(:snapshot, _, state), do: {:reply, state.script, state}

  def handle_call({:attach, id, pid}, _, state) do
    cond do
      not Intent.valid_id?(id) or not is_pid(pid) ->
        failure(:invalid_request, state)

      Map.has_key?(state.clients, id) ->
        {:reply, {:error, :duplicate_client}, state}

      map_size(state.clients) >= @max_clients ->
        failure(:capacity_exceeded, state)

      true ->
        client = %{pid: pid, monitor: Process.monitor(pid), watches: %{}, requests: %{}}
        {:reply, :ok, put_in(state.clients[id], client)}
    end
  end

  def handle_call({:detach, id}, _, state), do: {:reply, :ok, detach_client(state, id)}

  def handle_call({:watch, id, watch}, _, state) do
    with {:ok, watch} <- valid_watch(watch),
         {:ok, client} <- client(state, id),
         :ok <- check(not Map.has_key?(client.watches, watch.watch_ref), :duplicate_watch),
         :ok <- check(map_size(client.watches) < @max_watches, :capacity_exceeded),
         {:ok, body} <-
           page(
             state,
             watch.slot,
             watch.scope,
             watch.page_size,
             watch.byte_limit,
             nil,
             :after,
             nil
           ) do
      delivery = %Delivery{
        kind: :watch_ready,
        watch_ref: watch.watch_ref,
        request_id: nil,
        scope: watch.scope,
        generation: watch.generation,
        revision: state.script.revision,
        sequence: nil,
        body: body
      }

      send(client.pid, {:fake_source, id, delivery})
      {:reply, :ok, put_in(state.clients[id].watches[watch.watch_ref], watch)}
    else
      {:error, code} when is_atom(code) -> failure(code, state)
    end
  end

  def handle_call({:request, id, request}, _, state) do
    with {:ok, request} <- valid_request(request),
         {:ok, client} <- client(state, id),
         :ok <- check(request.deadline > Script.clock_ms(), :deadline_expired),
         :ok <- check(not Map.has_key?(client.requests, request.request_id), :request_conflict),
         :ok <- check(map_size(client.requests) < @max_requests, :capacity_exceeded),
         {:ok, script, body, deltas} <- execute(state, request) do
      delivery = %Delivery{
        kind: :response,
        watch_ref: nil,
        request_id: request.request_id,
        scope: request.scope,
        generation: request.generation,
        revision: nil,
        sequence: nil,
        body: body
      }

      send(client.pid, {:fake_source, id, delivery})

      next =
        %{state | script: script} |> put_in([:clients, id, :requests, request.request_id], true)

      broadcast(next, deltas)
      {:reply, :ok, next}
    else
      {:error, %AdmissionError{code: code}} -> failure(code, state)
      {:error, code} when is_atom(code) -> failure(code, state)
    end
  end

  def handle_call({:advance, barrier}, _, state) do
    case Script.advance(state.script, barrier) do
      {:ok, script, deltas} ->
        next = %{state | script: script}
        broadcast(next, deltas)
        {:reply, :ok, next}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call(_, _, state), do: failure(:invalid_request, state)

  @impl true
  def handle_cast({:detach, id, pid}, state) do
    if match?(%{pid: ^pid}, state.clients[id]),
      do: {:noreply, detach_client(state, id)},
      else: {:noreply, state}
  end

  def handle_cast({:unwatch, id, ref, pid}, state) do
    if match?(%{pid: ^pid}, state.clients[id]),
      do: {:noreply, unwatch_client(state, id, ref)},
      else: {:noreply, state}
  end

  def handle_cast({:detach, id}, state), do: {:noreply, detach_client(state, id)}
  def handle_cast({:unwatch, id, ref}, state), do: {:noreply, unwatch_client(state, id, ref)}
  def handle_cast(_, state), do: {:noreply, state}
  @impl true
  def handle_info({:DOWN, monitor, :process, pid, _}, state) do
    clients =
      Enum.reject(state.clients, fn {_, client} ->
        client.monitor == monitor and client.pid == pid
      end)
      |> Map.new()

    {:noreply, %{state | clients: clients}}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def format_status(status) do
    counts = %{
      clients: map_size(status.state.clients),
      runs: map_size(status.state.script.runs),
      revision: status.state.script.revision,
      sequence: status.state.script.sequence
    }

    status
    |> Map.put(:state, counts)
    |> Map.put(:message, :redacted)
    |> Map.put(:reason, :redacted)
    |> Map.put(:log, [])
  end

  defp valid_watch(%Watch{slot: :inspector, scope: %{kind: kind}}) when kind != :run,
    do: {:error, :invalid_watch}

  defp valid_watch(value), do: Watch.validate(value)

  defp valid_request(%Request{kind: {:query, :inspector, _, _, _, _}, scope: %{kind: kind}})
       when kind != :run,
       do: {:error, :invalid_request}

  defp valid_request(value), do: Request.validate(value)

  defp client(state, id) do
    case Map.fetch(state.clients, id) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :not_bound}
    end
  end

  defp check(true, _), do: :ok
  defp check(false, code), do: {:error, code}
  defp failure(code, state), do: {:reply, {:error, AdmissionError.new(code)}, state}

  defp unwatch_client(state, id, ref) do
    if Map.has_key?(state.clients, id),
      do: update_in(state.clients[id].watches, &Map.delete(&1, ref)),
      else: state
  end

  defp detach_client(state, id) do
    case Map.pop(state.clients, id) do
      {nil, _} ->
        state

      {client, clients} ->
        Process.demonitor(client.monitor, [:flush])
        %{state | clients: clients}
    end
  end

  defp broadcast(_, []), do: :ok

  defp broadcast(state, deltas) do
    Enum.each(state.clients, fn {id, client} -> send(client.pid, {:fake_source, id, deltas}) end)
  end

  defp execute(state, %Request{kind: {:query, slot, cursor, direction, size, bytes}} = request) do
    with {:ok, body} <-
           page(state, slot, request.scope, size, bytes, cursor, direction, request.request_id),
         do: {:ok, state.script, body, []}
  end

  defp execute(state, %Request{kind: {:query_detail, _, _, _}} = request) do
    result =
      Session.detail(state.script, request) ||
        SwarmCodeCLI.UI.DataSource.Fake.Details.query(state.script, request)

    with {:ok, body} <- result, do: {:ok, state.script, body, []}
  end

  defp execute(state, %Request{kind: {:conversation_list, _, _, _}} = request) do
    with {:ok, body} <- Session.conversation_list(state.script, request),
         do: {:ok, state.script, body, []}
  end

  defp execute(state, request), do: Script.command(state.script, request)

  defp page(state, slot, scope, size, bytes, cursor, direction, request_id) do
    script = state.script
    runs = scoped(Map.values(script.runs), scope) |> Enum.sort_by(&{&1.created_sequence, &1.id})

    transcript =
      scoped(Map.values(script.transcript), scope) |> Enum.sort_by(&{&1.created_sequence, &1.id})

    interactions =
      scoped(Map.values(script.interactions), scope)
      |> Enum.filter(&(&1.state == :pending))
      |> Enum.sort_by(& &1.id)

    activity = scoped(Map.values(script.activity), scope) |> Enum.sort_by(&activity_key/1)

    items =
      case slot do
        :shell -> runs
        :workspace -> transcript
        :transcript -> transcript
        :activity -> activity
        :pending -> interactions
        :inspector -> Map.values(script.agents) |> scoped(scope) |> Enum.sort_by(& &1.id)
      end

    with {:ok, selected, before_cursor, after_cursor} <- slice(items, cursor, direction, size) do
      attrs = [
        state: :idle,
        before_cursor: before_cursor,
        after_cursor: after_cursor,
        request_id: request_id,
        error: nil,
        presence: if(before_cursor || after_cursor, do: :off_window, else: :covered),
        covered_ids: Enum.map(selected, & &1.id),
        through_sequence: script.sequence
      ]

      {transcript_items, transcript_attrs} =
        if slot in [:workspace, :transcript],
          do: {selected, attrs},
          else: first_page(transcript, size, request_id, script.sequence)

      window = struct!(DTO.TranscriptWindow, transcript_attrs ++ [items: transcript_items])
      {run_items, run_attrs} = first_page(runs, size, request_id, script.sequence)

      {interaction_items, interaction_attrs} =
        first_page(interactions, size, request_id, script.sequence)

      body =
        case slot do
          :shell ->
            struct!(
              DTO.ShellSnapshot,
              attrs ++
                [
                  runs: selected,
                  counts: Script.counts(script),
                  connection: %DTO.Connection{source_epoch: state.epoch}
                ] ++ Session.shell_fields(script)
            )

          :workspace ->
            struct!(
              DTO.WorkspaceSnapshot,
              attrs ++
                [
                  changes:
                    script.changes
                    |> Map.values()
                    |> scoped_by_run(scope, script)
                    |> Enum.sort_by(&{-&1.at, &1.id})
                    |> Enum.take(200),
                  verdicts:
                    script.verdicts
                    |> Map.values()
                    |> scoped_by_run(scope, script)
                    |> Enum.sort_by(&{&1.run_id, &1.round, &1.id})
                    |> Enum.take(200),
                  conversation_id: if(scope.kind == :conversation, do: scope.id, else: nil),
                  allowed_actions: Script.workspace_actions(script, scope),
                  revision:
                    if(scope.kind == :conversation,
                      do: Script.conversation_revision(script, scope.id),
                      else: 0
                    ),
                  seen_revision:
                    if(scope.kind == :conversation,
                      do: Script.conversation_seen_revision(script, scope.id),
                      else: 0
                    ),
                  runs: run_items,
                  runs_page: struct!(DTO.PageInfo, run_attrs),
                  interactions_page: struct!(DTO.PageInfo, interaction_attrs),
                  transcript: window,
                  interactions: interaction_items
                ] ++ Session.workspace_fields(script, scope)
            )

          :pending ->
            struct!(DTO.PendingInteractionWindow, attrs ++ [items: selected])

          :transcript ->
            window

          :activity ->
            struct!(
              DTO.ActivitySnapshot,
              attrs ++ [items: selected, counts: Script.counts(script)]
            )

          :inspector ->
            struct!(
              DTO.RunDetailSnapshot,
              attrs ++ [run: List.first(runs), agents: selected, transcript: window]
            )
        end

      if :erlang.external_size(body) <= bytes, do: {:ok, body}, else: {:error, :capacity_exceeded}
    end
  end

  defp first_page(items, size, request_id, sequence) do
    {:ok, selected, before_cursor, after_cursor} = slice(items, nil, :after, size)

    {selected,
     [
       state: :idle,
       before_cursor: before_cursor,
       after_cursor: after_cursor,
       request_id: request_id,
       error: nil,
       presence: if(after_cursor, do: :off_window, else: :covered),
       covered_ids: Enum.map(selected, & &1.id),
       through_sequence: sequence
     ]}
  end

  defp scoped(items, %{kind: :global}), do: items

  defp scoped(items, %{kind: :conversation, id: id}),
    do: Enum.filter(items, &(Map.get(&1, :conversation_id) == id))

  defp scoped(items, %{kind: :run, id: id}),
    do: Enum.filter(items, &(Map.get(&1, :run_id, &1.id) == id))

  defp scoped(_, _), do: []

  # Changes and verdicts carry a run but no conversation; scope them by run.
  defp scoped_by_run(items, %{kind: :global}, _script), do: items

  defp scoped_by_run(items, %{kind: :conversation, id: id}, script),
    do: Enum.filter(items, &match?(%{conversation_id: ^id}, script.runs[&1.run_id]))

  defp scoped_by_run(items, %{kind: :run, id: id}, _script),
    do: Enum.filter(items, &(&1.run_id == id))

  defp scoped_by_run(_, _, _), do: []
  defp slice(items, nil, _, size), do: sliced(items, 0, size)

  defp slice(items, cursor, direction, size) do
    case Enum.find_index(items, &(&1.id == cursor)) do
      nil ->
        {:error, :invalid_request}

      index ->
        sliced(
          items,
          if(direction == :after, do: index + 1, else: max(0, index - size)),
          if(direction == :before, do: min(size, index), else: size)
        )
    end
  end

  defp sliced(items, start, size) do
    selected = Enum.slice(items, start, size)
    before_cursor = if start > 0 and selected != [], do: hd(selected).id, else: nil

    after_cursor =
      if start + length(selected) < length(items) and selected != [],
        do: List.last(selected).id,
        else: nil

    {:ok, selected, before_cursor, after_cursor}
  end

  defp activity_key(item) do
    category =
      case item.kind do
        :question -> 0
        :approval -> 0
        :running -> 1
        :paused -> 2
        :failure -> 3
        :completion -> 4
      end

    {category, item.deadline || 9_007_199_254_740_991, item.created_at, item.id}
  end
end
