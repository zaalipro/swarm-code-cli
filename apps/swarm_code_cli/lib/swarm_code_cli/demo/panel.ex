defmodule SwarmCodeCLI.Demo.Panel do
  @moduledoc """
  Synthetic read models shaped like the side panel mockups of pass 72
  (`docs/superpowers/specs/2026-09-23-side-panel/D2.html`): one scene per
  frame the panel owns. No daemon, filesystem or provider is involved; the
  names and sentences are the mockups' own, for layout review, the golden
  tests and the gallery.

  The pass-72 summary fields (an agent's `now`, `lane`, `finding`,
  `finding_refs`; a run's `phases`, `goal`, `research`, `positions`) are put
  on the summaries as the wire will carry them.

  Scenes: `:panel_chat`, `:panel_swarm_1` (02:10), `:panel_swarm_2` (02:14,
  web waits on a command), `:panel_swarm_3` (02:31, three findings),
  `:panel_workflow`, `:panel_goal`, `:panel_plan`, `:panel_research`,
  `:panel_consensus` and `:panel_heavy` (five runs, seventeen agents, two
  waiting on you).
  """
  alias SwarmCodeCLI.UI.{Capabilities, Draft, Drafts, Editor, ReadModel, Size, State}
  alias SwarmCodeCLI.UI.DataSource.DTO

  @clock 1_788_436_800_000
  @conversation "demo-panel"
  @model "deepseek-v4-pro"

  @scenes [
    :panel_chat,
    :panel_swarm_1,
    :panel_swarm_2,
    :panel_swarm_3,
    :panel_workflow,
    :panel_goal,
    :panel_plan,
    :panel_research,
    :panel_consensus,
    :panel_heavy
  ]

  @doc "Every scene, in the order the gallery shows them."
  def scenes, do: @scenes

  @doc "The state a scene draws, at `size` for `capabilities`."
  def state(scene, %Size{} = size, %Capabilities{} = capabilities) when scene in @scenes do
    capabilities = %{capabilities | size: size}
    {runs, agents, interactions, items, extra} = build(scene)
    mode = Keyword.get(extra, :approval_mode, :read_only)
    in_chat = hd(runs)

    order = items |> Enum.sort_by(&{&1.created_sequence, &1.id}) |> Enum.map(& &1.id)

    model = %ReadModel{
      runs: Map.new(runs, &{&1.id, &1}),
      transcript: Map.new(items, &{&1.id, &1}),
      agents: Map.new(agents, &{&1.id, &1}),
      interactions: Map.new(interactions, &{&1.id, &1}),
      changes: Map.new(Keyword.get(extra, :changes, []), &{&1.id, &1}),
      order: %{
        shell: runs |> Enum.sort_by(& &1.created_sequence, :desc) |> Enum.map(& &1.id),
        workspace: order
      },
      snapshots: %{workspace: workspace(runs, mode, extra)}
    }

    editor = Editor.new(ambiguous_width: capabilities.ambiguous_width)
    draft = Draft.new({@conversation, :main}, editor)
    drafts = Drafts.new(ambiguous_width: capabilities.ambiguous_width) |> Drafts.put(draft)

    %State{
      size: size,
      capabilities: capabilities,
      source_epoch: "demo-epoch",
      destination: {:run, in_chat.id},
      read_model: model,
      drafts: drafts,
      focus: "composer",
      revision: 1,
      now: @clock
    }
  end

  defp workspace(runs, mode, extra) do
    %DTO.WorkspaceSnapshot{
      conversation_id: @conversation,
      project: "swarm-code",
      mode: :build,
      chat_model: @model,
      swarm_model: @model,
      chat_provider: "llmotions",
      approval_mode: mode,
      trusted: mode != :read_only,
      context_used: Keyword.get(extra, :context_used, 26_000),
      context_window: Keyword.get(extra, :context_window, 200_000),
      cost_usd: runs |> Enum.map(&(&1.cost_usd || 0)) |> Enum.sum(),
      allowed_actions: [:send, :queue, :mark_seen],
      runs: runs,
      models: [%DTO.ModelOption{provider_id: "p1", provider: "llmotions", model: @model}]
    }
  end

  # ------------------------------------------------------------- scenes

  defp build(:panel_chat) do
    run =
      run(10, :chat, "fix the flaky retry test", :running, 42_000,
        tokens: 12_000,
        cost: 0.03,
        model: "opus-5"
      )
      |> Map.merge(%{lane: lane("ttooototwoow"), now: "editing agent_server_test.exs"})

    earlier = [
      run(1, :chat, "hi mate", :done, 360_000, duration: 6_000, tokens: 7_000, cost: 0.004),
      run(2, :swarm, "architecture review", :done, 300_000,
        duration: 182_000,
        tokens: 79_000,
        cost: 0.18
      )
    ]

    items = [
      user(run, 0, 42_000, "fix the flaky retry test in agent_server_test.exs"),
      text(
        run,
        1,
        11_000,
        "The flake is a timer race, not a retry bug; swapping sleep(50) for a monitor."
      )
    ]

    changes = [
      change(run, 1, "test/swarm_code/agent_server_test.exs", 12, 3),
      change(run, 2, "test/support/fake_clock.ex", 4, 1)
    ]

    {[run | earlier], [], [], items, approval_mode: :auto, changes: changes}
  end

  defp build(:panel_swarm_1), do: review(130_000, :one)
  defp build(:panel_swarm_2), do: review(134_000, :two)
  defp build(:panel_swarm_3), do: review(151_000, :three)

  defp build(:panel_workflow) do
    run =
      run(20, :workflow, "ship retry", :running, 252_000, tokens: 58_000, cost: 0.41)
      |> Map.put(:phases, [
        %{name: "scan", state: :done},
        %{name: "plan", state: :done},
        %{name: "implement", state: :running},
        %{name: "verify", state: :queued},
        %{name: "report", state: :queued}
      ])

    agents = [
      agent(run, 1, "migrate", :worker, :done, 88_000, 6_000,
        finding: "added an attempts column to jobs",
        files_changed: 1
      ),
      agent(run, 2, "retry-tests", :worker, :failed, 84_000, 9_000,
        lane: "oooototooox..",
        error: "tests failed: double charge on replay",
        retry_at: @clock + 8_000
      ),
      agent(run, 3, "client", :worker, :running, 80_000, 11_000,
        lane: "oowootowwoto",
        now: "wiring backoff into Req calls"
      )
    ]

    changes = [
      change(run, 1, "priv/repo/migrations/20260924_add_attempts.exs", 18, 0),
      change(run, 2, "lib/jobs/retry.ex", 42, 7)
    ]

    {[run], agents, [], [user(run, 0, 252_000, "/workflow ship retry")],
     approval_mode: :auto, changes: changes}
  end

  defp build(:panel_goal) do
    run =
      run(30, :goal, "suite green", :running, 700_000, cost: 0.62)
      |> Map.put(:goal, %{
        iteration: 3,
        max: 5,
        verdicts: [:not_met, :not_met],
        criteria: [
          %{text: "core suite passes", met_in: 1},
          %{text: "no compile warnings", met_in: 2},
          %{text: "web suite passes", met_in: nil},
          %{text: "credo --strict is clean", met_in: nil}
        ],
        last_verdict:
          "core is green; the web suite still fails in retry_test on timeouts, not asserts"
      })

    agents = [
      agent(run, 1, "goal agent", :worker, :streaming, 185_000, 22_000,
        lane: "ttooottttttt",
        now: "why retry_test times out"
      )
    ]

    {[run], agents, [], [user(run, 0, 700_000, "/goal suite green")], approval_mode: :auto}
  end

  defp build(:panel_plan) do
    run =
      run(40, :chat, "rate limits for the API", :waiting_question, 200_000,
        tokens: 31_000,
        cost: 0.08
      )

    agents = [
      agent(run, 1, "Planner", :lead, :waiting_question, 200_000, 31_000, lane: "toottttootyyy")
    ]

    ask = %DTO.PendingInteraction{
      id: "demo-question-40",
      run_id: run.id,
      node_id: "agent-40-1",
      conversation_id: @conversation,
      kind: :question,
      expected_revision: 1,
      question: %DTO.Question{prompt: "limit per API key, or per client IP?", options: []},
      allowed_actions: [:answer_question],
      created_at: @clock - 20_000
    }

    {[run], agents, [ask], [user(run, 0, 200_000, "/plan rate limits for the API")],
     approval_mode: :read_only}
  end

  defp build(:panel_research) do
    run =
      run(50, :research, "Req vs Finch pooling", :running, 168_000, tokens: 44_000, cost: 0.11)
      |> Map.put(:research, %{
        found: 24,
        read: 11,
        used: 6,
        sections: [
          %{title: "what Req pools by default", state: :done},
          %{title: "sizing a Finch pool", state: :done},
          %{title: "when to share one pool", state: :running},
          %{title: "recommendation", state: :queued}
        ]
      })

    agents = [
      agent(run, 1, "Lead", :lead, :running, 168_000, 20_000,
        lane: "ttwwwtwwwwtw",
        now: "writing § 3 of the report"
      ),
      agent(run, 2, "reader-docs", :worker, :done, 90_000, 12_000,
        finding: "NimblePool is gone from Req"
      ),
      agent(run, 3, "reader-code", :worker, :running, 112_000, 12_000,
        lane: "ooootoooooto",
        now: "reading Finch pool_manager.ex"
      )
    ]

    {[run], agents, [], [user(run, 0, 168_000, "/research Req vs Finch pooling")],
     approval_mode: :auto}
  end

  defp build(:panel_consensus) do
    run =
      run(60, :consensus, "should runs own worktrees?", :running, 190_000,
        tokens: 38_000,
        cost: 0.22
      )
      |> Map.merge(%{
        positions: [
          %{letter: "A", text: "yes, one worktree per writer run"},
          %{letter: "B", text: "only when 2+ agents write"},
          %{letter: "C", text: "no, checkpoints are enough"}
        ],
        round: 2,
        rounds: 3,
        agreement: "2 of 3 on A"
      })

    agents = [
      agent(run, 1, "opus", :worker, :running, 190_000, 9_000,
        lane: "ttttoo......",
        now: "holds A, waits for round 3",
        activity: :waiting
      ),
      agent(run, 2, "gpt", :worker, :running, 190_000, 10_000,
        lane: "tttoott.....",
        now: "moved to A this round",
        activity: :waiting
      ),
      agent(run, 3, "gemini", :worker, :streaming, 190_000, 11_000,
        lane: "tttttttttttt",
        now: "restating C against A"
      )
    ]

    {[run], agents, [], [user(run, 0, 190_000, "/consensus should runs own worktrees?")],
     approval_mode: :auto}
  end

  defp build(:panel_heavy) do
    {[review_run], review_agents, review_asks, review_items, _} = review(134_000, :two)

    api = run(70, :swarm, "api hardening", :running, 302_000, tokens: 40_000, cost: 0.31)

    api_agents = [
      agent(api, 1, "Lead", :lead, :running, 302_000, 12_000,
        lane: "t..t..t.",
        now: "waiting on 3 workers"
      ),
      agent(api, 2, "auth", :worker, :running, 200_000, 14_000,
        lane: "ooototoow",
        now: "adding token expiry to the session plug"
      ),
      agent(api, 3, "limits", :worker, :streaming, 200_000, 9_000,
        lane: "tttotttt",
        now: "choosing a bucket size"
      ),
      agent(api, 4, "plug", :worker, :waiting_approval, 200_000, 10_000, lane: "owoowyyy")
    ]

    edit = %DTO.PendingInteraction{
      id: "demo-approval-70",
      run_id: api.id,
      node_id: "demo-op-70",
      conversation_id: @conversation,
      kind: :approval,
      expected_revision: 1,
      approval: %DTO.Approval{
        tool: "edit_file",
        permission: :write,
        arguments_preview: ~s({"path":"lib/api/plug.ex"}),
        agent_id: "agent-70-4",
        agent_name: "plug"
      },
      allowed_actions: [:approve, :deny],
      created_at: @clock - 30_000
    }

    {[goal], goal_agents, _, _, _} = build(:panel_goal)
    {[cons], cons_agents, _, _, _} = build(:panel_consensus)

    judge = agent(cons, 4, "judge", :judge, :queued, nil, 0, now: "scores after round 3")

    {[flow], flow_agents, _, _, _} = build(:panel_workflow)

    runs = [
      review_run,
      api,
      %{goal | created_sequence: 69},
      %{cons | created_sequence: 68},
      %{flow | created_sequence: 67}
    ]

    agents =
      review_agents ++ api_agents ++ goal_agents ++ cons_agents ++ [judge] ++ flow_agents

    {runs, agents, [edit | review_asks], review_items, approval_mode: :read_only}
  end

  # The four read-only reviewers of the owner's own swarm, at three moments.
  defp review(elapsed, moment) do
    run =
      run(80, :swarm, "architecture review", :running, elapsed,
        tokens: %{one: 57_000, two: 65_000, three: 79_000}[moment],
        cost: %{one: 0.13, two: 0.15, three: 0.18}[moment]
      )

    lead =
      case moment do
        :three ->
          agent(run, 1, "Lead", :lead, :running, elapsed, 13_000,
            lane: "t..tttottttt",
            now: "merging 3 of 4 findings",
            activity: :working
          )

        _ ->
          agent(run, 1, "Lead", :lead, :running, elapsed, 9_000,
            lane: "....t.....t.",
            now: "waiting on 3 reviewers"
          )
      end

    engine =
      case moment do
        :three ->
          agent(run, 2, "engine-lifecycle-review", :worker, :done, 108_000, 19_000,
            finding: "stop reason read before the flush",
            finding_refs: ["run_server.ex:214", "agent_server.ex:88"]
          )

        _ ->
          agent(run, 2, "engine-lifecycle-review", :worker, :running, 104_000, 16_000,
            lane: "oooootooooott",
            now: "tracing where stop is saved"
          )
      end

    data =
      agent(run, 3, "data-persistence-review", :worker, :streaming, 104_000, 12_000,
        lane: "tttotttotttt",
        now: "weighing flush vs retry order"
      )

    llm =
      agent(run, 4, "llm-tools-review", :worker, :done, 102_000, 9_000,
        finding: "Fake provider never reaches the refusal branch",
        finding_refs: ["fake.ex:88", "anthropic.ex:301"]
      )

    web =
      case moment do
        :one ->
          agent(run, 5, "web-ui-desktop-review", :worker, :running, 100_000, 16_000,
            lane: "ooototooooooo",
            now: "reading LiveView key hooks"
          )

        :two ->
          agent(run, 5, "web-ui-desktop-review", :worker, :waiting_approval, 100_000, 19_000,
            lane: "ootoooooyyyy"
          )

        :three ->
          agent(run, 5, "web-ui-desktop-review", :worker, :done, 100_000, 23_000,
            finding: "three key routers fire Esc twice",
            finding_refs: ["hooks.js:412", "app.js:88", "keys.ts:17"]
          )
      end

    llm =
      if moment == :one,
        do:
          agent(run, 4, "llm-tools-review", :worker, :running, 100_000, 8_000,
            lane: "ootoooootoo",
            now: "checking Fake provider paths"
          ),
        else: llm

    asks =
      if moment == :two do
        [
          %DTO.PendingInteraction{
            id: "demo-approval-80",
            run_id: run.id,
            node_id: "demo-op-80",
            conversation_id: @conversation,
            kind: :approval,
            expected_revision: 1,
            approval: %DTO.Approval{
              tool: "run_command",
              permission: :execute,
              command: "mix test test/swarm_code_web/live",
              command_family: "mix test",
              arguments_preview: ~s({"command":"mix test test/swarm_code_web/live"}),
              agent_id: "agent-80-5",
              agent_name: "web-ui-desktop-review"
            },
            allowed_actions: [:approve, :deny],
            created_at: @clock - 12_000
          }
        ]
      else
        []
      end

    items = [
      user(run, 0, elapsed, "/swarm review the architecture with 4 read-only sub-agents"),
      text(
        run,
        1,
        elapsed - 2_000,
        "Split the review into four areas and started a reviewer for each.",
        agent_id: lead.id
      )
      | Enum.with_index([engine, data, llm, web], 2)
        |> Enum.map(fn {a, i} ->
          text(run, i, elapsed - 5_000 - i, Map.get(a, :finding) || "reading", agent_id: a.id)
        end)
    ]

    {[run], [lead, engine, data, llm, web], asks, items, approval_mode: :read_only}
  end

  # -------------------------------------------------------------- facts

  defp run(n, kind, title, state, elapsed, opts) do
    started = @clock - elapsed
    duration = Keyword.get(opts, :duration)
    tokens = Keyword.get(opts, :tokens, 0)

    %DTO.RunSummary{
      id: "demo-panel-run-#{n}",
      conversation_id: @conversation,
      kind: kind,
      title: title,
      revision: 2,
      state: state,
      allowed_actions: [],
      created_sequence: n,
      started_at: started,
      finished_at: duration && started + duration,
      tokens_in: div(tokens * 9, 10),
      tokens_out: tokens - div(tokens * 9, 10),
      cost_usd: Keyword.get(opts, :cost),
      model: Keyword.get(opts, :model, @model)
    }
  end

  @wire [:now, :lane, :finding, :finding_refs, :files_changed, :activity]

  defp agent(run, i, name, role, state, elapsed, tokens, opts) do
    started = elapsed && @clock - elapsed
    done? = state in [:done, :failed]

    base = %DTO.AgentSummary{
      id: "agent-#{run.created_sequence}-#{i}",
      run_id: run.id,
      revision: 1,
      state: state,
      name: name,
      role: role,
      title: name,
      step: "",
      tokens_in: div(tokens * 9, 10),
      tokens_out: tokens - div(tokens * 9, 10),
      started_at: started,
      finished_at: if(done? and started, do: started + elapsed - 20_000),
      parent_id: if(role == :lead, do: nil, else: "agent-#{run.created_sequence}-1"),
      depth: if(role == :lead, do: 0, else: 1),
      error: Keyword.get(opts, :error),
      retry_at: Keyword.get(opts, :retry_at)
    }

    Enum.reduce(@wire, base, fn key, acc ->
      case Keyword.fetch(opts, key) do
        {:ok, value} when key == :lane -> Map.put(acc, :lane, lane(value))
        {:ok, value} -> Map.put(acc, key, value)
        :error -> acc
      end
    end)
  end

  # `t` think, `o` tools, `w` write, `y` waiting on you, `.` idle, `x` failed.
  defp lane(cells) do
    cells
    |> String.graphemes()
    |> Enum.map(fn
      "t" -> :think
      "o" -> :tools
      "w" -> :write
      "y" -> :you
      "x" -> :fail
      _ -> :idle
    end)
    |> Enum.take(-12)
  end

  defp change(run, i, path, added, removed) do
    %DTO.Change{
      id: "#{run.id}-change-#{i}",
      run_id: run.id,
      path: path,
      restorable: true,
      at: @clock - 5_000 + i,
      file_state: :modified,
      added: added,
      removed: removed
    }
  end

  defp item(run, seq, ago, fields) do
    struct!(
      %DTO.TranscriptItem{
        id: "#{run.id}-item-#{String.pad_leading(Integer.to_string(seq), 3, "0")}",
        run_id: run.id,
        conversation_id: @conversation,
        node_id: "#{run.id}-node-#{seq}",
        revision: 1,
        role: :assistant,
        state: :done,
        text: "",
        reasoning: "",
        attempt_id: "demo-attempt",
        created_sequence: run.created_sequence * 1_000 + seq,
        at: @clock - ago
      },
      fields
    )
  end

  defp user(run, seq, ago, text), do: item(run, seq, ago, role: :user, text: text)

  defp text(run, seq, ago, text, extra \\ []),
    do: item(run, seq, ago, [role: :assistant, kind: :text, text: text] ++ extra)
end
