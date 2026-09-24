defmodule SwarmCodeCLI.Test.Pass73Scenes do
  @moduledoc """
  pass73 owner V1: the owner's screenshot 11 as a read model. A
  `/create-workflow` turn is in chat (its agent is the "Workflow author")
  while a swarm of four reviewers runs beside it, and one reviewer waits on a
  multi-line `curl … | python3 -c "…"` command. The draft the owner was
  typing sits in the composer.

  The reviewers' names reproduce the three names the owner saw for one
  agent: `review-angular-plan` on the card, `angular-plan` in the band and
  `angular` on the compact row (the `review-` prefix is shared by all four,
  the `-plan` suffix by three).
  """
  alias SwarmCodeCLI.Demo.Panel, as: Scenes
  alias SwarmCodeCLI.UI.{Capabilities, Drafts, Editor, Size}
  alias SwarmCodeCLI.UI.DataSource.DTO

  @conversation "demo-panel"
  @swarm "demo-panel-run-80"
  @chat "demo-panel-run-81"

  @names %{
    "engine-lifecycle-review" => "review-angular-plan",
    "data-persistence-review" => "review-elixir-plan",
    "llm-tools-review" => "review-security-plan",
    "web-ui-desktop-review" => "review-deploy"
  }

  @command """
  cd apps/ailogic_web && curl -s http://localhost:4000/api/plans/42 -H 'accept: application/json' | python3 -c "
  import json,sys
  d = json.load(sys.stdin)
  for k in sorted(d):
      print(k, type(d[k]).__name__)
  print(len(d['steps']), 'steps')
  print(d['angular']['version'])
  print(d['owner'])
  "\
  """

  def command, do: @command
  def swarm_id, do: @swarm
  def chat_id, do: @chat
  def angular_id, do: "agent-80-2"

  @doc "The scene at `columns` x `rows`; `opts`: `:panel` mode, `:draft`, `:mode`, `:ascii?`, `:policy`."
  def screenshot_11(columns, rows, opts \\ []) do
    size = %Size{columns: columns, rows: rows}

    caps = %Capabilities{
      size: size,
      color_mode: Keyword.get(opts, :mode, :truecolor),
      ascii?: Keyword.get(opts, :ascii?, false),
      glyph_tier: Keyword.get(opts, :tier, :rich),
      ambiguous_width: Keyword.get(opts, :policy, :narrow)
    }

    state = Scenes.state(:panel_swarm_2, size, caps)
    model = state.read_model
    now = state.now

    agents =
      Map.new(model.agents, fn {id, agent} ->
        agent = %{agent | name: Map.get(@names, agent.name, agent.name)}

        agent =
          cond do
            id == angular_id() ->
              %{agent | state: :waiting_approval}
              |> Map.put(:panel_state, :needs_you)
              |> Map.put(:lane, [:tools, :tools, :think, :tools, :you, :you, :you, :you])

            id == "agent-80-5" ->
              agent
              |> Map.put(:state, :running)
              |> Map.put(:panel_state, :working)
              |> Map.put(:now, "reading the deploy scripts")

            true ->
              agent
          end

        {id, agent}
      end)

    chat_run = %DTO.RunSummary{
      id: @chat,
      conversation_id: @conversation,
      kind: :chat,
      title: "/create-workflow a nightly check of the angular plans",
      revision: 2,
      state: :running,
      allowed_actions: [:stop],
      created_sequence: 81,
      started_at: now - 48_000,
      tokens_in: 9_000,
      tokens_out: 1_000,
      cost_usd: 0.02,
      model: "deepseek-v4-pro"
    }

    author = %DTO.AgentSummary{
      id: "agent-81-1",
      run_id: @chat,
      revision: 1,
      state: :streaming,
      name: "Workflow author",
      role: :assistant,
      title: "Workflow author",
      step: "",
      tokens_in: 9_000,
      tokens_out: 1_000,
      started_at: now - 48_000,
      depth: 0
    }

    author = author |> Map.put(:panel_state, :thinking) |> Map.put(:now, "drafting the phases")

    approval = %DTO.PendingInteraction{
      id: "demo-approval-80",
      run_id: @swarm,
      node_id: "demo-op-80",
      conversation_id: @conversation,
      kind: :approval,
      expected_revision: 1,
      state: :pending,
      approval: %DTO.Approval{
        tool: "run_command",
        permission: :execute,
        command: @command,
        command_family: "curl",
        classification: :dangerous,
        reason: "check the plan payload's shape before the angular client changes",
        arguments_preview: Jason.encode!(%{"command" => @command}),
        agent_id: angular_id(),
        agent_name: "review-angular-plan",
        allowed_decisions: [:approve, :approve_run, :always_prefix, :deny, :deny_stop]
      },
      allowed_actions: [:approve, :deny],
      created_at: now - 12_000
    }

    items = [
      item(@chat, 81_000, now - 48_000,
        role: :user,
        text: "/create-workflow a nightly check of the angular plans"
      ),
      item(@chat, 81_001, now - 30_000,
        role: :assistant,
        kind: :text,
        agent_id: "agent-81-1",
        text: "Drafting the workflow: a scan phase, a check per plan and a report.",
        state: :streaming
      )
    ]

    runs = Map.put(model.runs, @chat, chat_run)

    swarm = Map.fetch!(runs, @swarm)
    runs = Map.put(runs, @swarm, %{swarm | created_sequence: 80})

    order = Map.get(model.order, :workspace, []) ++ Enum.map(items, & &1.id)

    model = %{
      model
      | runs: runs,
        agents: Map.put(agents, author.id, author),
        interactions: %{approval.id => approval},
        transcript: Map.merge(model.transcript, Map.new(items, &{&1.id, &1})),
        order: %{model.order | workspace: order, shell: [@chat, @swarm]}
    }

    state = %{state | read_model: model, destination: {:conversation, @conversation}}
    state = Map.put(state, :panel_mode, Keyword.get(opts, :panel, :full))

    case Keyword.get(opts, :draft) do
      nil -> state
      text -> put_draft(state, text)
    end
  end

  @doc "`state` with `text` typed in the composer."
  def put_draft(state, text) do
    key = SwarmCodeCLI.UI.State.current_draft_key(state)
    draft = Drafts.fetch(state.drafts, key)
    {:ok, editor} = Editor.apply(draft.editor, {:paste, text})
    %{state | drafts: Drafts.put(state.drafts, %{draft | editor: editor})}
  end

  defp item(run, seq, at, fields) do
    struct!(
      %DTO.TranscriptItem{
        id: "#{run}-item-#{seq}",
        run_id: run,
        conversation_id: @conversation,
        node_id: "#{run}-node-#{seq}",
        revision: 1,
        role: :assistant,
        state: :done,
        text: "",
        reasoning: "",
        attempt_id: "demo-attempt",
        created_sequence: seq,
        at: at
      },
      fields
    )
  end
end
