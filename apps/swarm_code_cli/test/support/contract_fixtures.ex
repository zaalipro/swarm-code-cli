defmodule SwarmCodeCLI.TestSupport.ContractFixtures do
  @moduledoc false

  alias SwarmCode.Protocol.Scope
  alias SwarmCodeCLI.UI.DataSource.Request
  alias SwarmCodeCLI.UI.RequestResolver.Context
  alias SwarmCodeCLI.UI.{Scene, Size}
  alias SwarmCodeCLI.UI.Scene.{Rect, Region, Block}

  @default_scope %Scope{kind: :conversation, id: "conversation-a", generation: 3}

  def minimal_scene(text) do
    %Scene{
      schema_version: 1,
      revision: 1,
      size: %Size{columns: 80, rows: 24},
      ambiguous_width: :narrow,
      layout_class: :wide,
      regions: [
        %Region{
          id: "main",
          role: :main,
          rect: %Rect{x: 0, y: 0, width: 80, height: 24},
          label: text,
          focus: :active,
          blocks: [%Block.Text{text: text}]
        }
      ],
      overlay: nil,
      cursor: nil,
      announcements: []
    }
  end

  def with_raw_text(scene, text),
    do: update_in(scene.regions, &[Map.put(hd(&1), :blocks, [%Block.Text{text: text}]) | tl(&1)])

  def q1_resolution_context(options \\ []) do
    context(
      [
        origin: {:interaction, "q1", 7},
        active_run_id: "run-a2",
        active_run_state: :waiting_question,
        active_node_id: "node-a2",
        interaction: {:question, "run-a2", "node-a2", "q1", 7},
        allowed_actions: [:answer_question]
      ],
      options
    )
  end

  def approval_context(options \\ []) do
    context(
      [
        origin: {:interaction, "approval-1", 4},
        active_run_id: "run-a2",
        active_run_state: :waiting_approval,
        active_node_id: "node-a2",
        interaction: {:approval, "run-a2", "node-a2", "approval-1", 4},
        allowed_actions: [:approve, :deny, :always_allow]
      ],
      options
    )
  end

  def failed_run_context(run_id, revision, options \\ []) do
    context(
      [
        scope: %Scope{kind: :run, id: run_id, generation: 3},
        origin: {:run_revision, run_id, revision},
        active_run_id: run_id,
        active_run_state: :failed,
        subject_revision: revision,
        allowed_actions: [:retry]
      ],
      options
    )
  end

  def agent_context(run_id, agent_id, revision, options \\ []) do
    context(
      [
        scope: %Scope{kind: :run, id: run_id, generation: 3},
        origin: {:agent, run_id, agent_id, revision},
        active_run_id: run_id,
        active_run_state: :running,
        active_agent_id: agent_id,
        subject_revision: revision,
        allowed_actions: [:stop_agent]
      ],
      options
    )
  end

  def run_context(run_id, options \\ []) do
    context(
      [
        scope: %Scope{kind: :run, id: run_id, generation: 3},
        origin: {:run, run_id},
        active_run_id: run_id,
        active_run_state: :running,
        allowed_actions: [:pause, :stop]
      ],
      options
    )
  end

  def dispatch_context(options \\ []) do
    context(
      [
        origin: {:draft, {"conversation-a", :main}},
        editor_text: "ship it",
        dispatch_target: :main,
        attachment_refs: ["attachment-1"],
        allowed_actions: [:send, :queue]
      ],
      options
    )
  end

  def steer_context(options \\ []) do
    context(
      [
        origin: {:draft, {"conversation-a", :main}},
        active_run_id: "run-a2",
        active_run_state: :streaming,
        active_node_id: "node-a2",
        editor_text: "focus tests",
        allowed_actions: [:steer]
      ],
      options
    )
  end

  def seen_context(kind, id, revision, options \\ []) do
    context(
      [
        origin: {:seen, kind, id, revision},
        allowed_actions: [:mark_seen]
      ],
      options
    )
  end

  def canonical_request_bytes(%Request{} = request) do
    request
    |> request_wire_value()
    |> Jason.encode!()
  end

  # pass74 §3.4: the two settings ops, their exact parameter sets and the two
  # response kinds, for the conformance and codec tests.
  @settings_scope %Scope{kind: :global, id: nil, generation: 3}

  def settings_scope, do: @settings_scope

  def settings_param_keys(:query), do: SwarmCode.Settings.WireBounds.param_keys(:settings_query)

  def settings_param_keys(:command),
    do: SwarmCode.Settings.WireBounds.param_keys(:settings_command)

  def settings_query_request(params \\ %{"view" => "values"}, options \\ []) do
    {:ok, request} =
      Request.settings_query(
        params,
        Keyword.get(options, :origin, {:settings, 1, :open}),
        Keyword.get(options, :deadline, 1_788_438_400_000),
        request_id: Keyword.get(options, :request_id, "request-s1"),
        generation: 3
      )

    request
  end

  def settings_command_request(command, options \\ []) do
    {:ok, request} =
      Request.settings_command(
        command,
        Keyword.get(options, :origin, {:settings, 1, {:commit, 1}}),
        Keyword.get(options, :deadline, 1_788_438_400_000),
        request_id: Keyword.get(options, :request_id, "request-c1"),
        generation: 3
      )

    request
  end

  def settings_snapshot_value(view, body, options \\ []),
    do: %{
      "request_id" => Keyword.get(options, :request_id),
      "view" => view,
      "revision" => Keyword.get(options, :revision, 7),
      "available" => Keyword.get(options, :available, true),
      "message" => Keyword.get(options, :message),
      "body" => body
    }

  def settings_result_value(status, options \\ []),
    do: %{
      "request_id" => Keyword.get(options, :request_id),
      "status" => status,
      "results" => Keyword.get(options, :results, []),
      "record" => Keyword.get(options, :record),
      "task" => Keyword.get(options, :task),
      "message" => Keyword.get(options, :message),
      "confirm" => Keyword.get(options, :confirm),
      "field_errors" => Keyword.get(options, :field_errors, []),
      "revision" => Keyword.get(options, :revision, 8)
    }

  def expected_q1_request_bytes do
    ~s({"deadline":1788438400000,"expected_response":"outcome","generation":3,"kind":["answer_question","run-a2","node-a2","q1",7,["option-2"]],"origin":["interaction","q1",7],"request_id":"request-42","scope":{"generation":3,"id":"conversation-a","kind":"conversation"}})
  end

  defp context(defaults, overrides) do
    values =
      [
        scope: @default_scope,
        scope_generation: 3,
        origin: {:draft, {"conversation-a", :main}},
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
      ]
      |> Keyword.merge(defaults)
      |> Keyword.merge(overrides)

    struct!(Context, values)
  end

  defp request_wire_value(request) do
    %{
      "request_id" => request.request_id,
      "kind" => tuple_wire_value(request.kind),
      "scope" => %{
        "kind" => Atom.to_string(request.scope.kind),
        "id" => request.scope.id,
        "generation" => request.scope.generation
      },
      "generation" => request.generation,
      "origin" => tuple_wire_value(request.origin),
      "deadline" => request.deadline,
      "expected_response" => Atom.to_string(request.expected_response)
    }
  end

  defp tuple_wire_value(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&tuple_wire_value/1)
  end

  defp tuple_wire_value(list) when is_list(list), do: Enum.map(list, &tuple_wire_value/1)
  defp tuple_wire_value(value) when is_atom(value), do: Atom.to_string(value)
  defp tuple_wire_value(value), do: value
end
