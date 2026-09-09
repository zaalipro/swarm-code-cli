defmodule SwarmCodeCLI.ServiceBackendFixture do
  @moduledoc false
  use GenServer
  alias SwarmCode.Protocol.ServiceRequest

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts),
    do: {:ok, %{epoch: opts[:source_epoch], conversation_id: opts[:conversation_id], sequence: 0}}

  @impl true
  def handle_call(
        {:service_request, id, scope, %ServiceRequest{operation: :query, params: params}},
        _from,
        state
      ),
      do: {:reply, {:ok, query_result(id, scope, params["slot"], state)}, state}

  def handle_call(
        {:service_request, id, _scope, %ServiceRequest{operation: :detail, params: params}},
        _from,
        state
      ),
      do: {:reply, {:ok, detail_result(id, params)}, state}

  def handle_call(
        {:service_request, id, scope, %ServiceRequest{operation: operation}},
        _from,
        state
      )
      when operation in [:dispatch_send, :run_control, :run_steer, :approval_resolve],
      do:
        {:reply, {:ok, result("outcome", outcome(id, scope.id && [uuid()]))},
         %{state | sequence: state.sequence + 1}}

  def handle_call(
        {:service_watch, _connection, _id, scope, %ServiceRequest{params: params}},
        _from,
        state
      ) do
    kind = watch_kind(params["slot"])

    {:reply, {:watch, 1, state.sequence, kind, snapshot(kind, nil, scope, state) |> watermark(1)},
     state}
  end

  def handle_call(_, _from, state), do: {:reply, {:error, :unsupported_operation}, state}

  @impl true
  def handle_info(_, state), do: {:noreply, state}

  defp query_result(id, scope, "shell", state),
    do: result("shell_snapshot", snapshot("shell_snapshot", id, scope, state))

  defp query_result(id, scope, "workspace", state),
    do: result("workspace_snapshot", snapshot("workspace_snapshot", id, scope, state))

  defp query_result(id, scope, "transcript", state),
    do: result("transcript_window", snapshot("transcript_window", id, scope, state))

  defp query_result(id, scope, "activity", state),
    do: result("activity_snapshot", snapshot("activity_snapshot", id, scope, state))

  defp query_result(id, scope, "pending", state),
    do: result("pending_interactions", snapshot("pending_interactions", id, scope, state))

  defp query_result(id, scope, "inspector", state),
    do: result("run_detail_snapshot", snapshot("run_detail_snapshot", id, scope, state))

  defp result(kind, value), do: %{"op" => "result", "response_kind" => kind, "value" => value}

  defp outcome(id, ids),
    do: %{
      "status" => "accepted",
      "request_id" => id,
      "identifiers" => ids,
      "interaction" => nil,
      "error" => nil,
      "corrective_action" => "none"
    }

  defp snapshot("shell_snapshot", id, _scope, state),
    do:
      page(id, state)
      |> Map.merge(%{"runs" => [], "connection" => connection(state.epoch), "counts" => counts()})

  defp snapshot("workspace_snapshot", id, scope, state),
    do:
      page(id, state)
      |> Map.merge(%{
        "allowed_actions" => ["send", "queue", "mark_seen"],
        "revision" => state.sequence,
        "seen_revision" => state.sequence,
        "runs_page" => page_info(),
        "interactions_page" => page_info(),
        "conversation_id" => scope.id,
        "runs" => [],
        "transcript" => snapshot("transcript_window", id, scope, state),
        "interactions" => []
      })

  defp snapshot("transcript_window", id, _scope, state),
    do: page(id, state) |> Map.put("items", [])

  defp snapshot("activity_snapshot", id, _scope, state),
    do: page(id, state) |> Map.merge(%{"items" => [], "counts" => counts()})

  defp snapshot("pending_interactions", id, _scope, state),
    do: page(id, state) |> Map.put("items", [])

  defp snapshot("run_detail_snapshot", id, _scope, state),
    do:
      page(id, state)
      |> Map.merge(%{
        "run" => nil,
        "agents" => [],
        "transcript" => snapshot("transcript_window", id, nil, state),
        "tab" => "thread"
      })

  defp page(id, state),
    do: %{
      "state" => "idle",
      "before_cursor" => nil,
      "after_cursor" => nil,
      "request_id" => id,
      "error" => nil,
      "presence" => "covered",
      "covered_ids" => [],
      "through_sequence" => state.sequence
    }

  defp page_info,
    do: %{
      "state" => "idle",
      "before_cursor" => nil,
      "after_cursor" => nil,
      "request_id" => nil,
      "error" => nil,
      "presence" => "covered",
      "covered_ids" => [],
      "through_sequence" => 0
    }

  defp counts,
    do: %{
      "running" => 0,
      "waiting" => 0,
      "paused" => 0,
      "failed" => 0,
      "done" => 0,
      "unseen" => 0
    }

  defp connection(epoch), do: %{"state" => "connected", "source_epoch" => epoch}

  defp detail_result(id, params),
    do:
      result("detail_window", %{
        "detail_ref" => %{
          "id" => params["detail_ref"],
          "total_bytes" => max(params["offset"] + 1, 1)
        },
        "state" => "idle",
        "error" => nil,
        "offset" => params["offset"],
        "text" => "",
        "next_offset" => nil,
        "through_sequence" => 0,
        "request_id" => id
      })

  defp watch_kind("shell"), do: "shell_snapshot"
  defp watch_kind("workspace"), do: "workspace_snapshot"
  defp watch_kind("activity"), do: "activity_snapshot"
  defp watch_kind("inspector"), do: "run_detail_snapshot"

  defp watermark(value, sequence) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} ->
      {key, if(key == "through_sequence", do: sequence, else: watermark(nested, sequence))}
    end)
    |> Map.new()
  end

  defp watermark(values, sequence) when is_list(values),
    do: Enum.map(values, &watermark(&1, sequence))

  defp watermark(value, _sequence), do: value

  defp uuid do
    <<a::32, b::16, _::4, c::12, _::2, d::14, e::48>> = :crypto.strong_rand_bytes(16)
    hex(a, 8) <> "-" <> hex(b, 4) <> "-4" <> hex(c, 3) <> "-8" <> hex(d, 3) <> "-" <> hex(e, 12)
  end

  defp hex(value, size),
    do: value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(size, "0")
end
