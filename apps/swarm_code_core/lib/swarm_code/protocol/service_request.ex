defmodule SwarmCode.Protocol.ServiceRequest do
  @moduledoc """
  Closed request bodies for the first live service bridge.

  Operations are compile-time atoms; params retain wire string keys and enum
  values. A valid body does not establish authorization or persisted entity
  membership. The service must resolve those against its admitted context.
  The envelope/frame codecs separately enforce encoded JSON admission limits.
  """

  alias SwarmCode.Protocol.{Error, Scope}

  @enforce_keys [:operation, :params, :timeout_ms]
  defstruct @enforce_keys

  @type operation ::
          :query
          | :detail
          | :watch
          | :unwatch
          | :ack
          | :resync
          | :cancel
          | :conversation_open
          | :conversation_list
          | :conversation_new
          | :mark_seen
          | :project_update
          | :dispatch_send
          | :run_control
          | :run_steer
          | :approval_resolve
          | :feature_query
          | :feature_command
          | :question_answer

  @type t :: %__MODULE__{
          operation: operation(),
          params: %{optional(binary()) => term()},
          timeout_ms: 1..600_000
        }

  @max_counter 9_007_199_254_740_991
  # pass70 C1: `approve` once, `approve_run` every call of this tool in this
  # run, `always_prefix` the command family the service computed (never one
  # the client names), `deny`, and `deny_stop` (deny and stop the run).
  @decisions ~w(approve approve_run always_prefix deny deny_stop)
  @features ~w(workflows research schedules settings usage changes checkpoints mcp memory files)
  @request_keys [:__struct__, :operation, :params, :timeout_ms]
  @scope_keys [:__struct__, :kind, :id, :generation]

  @doc "Validate a parsed service request body in its typed envelope scope."
  @spec decode(term(), Scope.t() | nil) :: {:ok, t()} | {:error, Error.t()}
  def decode(body, scope) when is_map(body) do
    operation = decode_operation(Map.get(body, "op"))
    keys = param_keys(operation)

    if operation != nil and exact_keys?(body, ["op", "timeout_ms" | keys]) and
         valid_scope?(scope) and bounded_integer?(body["timeout_ms"], 1, 600_000) do
      params = Map.drop(body, ["op", "timeout_ms"])

      if valid_params?(operation, params, scope) do
        {:ok, %__MODULE__{operation: operation, params: params, timeout_ms: body["timeout_ms"]}}
      else
        invalid()
      end
    else
      invalid()
    end
  end

  def decode(_body, _scope), do: invalid()

  @doc "Encode a typed request, revalidating all fields including forged structs."
  @spec encode(t(), Scope.t() | nil) :: {:ok, map()} | {:error, Error.t()}
  def encode(%__MODULE__{} = request, scope) do
    if exact_keys?(request, @request_keys) do
      op = encode_operation(request.operation)

      if op != nil and exact_keys?(request.params, param_keys(request.operation)) do
        body = Map.merge(request.params, %{"op" => op, "timeout_ms" => request.timeout_ms})

        case decode(body, scope) do
          {:ok, _validated} -> {:ok, body}
          {:error, _error} = error -> error
        end
      else
        invalid()
      end
    else
      invalid()
    end
  end

  def encode(_request, _scope), do: invalid()

  defp decode_operation("query"), do: :query
  defp decode_operation("detail"), do: :detail
  defp decode_operation("watch"), do: :watch
  defp decode_operation("unwatch"), do: :unwatch
  defp decode_operation("ack"), do: :ack
  defp decode_operation("resync"), do: :resync
  defp decode_operation("cancel"), do: :cancel
  defp decode_operation("conversation.open"), do: :conversation_open
  defp decode_operation("conversation.list"), do: :conversation_list
  defp decode_operation("conversation.new"), do: :conversation_new
  defp decode_operation("mark_seen"), do: :mark_seen
  defp decode_operation("project.update"), do: :project_update
  defp decode_operation("dispatch"), do: :dispatch_send
  defp decode_operation("run.control"), do: :run_control
  defp decode_operation("run.steer"), do: :run_steer
  defp decode_operation("approval.resolve"), do: :approval_resolve
  defp decode_operation("feature.query"), do: :feature_query
  defp decode_operation("feature.command"), do: :feature_command
  defp decode_operation("question.answer"), do: :question_answer
  defp decode_operation(_operation), do: nil

  defp encode_operation(:query), do: "query"
  defp encode_operation(:detail), do: "detail"
  defp encode_operation(:watch), do: "watch"
  defp encode_operation(:unwatch), do: "unwatch"
  defp encode_operation(:ack), do: "ack"
  defp encode_operation(:resync), do: "resync"
  defp encode_operation(:cancel), do: "cancel"
  defp encode_operation(:conversation_open), do: "conversation.open"
  defp encode_operation(:conversation_list), do: "conversation.list"
  defp encode_operation(:conversation_new), do: "conversation.new"
  defp encode_operation(:mark_seen), do: "mark_seen"
  defp encode_operation(:project_update), do: "project.update"
  defp encode_operation(:dispatch_send), do: "dispatch"
  defp encode_operation(:run_control), do: "run.control"
  defp encode_operation(:run_steer), do: "run.steer"
  defp encode_operation(:approval_resolve), do: "approval.resolve"
  defp encode_operation(:feature_query), do: "feature.query"
  defp encode_operation(:feature_command), do: "feature.command"
  defp encode_operation(:question_answer), do: "question.answer"
  defp encode_operation(_operation), do: nil

  defp param_keys(:query), do: ~w(slot cursor direction page_size byte_limit)
  defp param_keys(:detail), do: ~w(detail_ref offset bytes)
  defp param_keys(:watch), do: ~w(watch_ref slot page_size byte_limit)
  defp param_keys(:unwatch), do: ~w(watch_ref)
  defp param_keys(:ack), do: ~w(watch_ref sequence)
  defp param_keys(:resync), do: ~w(watch_ref)
  defp param_keys(:cancel), do: ~w(target_request_id)
  defp param_keys(:conversation_open), do: ~w(conversation_id)
  defp param_keys(:conversation_list), do: ~w(cursor page_size byte_limit)
  defp param_keys(:conversation_new), do: []
  defp param_keys(:mark_seen), do: ~w(kind id revision)
  defp param_keys(:project_update), do: ~w(approval_mode trusted)
  defp param_keys(:dispatch_send), do: ~w(action text target attachment_refs)
  defp param_keys(:run_control), do: ~w(run_id action)
  defp param_keys(:run_steer), do: ~w(run_id node_id text attachment_refs)

  defp param_keys(:approval_resolve),
    do: ~w(run_id node_id interaction_id expected_revision decision)

  defp param_keys(:feature_query), do: ~w(feature id cursor page_size byte_limit)
  defp param_keys(:feature_command), do: ~w(feature action id attributes)

  defp param_keys(:question_answer),
    do: ~w(run_id node_id interaction_id expected_revision answers custom_text)

  defp param_keys(_operation), do: []

  defp valid_params?(:query, params, scope) do
    slot_scope?(params["slot"], scope) and
      (params["cursor"] == nil or reference?(params["cursor"])) and
      params["direction"] in ["before", "after"] and page_bounds?(params)
  end

  defp valid_params?(:detail, params, _scope) do
    reference?(params["detail_ref"]) and counter?(params["offset"]) and
      bounded_integer?(params["bytes"], 4, 65_536)
  end

  defp valid_params?(:watch, params, scope) do
    reference?(params["watch_ref"]) and
      params["slot"] in ["shell", "workspace", "activity", "inspector"] and
      slot_scope?(params["slot"], scope) and page_bounds?(params)
  end

  defp valid_params?(operation, params, _scope) when operation in [:unwatch, :resync],
    do: reference?(params["watch_ref"])

  defp valid_params?(:ack, params, _scope),
    do: reference?(params["watch_ref"]) and counter?(params["sequence"])

  defp valid_params?(:cancel, params, _scope), do: uuid?(params["target_request_id"])

  # pass70 C1: a conversation is opened, listed or created from any scope the
  # client holds (its shell is global, its workspace is a conversation); the
  # service resolves the project from its admitted context.
  defp valid_params?(:conversation_open, params, scope) do
    scope.kind in [:global, :project, :conversation] and
      (params["conversation_id"] == nil or uuid?(params["conversation_id"]))
  end

  defp valid_params?(:conversation_list, params, scope) do
    scope.kind in [:global, :project, :conversation] and
      (params["cursor"] == nil or reference?(params["cursor"])) and page_bounds?(params)
  end

  defp valid_params?(:conversation_new, _params, scope),
    do: scope.kind in [:global, :project, :conversation]

  defp valid_params?(:mark_seen, params, scope) do
    scope.kind in [:global, :project, :conversation, :run] and
      params["kind"] in ["conversation", "run", "activity"] and uuid?(params["id"]) and
      counter?(params["revision"])
  end

  defp valid_params?(:project_update, params, scope) do
    scope.kind in [:global, :project, :conversation] and
      params["approval_mode"] in [nil, "read_only", "auto", "full_access"] and
      params["trusted"] in [nil, true] and
      (params["approval_mode"] != nil or params["trusted"] != nil)
  end

  defp valid_params?(:dispatch_send, params, scope) do
    scope.kind == :conversation and params["action"] == "send" and
      text?(params["text"], 262_144) and
      params["target"] == %{"kind" => "main", "id" => nil} and
      attachment_refs?(params["attachment_refs"])
  end

  defp valid_params?(:run_control, params, scope) do
    run_scope?(params["run_id"], scope) and params["action"] in ["pause", "continue", "stop"]
  end

  defp valid_params?(:run_steer, params, scope) do
    run_scope?(params["run_id"], scope) and optional_uuid?(params["node_id"]) and
      text?(params["text"], 65_000) and attachment_refs?(params["attachment_refs"])
  end

  defp valid_params?(:approval_resolve, params, scope) do
    run_scope?(params["run_id"], scope) and optional_uuid?(params["node_id"]) and
      uuid?(params["interaction_id"]) and counter?(params["expected_revision"]) and
      params["decision"] in @decisions
  end

  defp valid_params?(:feature_query, params, scope) do
    params["feature"] in @features and
      optional_reference?(params["id"]) and
      (params["cursor"] == nil or reference?(params["cursor"])) and
      page_bounds?(params) and
      scope.kind in [:global, :project, :conversation]
  end

  defp valid_params?(:feature_command, params, scope) do
    actions = %{
      "workflows" => ~w(start pause resume stop),
      "research" => ~w(start stop retry report pin),
      "schedules" => ~w(save toggle run_now delete),
      "settings" => ~w(update),
      "checkpoints" => ~w(restore),
      "mcp" => ~w(save toggle delete),
      "memory" => ~w(update clear)
    }

    scope.kind in [:global, :project, :conversation] and
      params["action"] in Map.get(actions, params["feature"], []) and
      (reference?(params["id"]) or
         (is_nil(params["id"]) and
            {params["feature"], params["action"]} in [
              {"research", "start"},
              {"schedules", "save"},
              {"settings", "update"},
              {"mcp", "save"}
            ])) and
      is_map(params["attributes"]) and json_attributes?(params["attributes"], 0)
  end

  defp valid_params?(:question_answer, params, scope) do
    run_scope?(params["run_id"], scope) and uuid?(params["node_id"]) and
      uuid?(params["interaction_id"]) and counter?(params["expected_revision"]) and
      is_list(params["answers"]) and length(params["answers"]) <= 64 and
      Enum.all?(params["answers"], &reference?/1) and
      Enum.uniq(params["answers"]) == params["answers"] and
      is_binary(params["custom_text"]) and byte_size(params["custom_text"]) <= 4_000 and
      String.valid?(params["custom_text"]) and
      (params["answers"] != [] or String.trim(params["custom_text"]) != "")
  end

  defp json_attributes?(_, depth) when depth > 6, do: false

  defp json_attributes?(value, _) when is_binary(value),
    do: byte_size(value) <= 32_000 and String.valid?(value)

  defp json_attributes?(value, _) when is_boolean(value) or is_nil(value) or is_number(value),
    do: true

  defp json_attributes?(value, depth) when is_map(value) and map_size(value) <= 64,
    do:
      Enum.all?(value, fn {key, item} ->
        is_binary(key) and byte_size(key) in 1..64 and String.valid?(key) and
          json_attributes?(item, depth + 1)
      end)

  defp json_attributes?(value, depth) when is_list(value),
    do: length(value) <= 64 and Enum.all?(value, &json_attributes?(&1, depth + 1))

  defp json_attributes?(_, _), do: false

  defp valid_scope?(%Scope{} = scope) do
    exact_keys?(scope, @scope_keys) and counter?(scope.generation) and
      case scope.kind do
        :global -> scope.id == nil
        kind when kind in [:project, :conversation, :run] -> uuid?(scope.id)
        _unsupported -> false
      end
  end

  defp valid_scope?(_scope), do: false

  defp slot_scope?(slot, _scope) when slot in ["shell", "activity"], do: true

  defp slot_scope?(slot, %Scope{kind: :conversation})
       when slot in ["workspace", "transcript", "pending"],
       do: true

  defp slot_scope?("inspector", %Scope{kind: :run}), do: true
  defp slot_scope?(_slot, _scope), do: false

  defp run_scope?(run_id, %Scope{kind: :conversation}), do: uuid?(run_id)
  defp run_scope?(run_id, %Scope{kind: :run, id: id}), do: uuid?(run_id) and run_id == id
  defp run_scope?(_run_id, _scope), do: false

  defp page_bounds?(params) do
    bounded_integer?(params["page_size"], 1, 200) and
      bounded_integer?(params["byte_limit"], 1, 1_048_576)
  end

  defp exact_keys?(map, keys) when is_map(map),
    do: map_size(map) == length(keys) and Enum.all?(keys, &Map.has_key?(map, &1))

  defp exact_keys?(_map, _keys), do: false

  defp bounded_integer?(value, minimum, maximum),
    do: is_integer(value) and value >= minimum and value <= maximum

  defp counter?(value), do: bounded_integer?(value, 0, @max_counter)

  defp uuid?(value) when is_binary(value) and byte_size(value) == 36,
    do: Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/, value)

  defp uuid?(_value), do: false
  defp optional_uuid?(nil), do: true
  defp optional_uuid?(value), do: uuid?(value)

  defp optional_reference?(nil), do: true
  defp optional_reference?(value), do: reference?(value)

  defp reference?(value) when is_binary(value) and byte_size(value) in 1..256,
    do: String.valid?(value) and control_free?(value)

  defp reference?(_value), do: false

  defp text?(value, limit) when is_binary(value) and byte_size(value) <= limit,
    do: String.valid?(value) and String.trim(value) != ""

  defp text?(_value, _limit), do: false

  defp attachment_refs?(refs) when is_list(refs) and length(refs) <= 4 do
    Enum.uniq(refs) == refs and Enum.all?(refs, &uuid?/1)
  end

  defp attachment_refs?(_), do: false

  defp control_free?(<<>>), do: true

  defp control_free?(<<point::utf8, _rest::binary>>)
       when point in 0x00..0x1F or point in 0x7F..0x9F,
       do: false

  defp control_free?(<<_point::utf8, rest::binary>>), do: control_free?(rest)

  defp invalid, do: {:error, Error.new(:invalid_envelope)}
end
