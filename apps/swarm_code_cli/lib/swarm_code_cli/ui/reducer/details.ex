defmodule SwarmCodeCLI.UI.Reducer.Details do
  @moduledoc false
  alias SwarmCodeCLI.UI.State
  alias SwarmCodeCLI.UI.Reducer.Watch
  alias SwarmCodeCLI.UI.DataSource.{Request, DTO}

  def open(state, run_id, ref_id) do
    item =
      Enum.find(Map.values(state.read_model.transcript), fn item ->
        item.run_id == run_id and match?(%DTO.DetailRef{id: ^ref_id}, item.detail_ref)
      end)

    if item && length(state.layers) < 32 do
      {state, effects} = Watch.open(state, :inspector, :run, run_id)

      detail = %{
        run_id: run_id,
        ref: item.detail_ref,
        window: nil,
        status: :idle,
        request_id: nil,
        error: nil,
        history: [],
        requested_offset: 0,
        direction: :next
      }

      context = %{focus: state.focus, hidden_focus: state.hidden_focus}

      state = %{
        state
        | detail: detail,
          layers: [{:detail, run_id, ref_id} | state.layers],
          layer_contexts: [context | state.layer_contexts],
          hidden_focus: state.focus,
          focus: "detail"
      }

      {state, queried} = request(state, 0, :next)
      {state, effects ++ queried}
    else
      {state, []}
    end
  end

  def page(%{detail: nil} = state, _), do: {state, []}

  def page(state, direction) do
    detail = state.detail

    offset =
      cond do
        detail.status == :loading -> nil
        detail.status == :error -> detail.requested_offset
        direction == :previous -> List.first(detail.history)
        detail.window -> detail.window.next_offset
        true -> nil
      end

    direction = if detail.status == :error, do: detail.direction, else: direction
    if is_integer(offset), do: request(state, offset, direction), else: {state, []}
  end

  def response(%{detail: nil} = state, _, _), do: {state, []}

  def response(state, request, %DTO.DetailWindow{} = window) do
    detail = state.detail
    {:query_detail, ref, offset, bytes} = request.kind

    cond do
      detail.request_id != request.request_id or state.watches.inspector.scope != request.scope ->
        {state, []}

      window.state == :error ->
        detail = %{detail | status: :error, request_id: nil, error: window.error}
        {%{state | detail: detail, requests: Map.delete(state.requests, request.request_id)}, []}

      is_nil(window.detail_ref) or window.detail_ref.id != ref or
        window.detail_ref.total_bytes != detail.ref.total_bytes or window.offset != offset or
          byte_size(window.text) > bytes ->
        {state, []}

      true ->
        history =
          cond do
            detail.direction == :previous ->
              Enum.drop(detail.history, 1)

            detail.window && detail.window.offset != window.offset ->
              [detail.window.offset | Enum.take(detail.history, 31)]

            true ->
              detail.history
          end

        detail = %{
          detail
          | status: :idle,
            request_id: nil,
            error: nil,
            window: window,
            history: history
        }

        {%{state | detail: detail, requests: Map.delete(state.requests, request.request_id)}, []}
    end
  end

  def response(state, _, _), do: {state, []}

  defp request(state, offset, direction) do
    watch = state.watches.inspector
    {id, state} = State.next_id(state, :detail)

    request = %Request{
      request_id: id,
      kind: {:query_detail, state.detail.ref.id, offset, 16_384},
      scope: watch.scope,
      generation: watch.generation,
      origin: {:query, :detail},
      deadline: state.now + state.deadline_ms,
      expected_response: :detail_window
    }

    detail = %{
      state.detail
      | status: :loading,
        request_id: id,
        requested_offset: offset,
        direction: direction,
        error: nil
    }

    {%{state | detail: detail, requests: Map.put(state.requests, id, request)},
     [{:query, request}]}
  end
end
