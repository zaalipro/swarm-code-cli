defmodule SwarmCodeCLI.UI.RequestResolver.Context do
  @moduledoc "Exact immutable facts used by the pure request resolver."

  alias SwarmCode.Protocol.Scope
  alias SwarmCodeCLI.UI.{DraftKey, Intent}

  @enforce_keys [
    :scope,
    :scope_generation,
    :origin,
    :active_run_id,
    :active_run_state,
    :active_node_id,
    :active_agent_id,
    :subject_revision,
    :interaction,
    :editor_text,
    :dispatch_target,
    :attachment_refs,
    :allowed_actions
  ]
  defstruct @enforce_keys

  @type origin ::
          {:draft, DraftKey.t()}
          | {:run, binary()}
          | {:run_revision, binary(), non_neg_integer()}
          | {:agent, binary(), binary(), non_neg_integer()}
          | {:interaction, binary(), non_neg_integer()}
          | {:seen, :conversation | :run | :activity, binary(), non_neg_integer()}

  @type interaction ::
          nil
          | {:question | :approval, binary(), binary(), binary(), non_neg_integer()}

  @type run_state ::
          nil
          | :queued
          | :running
          | :streaming
          | :waiting_question
          | :waiting_approval
          | :paused
          | :retrying
          | :done
          | :failed
          | :stopped
          | :interrupted
          | :superseded

  @type t :: %__MODULE__{
          scope: Scope.t(),
          scope_generation: non_neg_integer(),
          origin: origin(),
          active_run_id: binary() | nil,
          active_run_state: run_state(),
          active_node_id: binary() | nil,
          active_agent_id: binary() | nil,
          subject_revision: non_neg_integer() | nil,
          interaction: interaction(),
          editor_text: binary(),
          dispatch_target: Intent.dispatch_target(),
          attachment_refs: [binary()],
          allowed_actions: [Intent.permission()]
        }

  @run_states [
    nil,
    :queued,
    :running,
    :streaming,
    :waiting_question,
    :waiting_approval,
    :paused,
    :retrying,
    :done,
    :failed,
    :stopped,
    :interrupted,
    :superseded
  ]

  @scope_kinds [:global, :project, :conversation, :run, :research, :workflow, :schedule]

  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_context}
  def validate(
        %__MODULE__{
          scope: scope,
          scope_generation: scope_generation,
          origin: origin,
          active_run_id: active_run_id,
          active_run_state: active_run_state,
          active_node_id: active_node_id,
          active_agent_id: active_agent_id,
          subject_revision: subject_revision,
          interaction: interaction,
          editor_text: editor_text,
          dispatch_target: dispatch_target,
          attachment_refs: attachment_refs,
          allowed_actions: allowed_actions
        } = context
      ) do
    valid? =
      map_size(context) == 14 and valid_scope?(scope) and non_negative_integer?(scope_generation) and
        valid_origin?(origin) and optional_id?(active_run_id) and active_run_state in @run_states and
        optional_id?(active_node_id) and optional_id?(active_agent_id) and
        optional_non_negative_integer?(subject_revision) and valid_interaction?(interaction) and
        Intent.valid_context_text?(editor_text) and Intent.valid_dispatch_target?(dispatch_target) and
        Intent.valid_id_list?(attachment_refs) and Intent.valid_permission_list?(allowed_actions)

    if valid?, do: {:ok, context}, else: {:error, :invalid_context}
  end

  def validate(_context), do: {:error, :invalid_context}

  @spec validate!(term()) :: t()
  def validate!(context) do
    case validate(context) do
      {:ok, valid} -> valid
      {:error, :invalid_context} -> raise ArgumentError, "invalid request resolver context"
    end
  end

  @spec valid_scope?(term()) :: boolean()
  def valid_scope?(%Scope{kind: :global, id: nil, generation: generation} = scope),
    do: map_size(scope) == 4 and non_negative_integer?(generation)

  def valid_scope?(%Scope{kind: kind, id: id, generation: generation} = scope),
    do:
      map_size(scope) == 4 and kind in (@scope_kinds -- [:global]) and Intent.valid_id?(id) and
        non_negative_integer?(generation)

  def valid_scope?(_scope), do: false

  @spec valid_origin?(term()) :: boolean()
  def valid_origin?({:draft, key}), do: match?({:ok, _key}, DraftKey.validate(key))
  def valid_origin?({:run, run_id}), do: Intent.valid_id?(run_id)

  def valid_origin?({:run_revision, run_id, revision}),
    do: Intent.valid_id?(run_id) and non_negative_integer?(revision)

  def valid_origin?({:agent, run_id, agent_id, revision}),
    do:
      Intent.valid_id?(run_id) and Intent.valid_id?(agent_id) and non_negative_integer?(revision)

  def valid_origin?({:interaction, interaction_id, revision}),
    do: Intent.valid_id?(interaction_id) and non_negative_integer?(revision)

  def valid_origin?({:seen, kind, id, revision}) when kind in [:conversation, :run, :activity],
    do: Intent.valid_id?(id) and non_negative_integer?(revision)

  def valid_origin?(_origin), do: false

  defp valid_interaction?(nil), do: true

  defp valid_interaction?({kind, run_id, node_id, interaction_id, revision})
       when kind in [:question, :approval],
       do:
         Intent.valid_id?(run_id) and Intent.valid_id?(node_id) and
           Intent.valid_id?(interaction_id) and non_negative_integer?(revision)

  defp valid_interaction?(_interaction), do: false

  defp optional_id?(nil), do: true
  defp optional_id?(id), do: Intent.valid_id?(id)
  defp optional_non_negative_integer?(nil), do: true
  defp optional_non_negative_integer?(value), do: non_negative_integer?(value)
  defp non_negative_integer?(value), do: is_integer(value) and value >= 0
end
