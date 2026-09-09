defmodule SwarmCodeCLI.UI.Reducer.Watch do
  @moduledoc false
  alias SwarmCode.Protocol.Scope
  alias SwarmCodeCLI.UI.{State, WatchState, ReadModel, Scroll, PageState}
  alias SwarmCodeCLI.UI.DataSource.{Watch, Request}

  def open(state, slot, kind, id) do
    old = Map.fetch!(state.watches, slot)
    generation = old.generation + 1
    {ref, state} = State.next_id(state, "#{state.source_epoch}:watch")
    scope = %Scope{kind: kind, id: id, generation: generation}

    watch = %Watch{
      watch_ref: ref,
      slot: slot,
      scope: scope,
      generation: generation,
      page_size: 200,
      byte_limit: 1_048_576
    }

    next = %WatchState{
      watch_ref: ref,
      scope: scope,
      generation: generation,
      source_epoch: state.source_epoch,
      status: :frozen
    }

    requests =
      state.requests
      |> Enum.filter(fn {_, request} ->
        request.expected_response != :outcome and request.scope == old.scope
      end)
      |> Enum.sort_by(&elem(&1, 0))

    effects =
      Enum.map(requests, fn {id, _} -> {:cancel_request, id} end) ++
        if(old.watch_ref, do: [{:unwatch, old.watch_ref}], else: []) ++ [{:watch, watch}]

    state = %{
      state
      | watches: Map.put(state.watches, slot, next),
        requests: Map.drop(state.requests, Enum.map(requests, &elem(&1, 0))),
        pages: Map.delete(state.pages, slot)
    }

    {state, effects}
  end

  def close(state, slot) do
    old = state.watches[slot]
    next = %{old | watch_ref: nil, scope: nil, generation: old.generation + 1, status: :closed}

    requests =
      Enum.filter(state.requests, fn {_, request} ->
        request.expected_response != :outcome and request.scope == old.scope
      end)

    effects =
      Enum.map(requests, fn {id, _} -> {:cancel_request, id} end) ++
        if(old.watch_ref, do: [{:unwatch, old.watch_ref}], else: [])

    {%{
       state
       | watches: Map.put(state.watches, slot, next),
         requests: Map.drop(state.requests, Enum.map(requests, &elem(&1, 0)))
     }, effects}
  end

  def deliver(state, delivery) do
    slot =
      Enum.find([:shell, :workspace, :activity, :inspector], fn slot ->
        watch = state.watches[slot]

        watch.watch_ref == delivery.watch_ref and watch.scope == delivery.scope and
          watch.generation == delivery.generation and watch.source_epoch == state.source_epoch
      end)

    if slot, do: matching(state, slot, delivery), else: {state, []}
  end

  def resync(state, slot) do
    watch = state.watches[slot]

    if watch.resync_request_id || watch.status == :closed do
      {state, []}
    else
      {id, state} = State.next_id(state, :resync)

      request = %Request{
        request_id: id,
        kind: {:resync_watch, watch.watch_ref},
        scope: watch.scope,
        generation: watch.generation,
        origin: {:watch, watch.watch_ref},
        deadline: state.now + state.deadline_ms,
        expected_response: :watch_snapshot
      }

      watch = %{watch | status: :resyncing, resync_request_id: id}

      state = %{
        state
        | watches: Map.put(state.watches, slot, watch),
          requests: Map.put(state.requests, id, request),
          pages:
            Map.update(
              state.pages,
              slot,
              %PageState{status: :resyncing},
              &%{&1 | status: :resyncing}
            )
      }

      {state, [{:query, request}]}
    end
  end

  def retry(state, slot) do
    case state.watches[slot] do
      %{status: :error, retry: :watch, scope: scope} -> open(state, slot, scope.kind, scope.id)
      %{status: :error} -> resync(state, slot)
      _ -> {state, []}
    end
  end

  defp matching(state, slot, %{kind: :watch_ready} = delivery) do
    watch = state.watches[slot]

    if not expected_snapshot?(slot, delivery.body, watch.scope) or
         delivery.revision < watch.revision or
         (delivery.revision == watch.revision and watch.status == :ready) or
         delivery.body.through_sequence < watch.sequence do
      {state, []}
    else
      watch = %{
        watch
        | status: :ready,
          revision: delivery.revision,
          sequence: delivery.body.through_sequence,
          resync_request_id: nil,
          retry: nil
      }

      old = state.watches[slot]
      candidate = install_snapshot(state, slot, delivery.body)

      if ReadModel.bounded?(candidate.read_model) do
        superseded_page =
          case Map.get(state.pages, slot) do
            %PageState{request_id: id} when is_binary(id) -> id
            _ -> nil
          end

        effects =
          if superseded_page && Map.has_key?(state.requests, superseded_page),
            do: [{:cancel_request, superseded_page}],
            else: []

        {%{
           candidate
           | watches: Map.put(candidate.watches, slot, watch),
             requests: Map.drop(candidate.requests, [old.resync_request_id, superseded_page])
         }, effects}
      else
        resync(state, slot)
      end
    end
  end

  defp matching(state, slot, %{kind: :delta} = delivery) do
    watch = state.watches[slot]

    cond do
      # Sequence is the watch's ordering watermark. Revisions belong to the
      # individual entity and may legitimately be older than another entity's
      # latest update; ReadModel.delta performs the per-entity stale check.
      delivery.sequence <= watch.sequence ->
        {state, []}

      watch.status in [:resyncing, :closed, :frozen] ->
        {state, []}

      delivery.sequence != watch.sequence + 1 ->
        resync(state, slot)

      true ->
        case ReadModel.delta(state.read_model, slot, delivery.body) do
          {:error, :snapshot_required} ->
            resync(state, slot)

          {:ok, model, changed, removed} ->
            old_ids = Map.get(state.read_model.order, slot, [])

            watch = %{
              watch
              | revision: max(watch.revision, delivery.revision),
                sequence: delivery.sequence
            }

            state = %{state | read_model: model, watches: Map.put(state.watches, slot, watch)}
            {state, overflow} = update_scrolls(state, slot, changed, removed, old_ids)
            if overflow, do: resync(state, slot), else: {state, []}
        end
    end
  end

  defp matching(state, slot, %{kind: kind, body: body})
       when kind in [:closed, :resyncing, :error] do
    status = if kind == :error, do: :error, else: kind
    previous = state.watches[slot]
    recovery = previous.resync_request_id

    watch =
      if kind == :error do
        %{
          previous
          | status: status,
            resync_request_id: nil,
            retry: previous.retry || if(previous.status == :frozen, do: :watch, else: :resync)
        }
      else
        %{previous | status: status}
      end

    state =
      if kind == :error,
        do: %{state | requests: Map.delete(state.requests, recovery)},
        else: state

    page = Map.get(state.pages, slot, %PageState{})

    {%{
       state
       | watches: Map.put(state.watches, slot, watch),
         pages:
           Map.put(state.pages, slot, %{
             page
             | status: status,
               request_id: if(kind == :error, do: nil, else: page.request_id),
               error: if(kind == :error, do: body, else: page.error)
           })
     }, []}
  end

  defp matching(state, _, _), do: {state, []}

  def install_snapshot(state, slot, body) do
    old_ids = Map.get(state.read_model.order, slot, [])
    model = ReadModel.snapshot(state.read_model, slot, body)

    page_body =
      if match?(%{transcript: %{}}, body) and slot in [:workspace, :inspector],
        do: body.transcript,
        else: body

    state = %{
      state
      | read_model: model,
        pages: Map.put(state.pages, slot, PageState.from_snapshot(page_body))
    }

    state =
      if Map.get(body, :presence) == :removed,
        do:
          elem(
            update_scrolls(state, slot, [], old_ids -- Map.get(model.order, slot, []), old_ids),
            0
          ),
        else: state

    region = region(slot)

    if region do
      scroll = Map.get(state.scrolls, region, %Scroll{})

      %{
        state
        | scrolls:
            Map.put(state.scrolls, region, %{
              scroll
              | before_cursor: Map.get(page_body, :before_cursor),
                after_cursor: Map.get(page_body, :after_cursor)
            })
      }
    else
      state
    end
  end

  defp update_scrolls(state, slot, changed, removed, old_ids) do
    region = region(slot)

    if region do
      ids = Map.get(state.read_model.order, slot, [])

      scroll =
        Enum.reduce(
          removed,
          Map.get(state.scrolls, region, %Scroll{}),
          &Scroll.repair(&2, &1, old_ids, ids)
        )

      {scroll, overflow} =
        Enum.reduce(changed, {scroll, false}, fn id, {acc, overflow} ->
          case Scroll.change(acc, id) do
            {:ok, next} -> {next, overflow}
            {:error, _, _} -> {acc, true}
          end
        end)

      selection = Map.get(state.selection, Atom.to_string(region))

      selection =
        if selection in removed,
          do: Enum.at(ids, Enum.find_index(old_ids, &(&1 == selection)) || 0) || List.last(ids),
          else: selection

      {%{
         state
         | scrolls: Map.put(state.scrolls, region, scroll),
           selection: Map.put(state.selection, Atom.to_string(region), selection)
       }, overflow}
    else
      {state, false}
    end
  end

  defp expected_snapshot?(:shell, %SwarmCodeCLI.UI.DataSource.DTO.ShellSnapshot{}, _), do: true

  defp expected_snapshot?(:activity, %SwarmCodeCLI.UI.DataSource.DTO.ActivitySnapshot{}, _),
    do: true

  defp expected_snapshot?(
         :workspace,
         %SwarmCodeCLI.UI.DataSource.DTO.WorkspaceSnapshot{conversation_id: id},
         %{kind: :conversation, id: id}
       ),
       do: true

  defp expected_snapshot?(:workspace, %SwarmCodeCLI.UI.DataSource.DTO.WorkspaceSnapshot{}, %{
         kind: :run
       }),
       do: true

  defp expected_snapshot?(slot, %SwarmCodeCLI.UI.DataSource.DTO.RunDetailSnapshot{run: run}, %{
         kind: :run,
         id: id
       })
       when slot in [:workspace, :inspector],
       do: is_nil(run) or run.id == id

  defp expected_snapshot?(_, _, _), do: false
  def region(:shell), do: :navigator
  def region(:inspector), do: :inspector
  def region(slot) when slot in [:workspace, :activity], do: :main
  def region(_), do: nil
end
