defmodule SwarmCodeCLI.TestSupport.RequestConformance do
  @moduledoc false
  alias SwarmCodeCLI.Plain.{Presenter, Options}
  alias SwarmCodeCLI.UI.DataSource.{DTO, Request}
  alias SwarmCodeCLI.UI.RequestResolver.Context
  alias SwarmCode.Protocol.Scope
  alias SwarmCodeCLI.TestSupport.ContractFixtures
  @path Path.expand("../fixtures/plain/command_conformance.json", __DIR__)
  def rows, do: @path |> File.read!() |> Jason.decode!()
  def domain_rows, do: Enum.filter(rows(), &Map.has_key?(&1, "intent"))

  def context(row) do
    source = Enum.find(domain_rows(), &(&1["name"] == fixture_name(row["context_fixture"])))
    map = source["context"]

    fields =
      Enum.map(Map.from_struct(struct(Context)), fn {key, _} ->
        {key, context_value(key, map[Atom.to_string(key)])}
      end)

    struct!(Context, fields)
  end

  defp fixture_name("retry_no_permission"), do: "retry"
  defp fixture_name("agent_no_permission"), do: "stop_agent"
  defp fixture_name("approval_no_always"), do: "approve"
  defp fixture_name(name), do: name
  defp context_value(:scope, value), do: scope(value)
  defp context_value(:origin, value), do: origin(value)
  defp context_value(:interaction, nil), do: nil
  defp context_value(:interaction, [kind | values]), do: List.to_tuple([atom(kind) | values])
  defp context_value(:dispatch_target, value), do: target(value)
  defp context_value(:active_run_state, nil), do: nil
  defp context_value(:active_run_state, value), do: atom(value)
  defp context_value(:allowed_actions, value), do: Enum.map(value, &atom/1)
  defp context_value(_, value), do: value

  defp scope(value),
    do: %Scope{kind: atom(value["kind"]), id: value["id"], generation: value["generation"]}

  defp origin(["draft", [conversation, "main"]]), do: {:draft, {conversation, :main}}
  defp origin(["seen", kind, id, rev]), do: {:seen, atom(kind), id, rev}
  defp origin([kind | rest]), do: List.to_tuple([atom(kind) | rest])
  defp target("main"), do: :main
  defp target([kind, id]), do: {atom(kind), id}
  defp target(["chip", kind, id]), do: {:chip, atom(kind), id}
  def intent(%{"intent" => values}), do: intent(values)

  def intent(["dispatch", operation, text, target, refs]),
    do: {:dispatch, atom(operation), text, target(target), refs}

  def intent(["run_control", operation, id]), do: {:run_control, atom(operation), id}

  def intent(["resolve_approval", run, node, id, rev, decision]),
    do: {:resolve_approval, run, node, id, rev, atom(decision)}

  def intent(["mark_seen", kind, id, rev]), do: {:mark_seen, atom(kind), id, rev}
  def intent([kind | rest]), do: List.to_tuple([atom(kind) | rest])
  def action("back"), do: :back
  def action(["scroll", panel, "follow"]), do: {:scroll, panel, :follow}
  def action(["navigate", "activity"]), do: {:navigate, :activity}
  def action(["navigate", [kind, id]]), do: {:navigate, {atom(kind), id}}
  def action(["open_layer", "help"]), do: {:open_layer, :help}

  def action(["open_layer", ["run_inspector", run, tab]]),
    do: {:open_layer, {:run_inspector, run, atom(tab)}}

  def action(["quit_requested", "detach"]), do: {:quit_requested, :detach}

  def request(row) do
    value = row["request"]

    %Request{
      request_id: value["request_id"],
      kind: intent(value["kind"]),
      scope: scope(value["scope"]),
      generation: value["generation"],
      origin: origin(value["origin"]),
      deadline: value["deadline"],
      expected_response: :outcome
    }
  end

  def presenter(row) do
    c = context(row)

    run = %DTO.RunSummary{
      id: "run-a2",
      conversation_id: "conversation-a",
      revision: c.subject_revision || 3,
      state: c.active_run_state || :running,
      allowed_actions: c.allowed_actions
    }

    node = %DTO.TranscriptItem{
      id: "node-a2",
      node_id: "node-a2",
      run_id: run.id,
      conversation_id: run.conversation_id,
      attempt_id: "attempt",
      allowed_actions: c.allowed_actions
    }

    p = %{
      Presenter.new(%Options{})
      | scope: c.scope,
        generation: c.scope_generation,
        source_epoch: "fixture",
        status: :ready,
        runs: %{run.id => run},
        nodes: %{{run.id, node.node_id} => node},
        conversations: %{"conversation-a" => %{revision: 3, allowed_actions: c.allowed_actions}},
        activities: %{
          "activity-1" => %DTO.ActivityItem{
            id: "activity-1",
            run_id: "run-a2",
            conversation_id: "conversation-a",
            revision: 3,
            allowed_actions: c.allowed_actions
          }
        },
        staged_refs: ["attachment-1"],
        allowed_actions: c.allowed_actions
    }

    p =
      if c.active_agent_id,
        do: %{
          p
          | agents: %{
              {run.id, c.active_agent_id} => %DTO.AgentSummary{
                id: c.active_agent_id,
                run_id: run.id,
                revision: c.subject_revision,
                allowed_actions: c.allowed_actions
              }
            }
        },
        else: p

    p =
      case c.interaction do
        {kind, run, node, id, rev} ->
          question =
            if kind == :question,
              do: %DTO.Question{
                prompt: "Choose",
                options: [
                  %DTO.QuestionOption{id: "option-1", label: "First"},
                  %DTO.QuestionOption{id: "option-2", label: "Second"}
                ]
              }

          i = %DTO.PendingInteraction{
            id: id,
            run_id: run,
            node_id: node,
            conversation_id: "conversation-a",
            kind: kind,
            expected_revision: rev,
            allowed_actions: c.allowed_actions,
            question: question
          }

          %{p | interactions: %{id => i}, current_prompt: i}

        nil ->
          p
      end

    case row["context_fixture"] do
      "retry_no_permission" ->
        put_in(p.runs[run.id].allowed_actions, [])

      "agent_no_permission" ->
        put_in(p.agents[{run.id, c.active_agent_id}].allowed_actions, [])

      "approval_no_always" ->
        put_in(p.interactions["approval-1"].allowed_actions, [:approve, :deny])

      _ ->
        p
    end
  end

  def tui_target(row) do
    alias SwarmCodeCLI.UI.{
      State,
      Size,
      Capabilities,
      Draft,
      Drafts,
      Editor,
      Projector,
      ReadModel,
      SafeText
    }

    alias SwarmCodeCLI.UI.Draft.AttachmentRef
    p = presenter(row)
    c = context(row)
    size = %Size{columns: 180, rows: 50}
    capabilities = %Capabilities{size: size}
    {:ok, editor} = Editor.apply(Editor.new(), {:insert, c.editor_text})

    attachments =
      Enum.map(c.attachment_refs, fn ref ->
        AttachmentRef.new!(
          id: ref,
          reference: ref,
          name: SafeText.chrome(:empty),
          media_type: "image/png",
          byte_size: 0,
          status: :ready
        )
      end)

    draft = %{
      Draft.new({"conversation-a", :main}, editor)
      | target: c.dispatch_target,
        attachments: attachments
    }

    model = %ReadModel{
      runs: p.runs,
      transcript: Map.new(p.nodes, fn {_, n} -> {n.id, n} end),
      agents: Map.new(p.agents, fn {_, a} -> {a.id, a} end),
      interactions: p.interactions,
      activity: p.activities,
      snapshots: %{
        workspace: %DTO.WorkspaceSnapshot{
          conversation_id: "conversation-a",
          revision: 3,
          allowed_actions: c.allowed_actions
        }
      },
      order: %{shell: ["run-a2"], workspace: ["node-a2"], activity: ["activity-1"]}
    }

    layers =
      case c.interaction do
        {kind, _, _, id, _} -> [{kind, id}]
        nil -> []
      end

    destination =
      case intent(row) do
        {:mark_seen, :activity, _, _} -> :activity
        {:mark_seen, :conversation, _, _} -> {:conversation, "conversation-a"}
        {:dispatch, _, _, _, _} -> {:conversation, "conversation-a"}
        _ -> {:run, "run-a2"}
      end

    state = %State{
      size: size,
      capabilities: capabilities,
      source_epoch: "fixture",
      read_model: model,
      destination: destination,
      drafts: Drafts.new() |> Drafts.put(draft),
      layers: layers,
      selection: %{{:question, "q1"} => ["option-2"]}
    }

    {_scene, actions} = Projector.project(state)
    Enum.find(Map.values(actions), &(&1 == {:intent, intent(row)}))
  end

  def encode(request), do: ContractFixtures.canonical_request_bytes(request)
  # Only fixed test-table vocabulary is decoded. Production command parsing never atomizes input.
  defp atom(value) do
    atoms = [
      :conversation,
      :run,
      :activity,
      :main,
      :draft,
      :interaction,
      :agent,
      :run_revision,
      :seen,
      :reply,
      :thread,
      :revise,
      :command,
      :goal,
      :research,
      :chip,
      :send,
      :queue,
      :steer,
      :pause,
      :continue,
      :resume,
      :stop,
      :retry,
      :stop_agent,
      :answer_question,
      :approve,
      :deny,
      :always_allow,
      :mark_seen,
      :interrupted,
      :streaming,
      :running,
      :waiting_question,
      :waiting_approval,
      :failed,
      :question,
      :approval,
      :dispatch,
      :run_control,
      :retry_run,
      :resolve_approval,
      :overview,
      :agents,
      :timeline,
      :changes
    ]

    Enum.find(atoms, &(Atom.to_string(&1) == value)) || raise("unknown fixture atom")
  end
end
