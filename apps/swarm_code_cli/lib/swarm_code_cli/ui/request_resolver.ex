defmodule SwarmCodeCLI.UI.RequestResolver do
  @moduledoc """
  Purely resolves a validated Intent against an exact immutable Context.

  It never accepts presentation action IDs or labels and never repairs a
  mismatch from context state.
  """

  alias SwarmCodeCLI.UI.DataSource.Request
  alias SwarmCodeCLI.UI.{Intent, RequestResolver}
  alias RequestResolver.Context

  @type error :: :not_allowed | :stale_revision | :invalid_origin | :invalid_intent

  @spec resolve(Intent.t(), Context.t(), binary(), non_neg_integer()) ::
          {:ok, Request.t()} | {:error, error()}
  def resolve(intent, context, request_id, deadline) do
    with {:ok, _intent} <- Intent.validate(intent),
         {:ok, _context} <- Context.validate(context),
         true <- Intent.valid_id?(request_id),
         true <- is_integer(deadline) and deadline >= 0 do
      resolve_valid(intent, context, request_id, deadline)
    else
      _invalid -> {:error, :invalid_intent}
    end
  end

  defp resolve_valid(intent, context, request_id, deadline) do
    permission = required_permission(intent)

    cond do
      obvious_target_mismatch?(intent, context) ->
        {:error, :invalid_origin}

      permission not in context.allowed_actions ->
        {:error, :not_allowed}

      retry_not_failed?(intent, context) ->
        {:error, :not_allowed}

      stale_revision?(intent, context) ->
        {:error, :stale_revision}

      not valid_origin?(intent, context) ->
        {:error, :invalid_origin}

      true ->
        request = %Request{
          request_id: request_id,
          kind: intent,
          scope: context.scope,
          generation: context.scope_generation,
          origin: context.origin,
          deadline: deadline,
          expected_response: :outcome
        }

        case Request.validate(request) do
          {:ok, valid} -> {:ok, valid}
          {:error, :invalid_request} -> {:error, :invalid_origin}
        end
    end
  end

  defp required_permission({:dispatch, permission, _text, _target, _attachments}), do: permission
  defp required_permission({:steer, _run_id, _node_id, _text, _attachments}), do: :steer
  defp required_permission({:run_control, permission, _run_id}), do: permission
  defp required_permission({:retry_run, _run_id, _revision}), do: :retry
  defp required_permission({:stop_agent, _run_id, _agent_id, _revision}), do: :stop_agent

  defp required_permission({:answer_question, _run_id, _node_id, _id, _revision, _options}),
    do: :answer_question

  defp required_permission({:resolve_approval, _run_id, _node_id, _id, _revision, decision}),
    do: decision

  defp required_permission({:mark_seen, _kind, _id, _revision}), do: :mark_seen

  defp retry_not_failed?({:retry_run, _run_id, _revision}, context),
    do: context.active_run_state != :failed

  defp retry_not_failed?(_intent, _context), do: false

  defp obvious_target_mismatch?({:steer, run_id, node_id, _text, _attachments}, context),
    do:
      present_mismatch?(context.active_run_id, run_id) or
        present_mismatch?(context.active_node_id, node_id)

  defp obvious_target_mismatch?({:run_control, _operation, run_id}, context),
    do: present_mismatch?(context.active_run_id, run_id)

  defp obvious_target_mismatch?({:retry_run, run_id, _revision}, context),
    do: present_mismatch?(context.active_run_id, run_id)

  defp obvious_target_mismatch?({:stop_agent, run_id, agent_id, _revision}, context),
    do:
      present_mismatch?(context.active_run_id, run_id) or
        present_mismatch?(context.active_agent_id, agent_id)

  defp obvious_target_mismatch?(
         {:answer_question, run_id, node_id, _id, _revision, _options},
         context
       ),
       do:
         present_mismatch?(context.active_run_id, run_id) or
           present_mismatch?(context.active_node_id, node_id)

  defp obvious_target_mismatch?(
         {:resolve_approval, run_id, node_id, _id, _revision, _decision},
         context
       ),
       do:
         present_mismatch?(context.active_run_id, run_id) or
           present_mismatch?(context.active_node_id, node_id)

  defp obvious_target_mismatch?(_intent, _context), do: false

  defp present_mismatch?(nil, _expected), do: false
  defp present_mismatch?(actual, expected), do: actual != expected

  defp stale_revision?({:retry_run, _run_id, revision}, context),
    do:
      revision_mismatch?(context.origin, :run_revision, revision) or
        present_revision_mismatch?(context.subject_revision, revision)

  defp stale_revision?({:stop_agent, _run_id, _agent_id, revision}, context),
    do:
      revision_mismatch?(context.origin, :agent, revision) or
        present_revision_mismatch?(context.subject_revision, revision)

  defp stale_revision?({:answer_question, _run_id, _node_id, _id, revision, _options}, context),
    do:
      revision_mismatch?(context.origin, :interaction, revision) or
        interaction_revision_mismatch?(context.interaction, revision)

  defp stale_revision?({:resolve_approval, _run_id, _node_id, _id, revision, _decision}, context),
    do:
      revision_mismatch?(context.origin, :interaction, revision) or
        interaction_revision_mismatch?(context.interaction, revision)

  defp stale_revision?({:mark_seen, _kind, _id, revision}, context),
    do: revision_mismatch?(context.origin, :seen, revision)

  defp stale_revision?(_intent, _context), do: false

  defp revision_mismatch?({:run_revision, _run_id, actual}, :run_revision, expected),
    do: actual != expected

  defp revision_mismatch?({:agent, _run_id, _agent_id, actual}, :agent, expected),
    do: actual != expected

  defp revision_mismatch?({:interaction, _interaction_id, actual}, :interaction, expected),
    do: actual != expected

  defp revision_mismatch?({:seen, _kind, _id, actual}, :seen, expected), do: actual != expected
  defp revision_mismatch?(_origin, _kind, _expected), do: false

  defp present_revision_mismatch?(nil, _expected), do: false
  defp present_revision_mismatch?(actual, expected), do: actual != expected

  defp interaction_revision_mismatch?(nil, _expected), do: false

  defp interaction_revision_mismatch?(
         {_kind, _run_id, _node_id, _interaction_id, actual},
         expected
       ),
       do: actual != expected

  defp valid_origin?({:dispatch, _operation, text, target, attachments}, context) do
    match?({:draft, _key}, context.origin) and scope_current?(context) and
      no_active_subject?(context) and context.editor_text == text and
      context.dispatch_target == target and context.attachment_refs == attachments
  end

  defp valid_origin?({:steer, run_id, node_id, text, attachments}, context) do
    match?({:draft, _key}, context.origin) and scope_current?(context) and
      context.active_run_id == run_id and not is_nil(context.active_run_state) and
      context.active_node_id == node_id and is_nil(context.active_agent_id) and
      is_nil(context.subject_revision) and is_nil(context.interaction) and
      context.editor_text == text and context.dispatch_target == :main and
      context.attachment_refs == attachments
  end

  defp valid_origin?({:run_control, _operation, run_id}, context) do
    context.origin == {:run, run_id} and scope_current?(context) and
      context.active_run_id == run_id and not is_nil(context.active_run_state) and
      non_text_defaults?(context, active_run?: true)
  end

  defp valid_origin?({:retry_run, run_id, revision}, context) do
    context.origin == {:run_revision, run_id, revision} and scope_current?(context) and
      context.active_run_id == run_id and context.active_run_state == :failed and
      context.subject_revision == revision and is_nil(context.active_node_id) and
      is_nil(context.active_agent_id) and is_nil(context.interaction) and
      canonical_non_text?(context)
  end

  defp valid_origin?({:stop_agent, run_id, agent_id, revision}, context) do
    context.origin == {:agent, run_id, agent_id, revision} and scope_current?(context) and
      context.active_run_id == run_id and not is_nil(context.active_run_state) and
      context.active_agent_id == agent_id and context.subject_revision == revision and
      is_nil(context.active_node_id) and is_nil(context.interaction) and
      canonical_non_text?(context)
  end

  defp valid_origin?(
         {:answer_question, run_id, node_id, interaction_id, revision, _options},
         context
       ) do
    valid_interaction_origin?(
      :question,
      :waiting_question,
      run_id,
      node_id,
      interaction_id,
      revision,
      context
    )
  end

  defp valid_origin?(
         {:resolve_approval, run_id, node_id, interaction_id, revision, _decision},
         context
       ) do
    valid_interaction_origin?(
      :approval,
      :waiting_approval,
      run_id,
      node_id,
      interaction_id,
      revision,
      context
    )
  end

  defp valid_origin?({:mark_seen, kind, id, revision}, context) do
    context.origin == {:seen, kind, id, revision} and scope_current?(context) and
      no_active_subject?(context) and canonical_non_text?(context)
  end

  defp valid_interaction_origin?(
         kind,
         run_state,
         run_id,
         node_id,
         interaction_id,
         revision,
         context
       ) do
    context.origin == {:interaction, interaction_id, revision} and scope_current?(context) and
      context.active_run_id == run_id and context.active_run_state == run_state and
      context.active_node_id == node_id and is_nil(context.active_agent_id) and
      is_nil(context.subject_revision) and
      context.interaction == {kind, run_id, node_id, interaction_id, revision} and
      canonical_non_text?(context)
  end

  defp scope_current?(context), do: context.scope.generation == context.scope_generation

  defp no_active_subject?(context) do
    is_nil(context.active_run_id) and is_nil(context.active_run_state) and
      is_nil(context.active_node_id) and is_nil(context.active_agent_id) and
      is_nil(context.subject_revision) and is_nil(context.interaction)
  end

  defp non_text_defaults?(context, active_run?: true) do
    is_nil(context.active_node_id) and is_nil(context.active_agent_id) and
      is_nil(context.subject_revision) and is_nil(context.interaction) and
      canonical_non_text?(context)
  end

  defp canonical_non_text?(context) do
    context.editor_text == "" and context.dispatch_target == :main and
      context.attachment_refs == []
  end
end
