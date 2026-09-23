defmodule SwarmCodeCLI.UI.DataSource.Fake.Compose do
  @moduledoc "Pure synthetic demo composition. No provider execution or attachment reads."
  alias SwarmCodeCLI.UI.DataSource.{DTO, Delta}
  alias SwarmCodeCLI.UI.DataSource.Fake.{Details, Script}

  def prepare(script, %{kind: {:dispatch, operation, text, target, attachments}} = request) do
    with {:ok, conversation} <- conversation(script, request.scope),
         :ok <- draft_origin(request.origin, conversation),
         nil <- SwarmCodeCLI.UI.DataSource.Fake.Session.slash(script, request),
         true <- operation in Script.workspace_actions(script, request.scope),
         {:ok, parent, target_kind, target_id} <- target(script, target, conversation) do
      run_id = id(request.request_id, "run")
      item_id = id(request.request_id, "user")
      node_id = id(request.request_id, "node")

      if Map.has_key?(script.runs, run_id) or Map.has_key?(script.transcript, item_id) do
        {:error, :request_conflict}
      else
        run = %DTO.RunSummary{
          id: run_id,
          created_sequence: Script.next_created_sequence(script),
          conversation_id: conversation,
          parent_run_id: parent,
          title: "Synthetic demo: " <> Details.prefix(text, 120),
          revision: 1,
          state: if(operation == :queue, do: :queued, else: :running),
          allowed_actions:
            if(operation == :queue,
              do: [:stop, :mark_seen],
              else: [:pause, :stop, :steer, :mark_seen]
            )
        }

        item = %{
          user_item(run, node_id, item_id, attachments, target_kind, target_id)
          | created_sequence: Script.next_created_sequence(script)
        }

        with {:ok, next, item} <- Details.store(script, item, text) do
          {:ok, next, [fact(:run_update, run), fact(:node_upsert, item)],
           [run.id, item.id, node_id]}
        end
      end
    else
      false -> {:error, :not_allowed}
      error -> error
    end
  end

  def prepare(script, %{kind: {:steer, run_id, node_id, text, attachments}} = request) do
    with %DTO.RunSummary{} = run <- Map.get(script.runs, run_id),
         true <- in_scope?(request.scope, run),
         :ok <- draft_origin(request.origin, run.conversation_id),
         true <-
           Enum.any?(script.transcript, fn {_, item} ->
             item.run_id == run_id and item.node_id == node_id
           end),
         :ok <- active_permission(run) do
      item_id = id(request.request_id, "user")

      if Map.has_key?(script.transcript, item_id) do
        {:error, :request_conflict}
      else
        item = %{
          user_item(run, node_id, item_id, attachments, :steer, node_id)
          | created_sequence: Script.next_created_sequence(script)
        }

        with {:ok, next, item} <- Details.store(script, item, text) do
          run = %{run | revision: run.revision + 1}

          {:ok, next, [fact(:run_update, run), fact(:node_upsert, item)],
           [run.id, item.id, node_id]}
        end
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_origin}
    end
  end

  def prepare(script, %{kind: {:mark_seen, kind, id, revision}, scope: scope}) do
    case kind do
      :conversation ->
        with {:ok, ^id} <- conversation(script, scope),
             true <- Script.conversation_revision(script, id) == revision do
          {:ok, %{script | conversation_seen: Map.put(script.conversation_seen, id, revision)},
           [], [id]}
        else
          false -> {:error, :stale_revision}
          _ -> {:error, :invalid_origin}
        end

      kind when kind in [:run, :activity] ->
        collection = if(kind == :run, do: script.runs, else: script.activity)

        with %{revision: actual} = item <- Map.get(collection, id),
             true <- in_scope?(scope, item),
             :ok <- seen_permission(item),
             true <- actual == revision do
          delta_kind = if(kind == :run, do: :run_update, else: :activity_upsert)
          {:ok, script, [fact(delta_kind, %{item | seen_revision: revision})], [id]}
        else
          false ->
            if(Map.has_key?(collection, id) and in_scope?(scope, collection[id]),
              do: {:error, :stale_revision},
              else: {:error, :invalid_origin}
            )

          {:error, _} = error ->
            error

          _ ->
            {:error, :invalid_origin}
        end
    end
  end

  defp draft_origin({:draft, {conversation, _}}, conversation), do: :ok
  defp draft_origin(_, _), do: {:error, :invalid_origin}

  defp active_permission(run) do
    if run.state in [:running, :streaming, :retrying] and :steer in run.allowed_actions,
      do: :ok,
      else: {:error, :not_allowed}
  end

  defp seen_permission(item),
    do: if(:mark_seen in item.allowed_actions, do: :ok, else: {:error, :not_allowed})

  defp conversation(script, %{kind: :conversation, id: id}) do
    if Enum.any?(script.runs, fn {_, run} -> run.conversation_id == id end) or
         SwarmCodeCLI.UI.DataSource.Fake.Session.conversation?(script, id),
       do: {:ok, id},
       else: {:error, :invalid_origin}
  end

  defp conversation(_, _), do: {:error, :invalid_origin}

  defp target(_, :main, _), do: {:ok, nil, :main, nil}

  defp target(_, {:chip, kind, id}, _) when kind in [:command, :goal, :research],
    do: {:ok, nil, kind, id}

  defp target(script, {kind, id}, conversation) when kind in [:reply, :thread, :revise] do
    item =
      Map.get(script.transcript, id) || Map.get(script.runs, id) ||
        Enum.find_value(script.transcript, fn {_, item} -> if item.node_id == id, do: item end)

    case item do
      %{conversation_id: ^conversation} -> {:ok, Map.get(item, :run_id, item.id), kind, id}
      _ -> {:error, :invalid_origin}
    end
  end

  defp in_scope?(%{kind: :global}, _), do: true
  defp in_scope?(%{kind: :conversation, id: id}, %{conversation_id: id}), do: true
  defp in_scope?(%{kind: :run, id: id}, item), do: Map.get(item, :run_id, item.id) == id
  defp in_scope?(_, _), do: false

  defp user_item(run, node, id, attachments, target_kind, target_id),
    do: %DTO.TranscriptItem{
      id: id,
      run_id: run.id,
      node_id: node,
      conversation_id: run.conversation_id,
      role: :user,
      state: :done,
      revision: 1,
      at: Script.clock_ms(),
      attempt_id: "synthetic-attempt",
      attachment_refs: attachments,
      target_kind: target_kind,
      target_id: target_id,
      allowed_actions: [:inspect, :copy, :fork]
    }

  defp id(request_id, kind),
    do: "demo-" <> kind <> "-" <> Base.encode16(:crypto.hash(:sha256, request_id), case: :lower)

  defp fact(kind, item),
    do: %Delta{
      kind: kind,
      entity_id: item.id,
      run_id: Map.get(item, :run_id, item.id),
      conversation_id: item.conversation_id,
      body: item
    }
end
