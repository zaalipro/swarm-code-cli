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
          | :settings_snapshot
          | :settings_result
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
          | {:settings_query, settings_params()}
          | {:settings_command, settings_params()}
  @typedoc """
  pass74 §3.6: the exact wire parameters of a `settings.query` / `settings.command`
  (string keys, the key sets of `SwarmCode.Settings.WireBounds.param_keys/1`).
  """
  @type settings_params :: %{required(String.t()) => term()}
  @typedoc """
  pass74 §3.6: the settings layer's origin: its generation and a purpose built
  only from atoms, integers and bounded strings (tuples/lists of them, depth ≤ 3).
  """
  @type settings_origin :: {:settings, pos_integer(), term()}
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
            | {:project, :update}
            | settings_origin(),
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
        is_integer(deadline) and valid_response?(kind, expected_response) and
        settings_scope?(kind, scope)

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

  @settings_query_defaults %{
    "view" => nil,
    "sections" => nil,
    "keys" => nil,
    "kind" => nil,
    "id" => nil,
    "project_id" => nil,
    "cursor" => nil,
    "page_size" => nil,
    "byte_limit" => nil,
    "options" => nil
  }
  @settings_command_defaults %{
    "action" => nil,
    "target" => nil,
    "attributes" => %{},
    "expected" => nil,
    "secrets" => [],
    "dry_run" => false
  }

  @doc """
  pass74 §3.6: a `settings.query` request. `params` may use string or atom keys
  and omit any parameter (missing ones are `null` on the wire). The three-argument
  form returns the unvalidated shell (`request_id`, `scope` and `generation` still
  nil) for the reducer to complete; with `opts` (`:request_id`, `:generation` — the
  shell watch's — and optionally `:scope`) it is completed and validated:
  `{:error, {:too_long, param}}` names the parameter outside its bound.
  """
  @spec settings_query(map(), settings_origin(), integer()) :: t()
  def settings_query(params, origin, deadline),
    do: settings_shell({:settings_query, settings_params(:query, params)}, origin, deadline)

  @spec settings_query(map(), settings_origin(), integer(), keyword()) ::
          {:ok, t()} | {:error, :invalid_request | {:too_long, String.t()}}
  def settings_query(params, origin, deadline, opts),
    do: params |> settings_query(origin, deadline) |> settings_complete(opts)

  @doc "pass74 §3.6: a `settings.command` request; see `settings_query/3,4`."
  @spec settings_command(map(), settings_origin(), integer()) :: t()
  def settings_command(command, origin, deadline),
    do: settings_shell({:settings_command, settings_params(:command, command)}, origin, deadline)

  @spec settings_command(map(), settings_origin(), integer(), keyword()) ::
          {:ok, t()} | {:error, :invalid_request | {:too_long, String.t()}}
  def settings_command(command, origin, deadline, opts),
    do: command |> settings_command(origin, deadline) |> settings_complete(opts)

  @doc "The scope of every settings request: global, with the shell watch's generation."
  @spec settings_scope(non_neg_integer()) :: SwarmCode.Protocol.Scope.t()
  def settings_scope(generation),
    do: %SwarmCode.Protocol.Scope{kind: :global, id: nil, generation: generation}

  @doc """
  The parameter of a settings request outside its wire bound (`nil` when every one
  is inside), for the row's `That is too long to save here (<param>)`.
  """
  @spec settings_violation(term()) :: String.t() | nil
  def settings_violation(%__MODULE__{kind: {op, params}})
      when op in [:settings_query, :settings_command],
      do: settings_violation(op, params)

  def settings_violation(_request), do: nil

  @doc "The words for a settings edit refused locally by its bound (§3.4.1)."
  @spec too_long_words(String.t()) :: String.t()
  def too_long_words(param) when is_binary(param),
    do: "That is too long to save here (#{param})"

  defp settings_violation(op, params) when is_map(params) and not is_struct(params) do
    keys = SwarmCode.Settings.WireBounds.param_keys(op)

    cond do
      map_size(params) != length(keys) or not Enum.all?(keys, &Map.has_key?(params, &1)) ->
        "params"

      true ->
        case SwarmCode.Settings.WireBounds.valid?(op, params) do
          :ok -> nil
          {:error, param} -> param
        end
    end
  end

  defp settings_violation(_op, _params), do: "params"

  defp settings_params(:query, params), do: fill(@settings_query_defaults, params)
  defp settings_params(:command, params), do: fill(@settings_command_defaults, params)

  defp fill(defaults, params) when is_map(params) do
    Enum.reduce(params, defaults, fn {key, value}, acc ->
      key = if is_atom(key), do: Atom.to_string(key), else: key
      Map.put(acc, key, value)
    end)
  end

  defp fill(defaults, _params), do: defaults

  defp settings_shell({op, _} = kind, origin, deadline) do
    %__MODULE__{
      request_id: nil,
      kind: kind,
      scope: nil,
      generation: nil,
      origin: origin,
      deadline: deadline,
      expected_response: if(op == :settings_query, do: :settings_snapshot, else: :settings_result)
    }
  end

  defp settings_complete(request, opts) do
    generation = Keyword.get(opts, :generation)

    request = %{
      request
      | request_id: Keyword.get(opts, :request_id),
        generation: generation,
        scope:
          Keyword.get_lazy(opts, :scope, fn ->
            if is_integer(generation), do: settings_scope(generation)
          end)
    }

    case settings_violation(request) do
      nil -> validate(request)
      param -> {:error, {:too_long, param}}
    end
  end

  defp settings_scope?({op, _}, scope) when op in [:settings_query, :settings_command],
    do: match?(%{kind: :global, id: nil}, scope)

  defp settings_scope?(_kind, _scope), do: true

  defp purpose?(value, _depth) when is_atom(value) or is_integer(value), do: true

  defp purpose?(value, _depth) when is_binary(value),
    do: byte_size(value) <= 512 and String.valid?(value)

  defp purpose?(value, depth) when is_tuple(value) and depth > 0,
    do: tuple_size(value) <= 8 and Enum.all?(Tuple.to_list(value), &purpose?(&1, depth - 1))

  defp purpose?(value, depth) when is_list(value) and depth > 0,
    do: length(value) <= 8 and Enum.all?(value, &purpose?(&1, depth - 1))

  defp purpose?(_value, _depth), do: false

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

  # pass74 S1-6: the same bounds the service decodes with (B3c).
  defp valid_kind?({op, params}) when op in [:settings_query, :settings_command],
    do: settings_violation(op, params) == nil

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

  defp valid_origin?({:settings, generation, purpose})
       when is_integer(generation) and generation > 0,
       do: purpose?(purpose, 3)

  defp valid_origin?(origin), do: Context.valid_origin?(origin)
  defp valid_response?({:query, slot, _, _, _, _}, response), do: response == query_response(slot)
  defp valid_response?({:query_detail, _, _, _}, response), do: response == :detail_window

  defp valid_response?({:feature_query, _, _, _, _, _}, response),
    do: response == :library_snapshot

  defp valid_response?({:resync_watch, _}, response), do: response == :watch_snapshot
  defp valid_response?({:agent_detail, _, _}, response), do: response == :agent_detail

  defp valid_response?({:conversation_list, _, _, _}, response),
    do: response == :conversation_list

  defp valid_response?({:settings_query, _}, response), do: response == :settings_snapshot
  defp valid_response?({:settings_command, _}, response), do: response == :settings_result

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

  defp correlated_kind_origin?({:settings_query, _}, {:settings, _, _}), do: true
  defp correlated_kind_origin?({:settings_command, _}, {:settings, _, _}), do: true
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

  defimpl Inspect do
    # pass74 §3.11: a settings command's pasted secrets never reach a crash
    # report or a log line; only their count is shown.
    def inspect(%{kind: {:settings_command, %{"secrets" => secrets} = params}} = request, opts)
        when is_list(secrets) and secrets != [] do
      shown = %{
        request
        | kind: {:settings_command, Map.put(params, "secrets", "[#{length(secrets)} redacted]")}
      }

      Inspect.Any.inspect(shown, opts)
    end

    def inspect(request, opts), do: Inspect.Any.inspect(request, opts)
  end
end
