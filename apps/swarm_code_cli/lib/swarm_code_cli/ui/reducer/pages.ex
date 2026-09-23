defmodule SwarmCodeCLI.UI.Reducer.Pages do
  @moduledoc false
  alias SwarmCodeCLI.UI.{State, Scroll, ScrollMetrics, PageState}
  alias SwarmCodeCLI.UI.DataSource.Request

  # The help sheet is the one bare-atom layer with a body longer than a screen.
  def scroll(%{layers: [:help | _]} = state, "dialog", operation),
    do: scroll_dialog(state, operation)

  def scroll(%{layers: [{kind, _} | _]} = state, "dialog", operation)
      when kind in [:approval, :command_report],
      do: scroll_dialog(state, operation)

  # The navigator is not one of them. A session restored onto the deleted region
  # still carries `scrolls.navigator` and `selection["navigator"]`, and scrolling
  # a region that is drawn nowhere must leave both exactly as they were rather
  # than measure them against main's viewport and page the shell in behind them.
  def scroll(state, region, operation) when region in ["main", "inspector"] do
    key = region_key(region)
    slot = slot(state, key)
    ids = ScrollMetrics.order(state, key, slot)
    before = Map.get(state.scrolls, key, %Scroll{})
    height_for = &ScrollMetrics.height(state, key, &1)

    scroll =
      Scroll.apply(
        before,
        operation,
        ids,
        max(1, ScrollMetrics.content_height(state, key)),
        height_for
      )

    state = %{state | scrolls: Map.put(state.scrolls, key, scroll)}

    direction = direction(operation)

    if direction && edge?(scroll, operation, ids, direction, height_for),
      do: request(state, slot, direction),
      else: {state, []}
  end

  def scroll(state, _, _), do: {state, []}

  defp scroll_dialog(state, operation) do
    # The dialog already measures its wrapped body and sticky footer. Use that
    # same viewport so paging can reach every argument without changing focus
    # to an approving action.
    state = %{state | focus: "cancel"}

    dialog =
      SwarmCodeCLI.UI.Projector.Dialog.project(state, SwarmCodeCLI.UI.Layout.classify(state.size))

    {first, last} = dialog.body_visible_range
    height = max(1, last - first)
    maximum = max(0, dialog.body_total_count - height)

    target =
      case operation do
        {:line, count} -> first + count
        {:half_page, count} -> first + max(1, div(height, 2)) * count
        {:page, count} -> first + height * count
        :first -> 0
        :last -> maximum
        _ -> first
      end

    selection = Map.put(state.selection, "dialog_scroll", min(maximum, max(0, target)))
    {%{state | selection: selection}, []}
  end

  def move(state, direction) do
    region = region_key(state.focus)
    slot = slot(state, region)
    ids = ScrollMetrics.order(state, region, slot)
    key = Atom.to_string(region)
    current = Map.get(state.selection, key)
    index = Enum.find_index(ids, &(&1 == current)) || -1

    target =
      case direction do
        :first -> 0
        :last -> length(ids) - 1
        :next -> index + 1
        :previous -> index - 1
      end

    selection = Enum.at(ids, max(0, min(length(ids) - 1, target)))
    state = %{state | selection: Map.put(state.selection, key, selection)}

    scroll =
      case direction do
        :last ->
          Scroll.apply(Map.get(state.scrolls, region, %Scroll{}), :last, ids)

        _ ->
          %{
            Map.get(state.scrolls, region, %Scroll{})
            | follow?: false,
              anchor: if(selection, do: {selection, 0, :top}, else: nil)
          }
      end

    state = %{state | scrolls: Map.put(state.scrolls, region, scroll)}

    if direction in [:first, :last] or target < 0 or target >= length(ids),
      do: request(state, slot, if(direction in [:previous, :first], do: :before, else: :after)),
      else: {state, []}
  end

  def request(state, slot, direction) do
    page = Map.get(state.pages, slot, %PageState{})
    watch = state.watches[slot]
    cursor = Map.fetch!(page, if(direction == :before, do: :before_cursor, else: :after_cursor))

    cond do
      watch.status == :error ->
        SwarmCodeCLI.UI.Reducer.Watch.retry(state, slot)

      watch.status != :ready or
          page.status in [:loading_before, :loading_after, :closed, :resyncing] ->
        {state, []}

      is_nil(cursor) and page.status != :error ->
        {state, []}

      true ->
        {id, state} = State.next_id(state, :page)
        query_kind = if slot == :workspace, do: :transcript, else: slot

        request = %Request{
          request_id: id,
          kind: {:query, query_kind, cursor, direction, 200, 1_048_576},
          scope: watch.scope,
          generation: watch.generation,
          origin: {:query, query_kind},
          deadline: state.now + state.deadline_ms,
          expected_response: Request.query_response(query_kind)
        }

        page = %{
          page
          | status: if(direction == :before, do: :loading_before, else: :loading_after),
            request_id: id,
            direction: direction,
            error: nil
        }

        {%{
           state
           | pages: Map.put(state.pages, slot, page),
             requests: Map.put(state.requests, id, request)
         }, [{:query, request}]}
    end
  end

  def response(state, request, body) do
    slot =
      Enum.find([:shell, :workspace, :activity, :inspector], fn slot ->
        state.watches[slot].scope == request.scope and
          match?(%PageState{request_id: id} when id == request.request_id, state.pages[slot])
      end)

    if slot && expected?(request.expected_response, body) do
      old = hydrate(Map.get(state.read_model.snapshots, slot), state.read_model, slot)
      body = merge_page(old, body, state.pages[slot].direction)
      candidate = SwarmCodeCLI.UI.Reducer.Watch.install_snapshot(state, slot, body)

      candidate =
        if candidate.pages[slot].status == :error do
          page = %{
            state.pages[slot]
            | status: :error,
              request_id: nil,
              error: candidate.pages[slot].error
          }

          %{state | pages: Map.put(state.pages, slot, page)}
        else
          candidate
        end

      if SwarmCodeCLI.UI.ReadModel.bounded?(candidate.read_model) do
        {%{candidate | requests: Map.delete(candidate.requests, request.request_id)}, []}
      else
        SwarmCodeCLI.UI.Reducer.Watch.resync(
          %{state | requests: Map.delete(state.requests, request.request_id)},
          slot
        )
      end
    else
      {state, []}
    end
  end

  defp hydrate(%{transcript: %{} = transcript} = body, model, slot),
    do: %{body | transcript: hydrate(transcript, model, slot)}

  defp hydrate(%SwarmCodeCLI.UI.DataSource.DTO.TranscriptWindow{} = body, model, slot),
    do: %{
      body
      | items:
          Enum.map(
            Map.get(model.order, slot, []),
            &SwarmCodeCLI.UI.ReadModel.transcript_item(model, &1)
          )
          |> Enum.reject(&is_nil/1)
    }

  defp hydrate(%SwarmCodeCLI.UI.DataSource.DTO.ActivitySnapshot{} = body, model, slot),
    do: %{body | items: SwarmCodeCLI.UI.ReadModel.items(model, slot)}

  defp hydrate(%SwarmCodeCLI.UI.DataSource.DTO.ShellSnapshot{} = body, model, slot),
    do: %{body | runs: SwarmCodeCLI.UI.ReadModel.items(model, slot)}

  defp hydrate(body, _, _), do: body
  defp expected?(:shell_snapshot, %SwarmCodeCLI.UI.DataSource.DTO.ShellSnapshot{}), do: true

  defp expected?(:workspace_snapshot, %SwarmCodeCLI.UI.DataSource.DTO.WorkspaceSnapshot{}),
    do: true

  defp expected?(:workspace_snapshot, %SwarmCodeCLI.UI.DataSource.DTO.RunDetailSnapshot{}),
    do: true

  defp expected?(:transcript_window, %SwarmCodeCLI.UI.DataSource.DTO.TranscriptWindow{}), do: true
  defp expected?(:activity_snapshot, %SwarmCodeCLI.UI.DataSource.DTO.ActivitySnapshot{}), do: true

  defp expected?(:run_detail_snapshot, %SwarmCodeCLI.UI.DataSource.DTO.RunDetailSnapshot{}),
    do: true

  defp expected?(
         :pending_interactions,
         %SwarmCodeCLI.UI.DataSource.DTO.PendingInteractionWindow{}
       ),
       do: true

  defp expected?(_, _), do: false

  defp merge_page(
         %{transcript: %{} = transcript} = old,
         %SwarmCodeCLI.UI.DataSource.DTO.TranscriptWindow{} = page,
         direction
       ) do
    %{old | transcript: merge_page(transcript, page, direction)}
  end

  defp merge_page(%module{} = old, %module{} = page, direction) do
    field =
      if Map.has_key?(page, :items),
        do: :items,
        else: if(Map.has_key?(page, :runs), do: :runs, else: nil)

    if field do
      previous = Map.fetch!(old, field)
      incoming = Map.fetch!(page, field)
      rows = if direction == :before, do: incoming ++ previous, else: previous ++ incoming

      best =
        Enum.reduce(previous ++ incoming, %{}, fn row, acc ->
          Map.update(acc, row.id, row, fn existing ->
            if row_revision(row) > row_revision(existing), do: row, else: existing
          end)
        end)

      rows = rows |> Enum.uniq_by(& &1.id) |> Enum.map(&Map.fetch!(best, &1.id))

      page
      |> Map.put(field, rows)
      |> Map.put(
        if(direction == :before, do: :after_cursor, else: :before_cursor),
        Map.get(old, if(direction == :before, do: :after_cursor, else: :before_cursor))
      )
    else
      page
    end
  end

  defp merge_page(_, page, _), do: page
  def slot(state, :main), do: if(state.destination == :activity, do: :activity, else: :workspace)
  def slot(_, :inspector), do: :inspector
  def slot(_, :navigator), do: :shell
  defp region_key("navigator"), do: :navigator
  defp region_key("inspector"), do: :inspector
  defp region_key(_), do: :main
  defp row_revision(row), do: Map.get(row, :revision, Map.get(row, :expected_revision, 0))
  defp direction(operation) when operation in [:last, :follow], do: :after
  defp direction(:first), do: :before
  defp direction({_, amount}) when amount < 0, do: :before
  defp direction({_, amount}) when amount > 0, do: :after
  defp direction(_), do: nil
  defp edge?(_, operation, _, _, _) when operation in [:first, :last, :follow], do: true

  defp edge?(scroll, _, ids, direction, height_for) do
    case scroll.anchor do
      nil ->
        true

      {id, line, _} ->
        if direction == :before,
          do: id == List.first(ids) and line == 0,
          else: id == List.last(ids) and line >= height_for.(id) - 1
    end
  end
end
