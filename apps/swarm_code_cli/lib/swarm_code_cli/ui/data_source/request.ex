defmodule SwarmCodeCLI.UI.DataSource.Request do
  @moduledoc "A bounded, typed, generation-correlated DataSource request shell."

  alias SwarmCodeCLI.UI.{Intent, RequestResolver}
  alias SwarmCodeCLI.UI.RequestResolver.Context

  @enforce_keys [
    :request_id,
    :kind,
    :scope,
    :generation,
    :origin,
    :deadline,
    :expected_response
  ]
  defstruct @enforce_keys

  @type expected_response ::
          :outcome
          | :shell_snapshot
          | :workspace_snapshot
          | :transcript_window
          | :activity_snapshot
          | :run_detail_snapshot
          | :pending_interactions
          | :watch_snapshot
          | :detail_window
          | :library_snapshot
          | :conversation_list
          | :agent_detail
  @type query_kind :: :shell | :workspace | :transcript | :activity | :inspector | :pending
  @features [
    :workflows,
    :research,
    :schedules,
    :settings,
    :usage,
    :changes,
    :checkpoints,
    :mcp,
    :memory,
    :files
  ]
  @decisions [:approve, :approve_run, :always_prefix, :deny, :deny_stop, :always_allow]
  @type query :: {:query, query_kind(), binary() | nil, :before | :after, 1..200, 1..1_048_576}
  @type kind ::
          Intent.t()
          | query()
          | {:resync_watch, binary()}
          | {:query_detail, binary(), non_neg_integer(), 4..65_536}
          | {:feature_query, atom(), binary() | nil, binary() | nil, 1..200, 1..1_048_576}
          | {:feature_command, atom(), atom(), binary() | nil, map()}
          | {:conversation_list, binary() | nil, 1..200, 1..1_048_576}
          | {:conversation_new}
          | {:conversation_open, binary()}
          | {:project_update, :read_only | :auto | :full_access | nil, true | nil}
          | {:resolve_approval, binary(), binary(), binary(), non_neg_integer(), decision()}
          | {:agent_detail, binary(), binary()}
  @typedoc """
  pass70 C1: `:approve` once, `:approve_run` every call of this tool in this
  run (`:always_allow` is its legacy name), `:always_prefix` the command
  family the service computed for this request, `:deny`, `:deny_stop`.
  """
  @type decision ::
          :approve | :approve_run | :always_prefix | :deny | :deny_stop | :always_allow

  @type t :: %__MODULE__{
          request_id: binary(),
          kind: kind(),
          scope: SwarmCode.Protocol.Scope.t(),
          generation: non_neg_integer(),
          origin:
            RequestResolver.Context.origin()
            | {:query, query_kind()}
            | {:watch, binary()}
            | {:query, :detail}
            | {:conversation, :list | :new | :open}
            | {:project, :update},
          deadline: integer(),
          expected_response: expected_response()
        }

  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_request}
  def validate(
        %__MODULE__{
          request_id: request_id,
          kind: kind,
          scope: scope,
          generation: generation,
          origin: origin,
          deadline: deadline,
          expected_response: expected_response
        } = request
      ) do
    valid? =
      map_size(request) == 8 and Intent.valid_id?(request_id) and valid_kind?(kind) and
        Context.valid_scope?(scope) and is_integer(generation) and generation >= 0 and
        generation == scope.generation and valid_origin?(origin) and
        correlated_kind_origin?(kind, origin) and
        is_integer(deadline) and valid_response?(kind, expected_response)

    if valid?, do: {:ok, request}, else: {:error, :invalid_request}
  end

  def validate(_request), do: {:error, :invalid_request}

  @spec validate!(term()) :: t()
  def validate!(request) do
    case validate(request) do
      {:ok, valid} -> valid
      {:error, :invalid_request} -> raise ArgumentError, "invalid data source request"
    end
  end

  defp valid_kind?({:query, slot, cursor, direction, page_size, byte_limit}),
    do:
      slot in [:shell, :workspace, :transcript, :activity, :inspector, :pending] and
        (is_nil(cursor) or Intent.valid_id?(cursor)) and direction in [:before, :after] and
        is_integer(page_size) and page_size in 1..200 and is_integer(byte_limit) and
        byte_limit in 1..1_048_576

  defp valid_kind?({:query_detail, ref, offset, bytes}),
    do:
      Intent.valid_id?(ref) and is_integer(offset) and offset >= 0 and is_integer(bytes) and
        bytes in 4..65_536

  defp valid_kind?({:feature_query, feature, id, cursor, size, bytes}),
    do:
      feature in @features and (is_nil(id) or Intent.valid_id?(id)) and
        (is_nil(cursor) or Intent.valid_id?(cursor)) and is_integer(size) and size in 1..200 and
        is_integer(bytes) and bytes in 1..1_048_576

  defp valid_kind?({:resync_watch, ref}), do: Intent.valid_id?(ref)

  defp valid_kind?({:conversation_list, cursor, size, bytes}),
    do:
      (is_nil(cursor) or Intent.valid_id?(cursor)) and is_integer(size) and size in 1..200 and
        is_integer(bytes) and bytes in 1..1_048_576

  # pass72 S: one agent's detail for the overlay (origin `{:query, :agent_detail}`).
  defp valid_kind?({:agent_detail, run_id, node_id}), do: uuid?(run_id) and uuid?(node_id)

  defp valid_kind?({:conversation_new}), do: true
  defp valid_kind?({:conversation_open, id}), do: uuid?(id)

  defp valid_kind?({:project_update, mode, trusted}),
    do:
      mode in [nil, :read_only, :auto, :full_access] and trusted in [nil, true] and
        (mode != nil or trusted != nil)

  # The widened decision set; the rest of the tuple is the Intent's.
  defp valid_kind?({:resolve_approval, run_id, node_id, interaction_id, revision, decision})
       when decision in @decisions,
       do:
         Intent.valid_id?(run_id) and Intent.valid_id?(node_id) and
           Intent.valid_id?(interaction_id) and is_integer(revision) and revision >= 0

  defp valid_kind?({:feature_command, feature, action, id, attrs})
       when is_atom(feature) and is_atom(action) do
    body = %{
      "op" => "feature.command",
      "feature" => Atom.to_string(feature),
      "action" => Atom.to_string(action),
      "id" => id,
      "attributes" => attrs,
      "timeout_ms" => 5000
    }

    match?(
      {:ok, _},
      SwarmCode.Protocol.ServiceRequest.decode(
        body,
        %SwarmCode.Protocol.Scope{kind: :global, id: nil, generation: 0}
      )
    )
  end

  defp valid_kind?(kind), do: Intent.valid?(kind)

  defp valid_origin?({:query, slot}),
    do:
      slot in [
        :shell,
        :workspace,
        :transcript,
        :activity,
        :inspector,
        :pending,
        :detail,
        :agent_detail
      ]

  defp valid_origin?({:feature, feature}), do: feature in @features
  defp valid_origin?({:feature_form, feature}), do: feature in @features

  defp valid_origin?({:watch, ref}), do: Intent.valid_id?(ref)
  defp valid_origin?({:conversation, action}) when action in [:list, :new, :open], do: true
  defp valid_origin?({:project, :update}), do: true

  defp valid_origin?(origin), do: Context.valid_origin?(origin)
  defp valid_response?({:query, slot, _, _, _, _}, response), do: response == query_response(slot)
  defp valid_response?({:query_detail, _, _, _}, response), do: response == :detail_window

  defp valid_response?({:feature_query, _, _, _, _, _}, response),
    do: response == :library_snapshot

  defp valid_response?({:resync_watch, _}, response), do: response == :watch_snapshot
  defp valid_response?({:agent_detail, _, _}, response), do: response == :agent_detail

  defp valid_response?({:conversation_list, _, _, _}, response),
    do: response == :conversation_list

  defp valid_response?(_, response), do: response == :outcome
  def query_response(:shell), do: :shell_snapshot
  def query_response(:workspace), do: :workspace_snapshot
  def query_response(:transcript), do: :transcript_window
  def query_response(:activity), do: :activity_snapshot
  def query_response(:pending), do: :pending_interactions
  def query_response(:inspector), do: :run_detail_snapshot

  defp correlated_kind_origin?({:feature_query, feature, _, _, _, _}, {:feature, feature}),
    do: true

  defp correlated_kind_origin?({:feature_command, feature, _, _, _}, {:feature, feature}),
    do: true

  defp correlated_kind_origin?({:feature_command, feature, _, _, _}, {:feature_form, feature}),
    do: true

  defp correlated_kind_origin?({:query_detail, _, _, _}, {:query, :detail}), do: true
  defp correlated_kind_origin?({:resync_watch, ref}, {:watch, ref}), do: true
  defp correlated_kind_origin?({:agent_detail, _, _}, {:query, :agent_detail}), do: true

  defp correlated_kind_origin?({:conversation_list, _, _, _}, {:conversation, :list}),
    do: true

  defp correlated_kind_origin?({:conversation_new}, {:conversation, :new}), do: true
  defp correlated_kind_origin?({:conversation_open, _}, {:conversation, :open}), do: true
  defp correlated_kind_origin?({:project_update, _, _}, {:project, :update}), do: true
  defp correlated_kind_origin?({:query, slot, _, _, _, _}, {:query, slot}), do: true

  defp correlated_kind_origin?(
         {:dispatch, _operation, _text, _target, _attachments},
         {:draft, _key}
       ),
       do: true

  defp correlated_kind_origin?({:steer, _run_id, _node_id, _text, _attachments}, {:draft, _key}),
    do: true

  defp correlated_kind_origin?({:run_control, _operation, run_id}, {:run, run_id}), do: true

  defp correlated_kind_origin?(
         {:retry_run, run_id, revision},
         {:run_revision, run_id, revision}
       ),
       do: true

  defp correlated_kind_origin?(
         {:stop_agent, run_id, agent_id, revision},
         {:agent, run_id, agent_id, revision}
       ),
       do: true

  defp correlated_kind_origin?(
         {:answer_question, _run_id, _node_id, interaction_id, revision, _option_ids},
         {:interaction, interaction_id, revision}
       ),
       do: true

  defp correlated_kind_origin?(
         {:resolve_approval, _run_id, _node_id, interaction_id, revision, _decision},
         {:interaction, interaction_id, revision}
       ),
       do: true

  defp correlated_kind_origin?(
         {:mark_seen, kind, id, revision},
         {:seen, kind, id, revision}
       ),
       do: true

  defp correlated_kind_origin?(_kind, _origin), do: false

  defp uuid?(value) when is_binary(value) and byte_size(value) == 36,
    do: Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/, value)

  defp uuid?(_value), do: false
end
