defmodule SwarmCodeCLI.UI.Reducer.Commands do
  @moduledoc false
  alias SwarmCodeCLI.UI.{State, Drafts, Editor, RequestResolver, MutationState}
  alias SwarmCodeCLI.UI.RequestResolver.Context
  alias SwarmCodeCLI.UI.DataSource.DTO.Outcome

  def invoke(state, intent, id) do
    with false <- Map.has_key?(state.requests, id),
         false <-
           Enum.any?(state.mutations, fn {_, mutation} -> match?({:settled, ^id, _}, mutation) end),
         {:ok, context} <- context(state, intent),
         false <- blocked?(context.origin, Map.get(state.mutations, context.origin)),
         {:ok, request} <-
           RequestResolver.resolve(intent, context, id, state.now + state.deadline_ms) do
      {preview, advanced} = State.next_id(state, :request)
      state = if preview == id, do: advanced, else: state

      drafts =
        case request.origin do
          {:draft, key} -> Drafts.mark_submitted(state.drafts, key, id)
          _ -> state.drafts
        end

      {%{
         state
         | requests: Map.put(state.requests, id, request),
           mutations: Map.put(state.mutations, request.origin, {:pending, id, intent}),
           drafts: drafts
       }, [{:command, request}]}
    else
      true -> {state, []}
      {:error, reason} -> {%{state | notice: {:command_rejected, reason}}, []}
    end
  end

  defp blocked?({kind, _, _}, {:settled, _, :accepted})
       when kind in [:interaction, :run_revision],
       do: true

  defp blocked?({kind, _, _, _}, {:settled, _, :accepted}) when kind in [:agent, :seen], do: true
  defp blocked?(_, mutation), do: MutationState.pending?(mutation)

  def settle(state, request, %Outcome{} = outcome) do
    drafts =
      case {outcome.status, request.origin, request.kind} do
        {:accepted, {:draft, key}, {kind, _, _, _, _}} when kind in [:dispatch, :steer] ->
          Drafts.clear_origin(state.drafts, key, request.request_id)

        _ ->
          state.drafts
      end

    drafts =
      case request.origin do
        {:draft, key} ->
          case Map.get(drafts.pending, key) do
            {id, _} when id == request.request_id ->
              %{drafts | pending: Map.delete(drafts.pending, key)}

            _ ->
              drafts
          end

        _ ->
          drafts
      end

    state = %{
      state
      | drafts: drafts,
        requests: Map.delete(state.requests, request.request_id),
        mutations:
          Map.put(state.mutations, request.origin, {:settled, request.request_id, outcome.status})
    }

    state =
      if outcome.interaction,
        do: %{
          state
          | read_model: %{
              state.read_model
              | interactions:
                  Map.put(
                    state.read_model.interactions,
                    outcome.interaction.id,
                    outcome.interaction
                  )
            }
        },
        else: state

    {state, []}
  end

  def context(state, intent) do
    inspector = Enum.find(state.layers, &match?({:run_inspector, _, _}, &1))

    slot =
      case {inspector, intent} do
        {{:run_inspector, run_id, _}, {kind, run_id, _, _}} when kind == :stop_agent ->
          :inspector

        {{:run_inspector, run_id, _}, {:retry_run, run_id, _}} ->
          :inspector

        {{:run_inspector, run_id, _}, {:run_control, _, run_id}} ->
          :inspector

        _ ->
          if state.destination == :activity, do: :activity, else: :workspace
      end

    watch = state.watches[slot]

    if watch.status != :ready do
      {:error, :not_allowed}
    else
      base =
        struct!(Context,
          scope: watch.scope,
          scope_generation: watch.generation,
          origin: {:run, "unresolved"},
          active_run_id: nil,
          active_run_state: nil,
          active_node_id: nil,
          active_agent_id: nil,
          subject_revision: nil,
          interaction: nil,
          editor_text: "",
          dispatch_target: :main,
          attachment_refs: [],
          allowed_actions: []
        )

      resolve_context(state, intent, base)
    end
  end

  defp resolve_context(state, {:dispatch, _, _, _, _}, base) do
    case State.current_draft_key(state) do
      nil ->
        {:error, :invalid_origin}

      key ->
        draft = Drafts.fetch(state.drafts, key)
        workspace = Map.get(state.read_model.snapshots, :workspace)
        permissions = if workspace, do: Map.get(workspace, :allowed_actions, []), else: []

        if Enum.all?(draft.attachments, &(&1.status == :ready)) and
             not match?({:invalid, _}, draft.staged_validation) do
          {:ok, draft_context(base, draft, key, permissions)}
        else
          {:error, :not_allowed}
        end
    end
  end

  defp resolve_context(state, {:steer, run_id, node_id, _, _}, base) do
    with {:ok, run} <- Map.fetch(state.read_model.runs, run_id),
         {:ok, node} <- find_node(state, run_id, node_id),
         true <- node.conversation_id == run.conversation_id and scope_run?(base.scope, run),
         true <- run.state in [:running, :streaming, :retrying],
         key when not is_nil(key) <- State.current_draft_key(state),
         true <- elem(key, 0) == run.conversation_id,
         draft = Drafts.fetch(state.drafts, key),
         true <-
           Enum.all?(draft.attachments, &(&1.status == :ready)) and
             not match?({:invalid, _}, draft.staged_validation) do
      context = draft_context(base, draft, key, run.allowed_actions)

      {:ok,
       %{
         context
         | active_run_id: run.id,
           active_run_state: run.state,
           active_node_id: node.node_id
       }}
    else
      _ -> {:error, :invalid_origin}
    end
  end

  defp resolve_context(state, {:run_control, _, id}, base),
    do: run_context(state, id, base, fn run, context -> %{context | origin: {:run, run.id}} end)

  defp resolve_context(state, {:retry_run, id, _}, base),
    do:
      run_context(state, id, base, fn run, context ->
        %{context | origin: {:run_revision, run.id, run.revision}, subject_revision: run.revision}
      end)

  defp resolve_context(state, {:stop_agent, run_id, agent_id, _}, base) do
    with {:ok, agent} <- Map.fetch(state.read_model.agents, agent_id),
         true <- agent.run_id == run_id do
      run_context(state, run_id, base, fn _, context ->
        %{
          context
          | origin: {:agent, run_id, agent.id, agent.revision},
            active_agent_id: agent.id,
            subject_revision: agent.revision,
            allowed_actions: agent.allowed_actions
        }
      end)
    else
      _ -> {:error, :invalid_origin}
    end
  end

  defp resolve_context(state, {kind, run_id, node_id, id, _, _}, base)
       when kind in [:answer_question, :resolve_approval] do
    with {:ok, interaction} <- Map.fetch(state.read_model.interactions, id),
         true <-
           interaction.run_id == run_id and interaction.node_id == node_id and
             interaction.state == :pending do
      interaction_context(state, interaction, base)
    else
      _ -> {:error, :invalid_origin}
    end
  end

  defp resolve_context(state, {:mark_seen, kind, id, _}, base) do
    subject =
      case kind do
        :activity ->
          Map.get(state.read_model.activity, id)

        :run ->
          Map.get(state.read_model.runs, id)

        :conversation ->
          case Map.get(state.read_model.snapshots, :workspace) do
            %{conversation_id: ^id} = workspace -> workspace
            _ -> nil
          end
      end

    if subject && seen_scope?(base.scope, kind, subject),
      do:
        {:ok,
         %{
           base
           | origin: {:seen, kind, id, subject.revision},
             allowed_actions: subject.allowed_actions
         }},
      else: {:error, :invalid_origin}
  end

  defp run_context(state, id, base, update) do
    case Map.fetch(state.read_model.runs, id) do
      {:ok, run} ->
        if not scope_run?(base.scope, run) do
          {:error, :invalid_origin}
        else
          {:ok,
           update.(run, %{
             base
             | active_run_id: run.id,
               active_run_state: run.state,
               allowed_actions: run.allowed_actions
           })}
        end

      :error ->
        {:error, :invalid_origin}
    end
  end

  defp draft_context(base, draft, key, permissions),
    do: %{
      base
      | origin: {:draft, key},
        editor_text: Editor.text(draft.editor),
        dispatch_target: if(draft.target == :none, do: :main, else: draft.target),
        attachment_refs: Enum.map(draft.attachments, & &1.reference),
        allowed_actions: permissions
    }

  defp scope_run?(%{kind: :run, id: id}, run), do: run.id == id
  defp scope_run?(%{kind: :conversation, id: id}, run), do: run.conversation_id == id
  defp scope_run?(%{kind: :global}, _), do: true
  defp scope_run?(_, _), do: false

  defp seen_scope?(%{kind: :conversation, id: id}, :conversation, subject),
    do: subject.conversation_id == id

  defp seen_scope?(_, :conversation, _), do: false
  defp seen_scope?(%{kind: :global}, _, _), do: true
  defp seen_scope?(%{kind: :conversation, id: id}, _, subject), do: subject.conversation_id == id
  defp seen_scope?(%{kind: :run, id: id}, :run, subject), do: subject.id == id
  defp seen_scope?(%{kind: :run, id: id}, :activity, subject), do: subject.run_id == id
  defp seen_scope?(_, _, _), do: false

  defp find_node(state, run_id, id) do
    case Enum.find(
           Map.values(state.read_model.transcript),
           &(&1.node_id == id and &1.run_id == run_id and &1.state != :superseded)
         ) do
      nil -> :error
      node -> {:ok, node}
    end
  end

  defp interaction_context(state, interaction, base) do
    if Map.has_key?(state.read_model.runs, interaction.run_id) do
      run_context(state, interaction.run_id, base, fn run, context ->
        if run.conversation_id == interaction.conversation_id,
          do: interaction_fields(context, interaction),
          else: %{context | allowed_actions: []}
      end)
    else
      waiting = if interaction.kind == :question, do: :waiting_question, else: :waiting_approval

      item =
        if state.destination == :activity and base.scope.kind == :global and is_nil(base.scope.id) do
          Enum.find_value(state.read_model.activity, fn {_, item} ->
            nested = item.interaction

            if item.kind == interaction.kind and item.state == waiting and
                 item.run_id == interaction.run_id and
                 item.conversation_id == interaction.conversation_id and
                 nested != nil and nested.state == :pending and
                 interaction_identity(nested) == interaction_identity(interaction),
               do: item
          end)
        end

      if item do
        {:ok,
         interaction_fields(
           %{base | active_run_id: item.run_id, active_run_state: item.state},
           interaction
         )}
      else
        {:error, :invalid_origin}
      end
    end
  end

  defp interaction_fields(context, item) do
    %{
      context
      | origin: {:interaction, item.id, item.expected_revision},
        active_node_id: item.node_id,
        interaction: {item.kind, item.run_id, item.node_id, item.id, item.expected_revision},
        allowed_actions: Enum.uniq(item.allowed_actions ++ offered_decisions(item))
    }
  end

  # pass70 F11: the service lists an approval's older permissions (approve,
  # deny) in `allowed_actions` and the card's decisions in its approval's
  # `allowed_decisions`; a decision the card offers (A always "<family>")
  # is authorized by that list. The daemon still compares-and-sets.
  defp offered_decisions(%{kind: :approval} = item) do
    explicit =
      Map.get(item, :allowed_decisions) ||
        (is_map(item.approval) && Map.get(item.approval, :allowed_decisions))

    if is_list(explicit), do: explicit, else: []
  end

  defp offered_decisions(_item), do: []

  defp interaction_identity(item),
    do:
      {item.id, item.run_id, item.node_id, item.expected_revision, item.kind,
       item.conversation_id}
end
