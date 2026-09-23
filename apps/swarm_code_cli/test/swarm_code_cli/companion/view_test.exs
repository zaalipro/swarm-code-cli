defmodule SwarmCodeCLI.Companion.ViewTest do
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.Companion.View
  alias SwarmCodeCLI.UI.{Capabilities, Fixtures, ReadModel, Size, State}
  alias SwarmCodeCLI.UI.DataSource.DTO

  @keys ~w(revision session header tabs run agents transcript needs changes timeline verdict artifacts focus notice)a
  @agent_keys ~w(cost error finished_at hue id name parent_id progress role started_at state step tokens waiting)a
  @item_keys ~w(agent_id at id kind reasoning role state text tokens tool)a
  @tool_keys ~w(detail duration_ms files name result_bytes status title)a
  @size %Size{columns: 120, rows: 40}
  @caps %Capabilities{size: @size, color_mode: :truecolor}
  # The fake source's clock, the one Fixtures builds its timestamps around.
  @clock 1_788_436_800_000

  defp swarm, do: Fixtures.representative(:swarm, @size, @caps)
  defp chat, do: Fixtures.representative(:chat, @size, @caps)
  defp consensus, do: Fixtures.representative(:consensus, @size, @caps)

  defp item(state, id, attrs) do
    base = state.read_model.transcript["002"]
    put_in(state.read_model.transcript[id], struct!(base, Keyword.put(attrs, :id, id)))
  end

  defp interaction(state, %DTO.PendingInteraction{} = need),
    do: put_in(state.read_model.interactions[need.id], need)

  # A hive built from DTO structs directly, so the facts under test do not
  # depend on what the fake source happens to carry today.
  defp hive(opts \\ []) do
    run =
      struct!(
        %DTO.RunSummary{
          id: "r1",
          conversation_id: "c1",
          kind: :swarm,
          title: "Hive",
          revision: 1,
          state: :running,
          started_at: @clock
        },
        Keyword.get(opts, :run, [])
      )

    items = Keyword.get(opts, :items, [])
    agents = Keyword.get(opts, :agents, [])
    changes = Keyword.get(opts, :changes, [])
    verdicts = Keyword.get(opts, :verdicts, [])

    model = %ReadModel{
      runs: %{run.id => run},
      transcript: Map.new(items, &{&1.id, &1}),
      agents: Map.new(agents, &{&1.id, &1}),
      changes: Map.new(changes, &{&1.id, &1}),
      verdicts: Map.new(verdicts, &{&1.id, &1}),
      order: %{shell: [run.id], workspace: Enum.map(items, & &1.id)}
    }

    %State{
      source_epoch: "epoch-c2",
      destination: {:run, run.id},
      read_model: model,
      focus: "composer"
    }
  end

  defp an_agent(id, attrs),
    do:
      struct!(
        %DTO.AgentSummary{id: id, run_id: "r1", revision: 1, state: :running},
        attrs
      )

  defp a_change(id, attrs),
    do: struct!(%DTO.Change{id: id, run_id: "r1", revision: 1}, attrs)

  defp an_item(id, attrs),
    do:
      struct!(
        %DTO.TranscriptItem{
          id: id,
          run_id: "r1",
          conversation_id: "c1",
          node_id: "node-" <> id,
          revision: 1
        },
        attrs
      )

  test "every contract key is present for fixtures and for an empty state" do
    for state <- [swarm(), chat(), consensus(), %State{}] do
      view = View.build(state, 1_000)
      assert Enum.sort(Map.keys(view)) == Enum.sort(@keys)
      assert Enum.sort(Map.keys(view.session)) == [:id, :now, :started_at]

      assert Enum.sort(Map.keys(view.header)) ==
               ~w(approval context_tokens cost effort keymap mode model project)a

      assert Enum.sort(Map.keys(view.run)) ==
               ~w(edges finished_at id kind started_at state title)a

      assert Enum.sort(Map.keys(view.changes)) == [:blast, :files, :unavailable]
      assert view.changes.unavailable == nil
      assert Enum.sort(Map.keys(view.timeline)) == [:checkpoints, :events]
      assert view.artifacts == []
      assert Enum.sort(Map.keys(view.focus)) == [:id, :kind]
      assert view.session.now == 1_000

      for agent <- view.agents, do: assert(Enum.sort(Map.keys(agent)) == @agent_keys)
      for item <- view.transcript, do: assert(Enum.sort(Map.keys(item)) == @item_keys)

      for tool <- Enum.map(view.transcript, & &1.tool),
          tool != nil,
          do: assert(Enum.sort(Map.keys(tool)) == @tool_keys)

      for file <- view.changes.files,
          do: assert(Enum.sort(Map.keys(file)) == ~w(agent_id at id path restorable)a)

      for blast <- view.changes.blast,
          do: assert(Enum.sort(Map.keys(blast)) == [:agent_ids, :path])

      for event <- view.timeline.events,
          do: assert(Enum.sort(Map.keys(event)) == [:agent_id, :at, :kind])

      for checkpoint <- view.timeline.checkpoints,
          do: assert(Enum.sort(Map.keys(checkpoint)) == [:at, :label])
    end
  end

  test "an empty state carries empty collections, never a missing key" do
    view = View.build(%State{}, 0)
    assert view.changes == %{files: [], blast: [], unavailable: nil}
    assert view.timeline == %{events: [], checkpoints: []}
    assert view.verdict == nil and view.agents == [] and view.transcript == []
    assert view.run.edges == [] and view.header.cost == nil and view.header.context_tokens == nil
  end

  test "encodes to JSON with string keys and words for every enum" do
    decoded = swarm() |> View.build(5) |> Jason.encode!() |> Jason.decode!()
    assert decoded["session"]["id"] == "fixture-"
    assert decoded["run"]["state"] == "streaming" and decoded["run"]["kind"] == "swarm"
    assert Enum.map(decoded["agents"], & &1["state"]) |> Enum.all?(&is_binary/1)
    assert decoded["header"]["keymap"] == "default"
    assert hd(decoded["agents"])["name"] == "lead" and hd(decoded["agents"])["role"] == "lead"
    tool = Enum.find_value(decoded["transcript"], & &1["tool"])
    assert tool["name"] == "grep" and tool["status"] == "done" and tool["duration_ms"] == 400
    assert hd(decoded["changes"]["files"])["path"] == "lib/swarm_code/repo.ex"

    verdict =
      consensus() |> View.build(5) |> Jason.encode!() |> Jason.decode!() |> Map.get("verdict")

    assert verdict["round"] == 1 and verdict["status"] == "done"

    assert hd(verdict["checks"]) == %{
             "key" => "tests_pass",
             "ok" => true,
             "note" => "142 tests, 0 failures"
           }
  end

  test "tabs take their counts and times from the run summary" do
    assert [tab] = View.build(swarm(), 0).tabs
    assert tab.id == "fixture-run" and tab.active and tab.agents == 5 and tab.needs == 1
    assert tab.state == "streaming" and tab.kind == "swarm" and tab.title =~ "Swarm"
    assert tab.started_at == @clock - 300_000 and tab.finished_at == nil
  end

  test "agents carry the daemon's names, roles, steps, gauges, tokens and cost" do
    view = View.build(swarm(), 0)
    assert Enum.map(view.agents, & &1.id) == ~w(agent-1 agent-2 agent-3 agent-4 agent-5)
    assert Enum.map(view.agents, & &1.name) == ~w(lead scout-1 scout-2 builder-4 judge)
    assert Enum.map(view.agents, & &1.role) == ~w(lead sub sub worker judge)
    assert Enum.map(view.agents, & &1.hue) == [0, 1, 2, 3, 4]
    assert Enum.map(view.agents, & &1.waiting) == [false, false, false, false, true]
    assert Enum.map(view.agents, & &1.progress) == [0.35, 0.7, 0.55, 0.4, 0.5]
    assert Enum.map(view.agents, & &1.parent_id) == [nil | List.duplicate("agent-1", 4)]

    lead = hd(view.agents)
    assert lead.step == "planning" and lead.tokens == 7_600 and lead.cost == 0.12
    assert lead.started_at == @clock - 285_000 and lead.finished_at == nil and lead.error == nil
    assert List.last(view.agents).step == "waiting for you"

    assert view.run.edges ==
             for(
               id <- ~w(agent-2 agent-3 agent-4 agent-5),
               do: %{from: "agent-1", to: id, kind: "spawn"}
             )

    assert View.build(chat(), 0).agents == []
  end

  test "without roles or parents the earliest non-user author leads and spawns the rest" do
    state =
      hive(
        agents: for(n <- 1..8, do: an_agent("a#{n}", [])),
        items: [
          an_item("i1", role: :user, state: :done, at: @clock),
          an_item("i2", role: :assistant, agent_id: "a3", state: :streaming, at: @clock + 1_000)
        ]
      )

    view = View.build(state, 0)
    assert [lead | rest] = view.agents
    assert lead.id == "a3" and lead.role == "lead" and lead.name == "agent-a3"
    assert lead.hue == 0 and lead.parent_id == nil and lead.tokens == nil and lead.cost == nil
    assert Enum.map(rest, & &1.id) == ~w(a1 a2 a4 a5 a6 a7 a8)
    assert Enum.all?(rest, &(&1.role == "worker" and &1.parent_id == "a3"))
    # hue is the index modulo six, so the seventh lane wraps back onto the lead's colour
    assert Enum.map(rest, & &1.hue) == [1, 2, 3, 4, 5, 0, 1]
    assert Enum.map(view.run.edges, & &1.to) == ~w(a1 a2 a4 a5 a6 a7 a8)
    assert Enum.all?(view.run.edges, &(&1.from == "a3" and &1.kind == "spawn"))
  end

  test "reported parents win: edges follow them and nothing is invented" do
    state =
      hive(
        agents: [
          an_agent("a1", role: :lead),
          an_agent("a2", parent_id: "a1", depth: 1),
          an_agent("a3", parent_id: "a2", depth: 2),
          an_agent("a4", depth: 1)
        ]
      )

    view = View.build(state, 0)
    # lanes are ordered by depth, so a child of a child lands last
    assert Enum.map(view.agents, & &1.id) == ~w(a1 a2 a4 a3)
    assert Enum.map(view.agents, & &1.parent_id) == [nil, "a1", nil, "a2"]

    assert view.run.edges == [
             %{from: "a1", to: "a2", kind: "spawn"},
             %{from: "a2", to: "a3", kind: "spawn"}
           ]
  end

  test "progress falls back to the state only when the daemon reports no gauge" do
    state =
      hive(
        agents: [
          an_agent("a1", progress: 100, state: :running),
          an_agent("a2", progress: 0, state: :done),
          an_agent("a3", progress: 0, state: :queued),
          an_agent("a4", progress: 0, state: :streaming)
        ]
      )

    assert Enum.map(View.build(state, 0).agents, & &1.progress) == [1.0, 1.0, 0.0, 0.5]
  end

  test "transcript items carry their kind, tool call, tokens and time" do
    view = View.build(swarm(), 0)
    # Prompt, then the work, then the words: the reply the daemon created
    # before the tool calls reads after them, as it does in the terminal.
    assert Enum.map(view.transcript, & &1.id) == ~w(001 005 006 007 008 002 009)
    assert Enum.map(view.transcript, & &1.kind) == ~w(text tool tool thinking tool text error)

    grep = Enum.find(view.transcript, &(&1.id == "005"))
    assert grep.agent_id == "agent-2" and grep.tokens == 876 and grep.at == @clock - 170_000

    assert grep.tool == %{
             name: "grep",
             title: "grep \"Repo\\.\"",
             detail: "lib/ test/ · 41 hits",
             status: "done",
             duration_ms: 400,
             result_bytes: 3_812,
             files: []
           }

    edit = Enum.find(view.transcript, &(&1.id == "008"))
    assert edit.tool.files == ["lib/swarm_code/repo.ex"] and edit.tool.status == "running"
    assert edit.tool.duration_ms == nil
    assert Enum.find(view.transcript, &(&1.id == "007")).tool == nil
    assert Enum.find(view.transcript, &(&1.id == "007")).reasoning =~ "builder-4"
    assert Enum.find(view.transcript, &(&1.id == "001")).tokens == nil
  end

  test "an item with no time of its own inherits the previous one, starting at the run" do
    state =
      hive(
        items: [
          an_item("i1", role: :user, created_sequence: 1, at: 0),
          an_item("i2", created_sequence: 2, at: @clock + 5_000),
          an_item("i3", created_sequence: 3, at: 0)
        ]
      )

    assert Enum.map(View.build(state, 0).transcript, & &1.at) ==
             [@clock, @clock + 5_000, @clock + 5_000]
  end

  test "timeline events name you, the lead, other agents, the judge, tools and waits" do
    state =
      hive(
        agents: [
          an_agent("a1", role: :lead),
          an_agent("a2", parent_id: "a1"),
          an_agent("a3", role: :judge, parent_id: "a1")
        ],
        items: [
          an_item("i1", role: :user, state: :done, at: @clock + 1),
          an_item("i2", agent_id: "a1", state: :streaming, at: @clock + 2),
          an_item("i3", agent_id: "a2", state: :done, at: @clock + 3),
          an_item("i4", agent_id: "a2", kind: :tool, state: :done, at: @clock + 4),
          an_item("i5", agent_id: "a3", kind: :tool, state: :done, at: @clock + 5),
          an_item("i6", agent_id: "a2", state: :waiting_approval, at: @clock + 6),
          an_item("i7", agent_id: "gone", state: :done, at: @clock + 7)
        ]
      )

    view = View.build(state, 0)
    assert Enum.map(view.timeline.events, & &1.kind) == ~w(you lead agent tool judge wait lead)
    assert Enum.map(view.timeline.events, & &1.at) == Enum.map(1..7, &(@clock + &1))

    assert Enum.map(view.timeline.events, & &1.agent_id) == [
             nil,
             "a1",
             "a2",
             "a2",
             "a3",
             "a2",
             nil
           ]
  end

  test "changes list the run's ledger and name the paths two agents both wrote" do
    state =
      hive(
        changes: [
          a_change("c1",
            agent_id: "a1",
            path: "lib/app/repo.ex",
            restorable: true,
            at: @clock + 10
          ),
          a_change("c2",
            agent_id: "a2",
            path: "lib/app/repo.ex",
            restorable: false,
            at: @clock + 20
          ),
          a_change("c3",
            agent_id: "a2",
            path: "lib/app/repo.ex",
            restorable: true,
            at: @clock + 30
          ),
          a_change("c4", agent_id: "a1", path: "docs/plan.md", restorable: true, at: @clock + 40),
          a_change("c5", agent_id: nil, path: "mix.exs", restorable: false, at: @clock + 50)
        ]
      )

    view = View.build(state, 0)
    assert Enum.map(view.changes.files, & &1.id) == ~w(c1 c2 c3 c4 c5)

    assert hd(view.changes.files) == %{
             id: "c1",
             path: "lib/app/repo.ex",
             agent_id: "a1",
             restorable: true,
             at: @clock + 10
           }

    assert view.changes.blast == [%{path: "lib/app/repo.ex", agent_ids: ["a1", "a2"]}]
    assert view.changes.unavailable == nil
    assert View.build(hive(), 0).changes == %{files: [], blast: [], unavailable: nil}
  end

  test "checkpoints keep one change a minute, labelled with the file's name, at most twelve" do
    changes =
      for n <- 0..19,
          do:
            a_change("c#{n}",
              agent_id: "a1",
              path: "lib/app/step_#{n}.ex",
              at: @clock + n * 60_000 + 500
            )

    view = View.build(hive(changes: changes), 0)
    assert length(view.timeline.checkpoints) == 12
    assert hd(view.timeline.checkpoints) == %{at: @clock + 8 * 60_000 + 500, label: "step_8.ex"}
    assert List.last(view.timeline.checkpoints).label == "step_19.ex"

    same_minute =
      for n <- 0..2,
          do: a_change("m#{n}", agent_id: "a1", path: "lib/app/m#{n}.ex", at: @clock + n * 1_000)

    assert View.build(hive(changes: same_minute), 0).timeline.checkpoints ==
             [%{at: @clock, label: "m0.ex"}]

    assert View.build(swarm(), 0).timeline.checkpoints == [
             %{at: @clock - 145_000, label: "repo.ex"}
           ]
  end

  test "the verdict is the newest round the judge reached on the active run" do
    state =
      hive(
        verdicts: [
          %DTO.Verdict{
            id: "v1",
            run_id: "r1",
            round: 1,
            status: :done,
            checks: [%DTO.VerdictCheck{key: "tests", ok: true, note: "green"}],
            summary: "first pass",
            revision: 1
          },
          %DTO.Verdict{
            id: "v2",
            run_id: "r1",
            round: 2,
            status: :running,
            checks: [
              %DTO.VerdictCheck{key: "tests", ok: nil, note: ""},
              %DTO.VerdictCheck{key: "docs", ok: false, note: "still draft"}
            ],
            summary: "",
            revision: 3
          },
          %DTO.Verdict{id: "v3", run_id: "other", round: 9, status: :done, revision: 9}
        ]
      )

    assert View.build(state, 0).verdict == %{
             id: "v2",
             run_id: "r1",
             round: 2,
             status: "running",
             checks: [
               %{key: "tests", ok: nil, note: nil},
               %{key: "docs", ok: false, note: "still draft"}
             ],
             summary: nil
           }

    verdict = View.build(consensus(), 0).verdict
    assert verdict.id == "judge-1" and verdict.round == 1 and length(verdict.checks) == 4
    assert verdict.summary =~ "Two of three proposals"
    assert View.build(swarm(), 0).verdict == nil
  end

  test "transcript keeps the newest 200 items, in sequence, with text capped at 4000" do
    state =
      Enum.reduce(1..250, chat(), fn n, acc ->
        item(acc, "gen-#{String.pad_leading(Integer.to_string(n), 3, "0")}",
          created_sequence: n,
          at: @clock + n * 1_000,
          text: String.duplicate("x", 4_500),
          reasoning: ""
        )
      end)

    view = View.build(state, 0)
    assert length(view.transcript) == 200
    assert hd(view.transcript).id == "gen-051" and List.last(view.transcript).id == "gen-250"
    assert Enum.map(view.transcript, & &1.at) == Enum.map(51..250, &(@clock + &1 * 1_000))
    assert String.length(hd(view.transcript).text) == 4_000
    assert hd(view.transcript).reasoning == nil and hd(view.transcript).kind == "text"
  end

  test "needs list pending interactions across runs with their options" do
    approval = %DTO.PendingInteraction{
      id: "need-b",
      run_id: "other-run",
      node_id: "agent-2",
      conversation_id: "c",
      kind: :approval,
      expected_revision: 7,
      state: :pending,
      approval: %DTO.Approval{tool: "shell", permission: :execute, arguments_preview: "mix test"},
      created_at: 2
    }

    question = %DTO.PendingInteraction{
      id: "need-a",
      run_id: "fixture-run",
      node_id: "node-9",
      conversation_id: "c",
      kind: :question,
      expected_revision: 3,
      state: :pending,
      question: %DTO.Question{
        prompt: "Which?",
        options: [
          %DTO.QuestionOption{id: "x", label: "X"},
          %DTO.QuestionOption{id: "y", label: "Y"}
        ]
      },
      created_at: 1
    }

    resolved = %{approval | id: "need-c", state: :resolved, created_at: 0}
    state = swarm() |> interaction(approval) |> interaction(question) |> interaction(resolved)
    view = View.build(state, 0)

    assert [first, second] = view.needs
    assert first.id == "need-a" and first.kind == "question" and first.title == "Which?"
    assert first.options == [%{id: "x", label: "X"}, %{id: "y", label: "Y"}]
    assert first.command == nil and first.risk == nil and first.agent_id == nil
    assert first.revision == 3 and first.run_id == "fixture-run"
    assert second.id == "need-b" and second.kind == "approval" and second.title == "shell"

    assert second.command == "mix test" and second.risk == "execute" and
             second.agent_id == "agent-2"

    assert second.options == [%{id: "approve", label: "allow"}, %{id: "deny", label: "deny"}]
    assert Enum.all?(view.needs, &(&1.cwd == nil and &1.reason == nil))
    assert hd(view.tabs).needs == 1
  end

  test "focus mirrors the composer, a selected item, an inspected agent, or the run" do
    state = swarm()
    assert View.build(state, 0).focus == %{kind: "composer", id: nil}

    assert View.build(%{state | focus: "main", selection: %{"main" => "002"}}, 0).focus ==
             %{kind: "item", id: "002"}

    assert View.build(%{state | focus: "main", selection: %{}}, 0).focus ==
             %{kind: "run", id: "fixture-run"}

    assert View.build(%{state | focus: "inspector", selection: %{"inspector" => "agent-4"}}, 0).focus ==
             %{kind: "agent", id: "agent-4"}

    assert View.build(%State{focus: "main"}, 0).focus == %{kind: "composer", id: nil}
  end

  test "header takes cost, context tokens and the model from the current run" do
    view = View.build(swarm(), 0)
    assert view.header.cost == 0.184 and view.header.context_tokens == 22_850
    assert view.header.model == "kimi-k2-thinking"

    chat = View.build(chat(), 0)
    assert chat.header.cost == 0.021 and chat.header.context_tokens == 4_032
    assert chat.header.model == "deepseek-v4-pro"

    empty = View.build(%State{}, 0)
    assert empty.header.cost == nil and empty.header.context_tokens == nil
  end

  test "header reads the workspace snapshot, the keymap and the launcher's project" do
    workspace = %DTO.WorkspaceSnapshot{
      mode: :plan,
      chat_model: "chat-model",
      swarm_model: "swarm-model",
      effort: "low",
      swarm_effort: "max"
    }

    chat = put_in(chat().read_model.snapshots[:workspace], workspace)
    swarm = put_in(swarm().read_model.snapshots[:workspace], workspace)
    # the run's own model wins; the snapshot answers for mode, effort and keymap
    assert %{
             model: "deepseek-v4-pro",
             effort: "low",
             mode: "plan",
             keymap: "vim",
             project: "demo"
           } =
             View.build(%{chat | keymap: :vim}, 0, project: "demo").header

    assert %{model: "kimi-k2-thinking", effort: "max"} = View.build(swarm, 0).header

    modelless = put_in(chat().read_model.runs["fixture-run"].model, nil)

    assert %{model: "chat-model"} =
             View.build(put_in(modelless.read_model.snapshots[:workspace], workspace), 0).header

    assert %{model: nil, mode: nil, effort: nil, project: nil} = View.build(hive(), 0).header
    assert View.build(chat(), 0, started_at: 42).session.started_at == 42
  end

  test "notice is the feedback text or a readable label" do
    state = chat()
    assert View.build(state, 0).notice == nil
    assert View.build(%{state | notice: {:command_feedback, "hello"}}, 0).notice == "hello"

    assert View.build(%{state | notice: :detach_requires_confirmation}, 0).notice ==
             "detach requires confirmation"

    assert View.build(%{state | notice: {:input_rejected, :invalid_utf8}}, 0).notice ==
             "input rejected · invalid utf8"
  end

  test "fingerprint ignores the revision and the clock" do
    assert View.fingerprint(View.build(swarm(), 1)) == View.fingerprint(View.build(swarm(), 2))

    refute View.fingerprint(View.build(swarm(), 1)) ==
             View.fingerprint(View.build(%{swarm() | focus: "main"}, 1))
  end

  test "pass70 C1 facts reach the page: the command, where, why, the verdict and the mode" do
    size = %Size{columns: 120, rows: 36}
    state = SwarmCodeCLI.Demo.Conversation.state(:approval, size, %Capabilities{size: size})
    view = View.build(state, state.now)

    assert view.header.approval == "auto"
    assert [need] = view.needs
    assert need.command == "ls -la notes"
    assert need.cwd == "."
    assert need.reason =~ "notes"
    assert need.risk == "safe"

    trouble = SwarmCodeCLI.Demo.Conversation.state(:trouble, size, %Capabilities{size: size})
    assert View.build(trouble, trouble.now).header.approval == "read-only"
  end
end
