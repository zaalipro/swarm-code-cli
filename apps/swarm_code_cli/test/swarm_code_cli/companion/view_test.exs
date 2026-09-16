defmodule SwarmCodeCLI.Companion.ViewTest do
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.Companion.View
  alias SwarmCodeCLI.UI.{Capabilities, Fixtures, Size, State}
  alias SwarmCodeCLI.UI.DataSource.DTO

  @keys ~w(revision session header tabs run agents transcript needs changes timeline verdict artifacts focus notice)a
  @size %Size{columns: 120, rows: 40}
  @caps %Capabilities{size: @size, color_mode: :truecolor}

  defp swarm, do: Fixtures.representative(:swarm, @size, @caps)
  defp chat, do: Fixtures.representative(:chat, @size, @caps)

  defp item(state, id, attrs) do
    base = state.read_model.transcript["002"]
    put_in(state.read_model.transcript[id], struct!(base, Keyword.put(attrs, :id, id)))
  end

  defp interaction(state, %DTO.PendingInteraction{} = need),
    do: put_in(state.read_model.interactions[need.id], need)

  test "every contract key is present for fixtures and for an empty state" do
    for state <- [swarm(), chat(), %State{}] do
      view = View.build(state, 1_000)
      assert Enum.sort(Map.keys(view)) == Enum.sort(@keys)
      assert Enum.sort(Map.keys(view.session)) == [:id, :now, :started_at]

      assert Enum.sort(Map.keys(view.header)) ==
               ~w(approval context_tokens cost effort keymap mode model project)a

      assert Enum.sort(Map.keys(view.run)) ==
               ~w(edges finished_at id kind started_at state title)a

      assert view.changes == %{files: [], unavailable: "not reported by the daemon yet"}
      assert view.timeline.checkpoints == []
      assert view.verdict == nil and view.artifacts == []
      assert Enum.sort(Map.keys(view.focus)) == [:id, :kind]
      assert view.session.now == 1_000
    end
  end

  test "encodes to JSON with string keys and words for every enum" do
    decoded = swarm() |> View.build(5) |> Jason.encode!() |> Jason.decode!()
    assert decoded["session"]["id"] == "fixture-"
    assert decoded["run"]["state"] == "streaming" and decoded["run"]["kind"] == "swarm"
    assert Enum.map(decoded["agents"], & &1["state"]) |> Enum.all?(&is_binary/1)
    assert decoded["header"]["keymap"] == "default"
  end

  test "tabs mirror the tab row with the active run marked and counted" do
    assert [tab] = View.build(swarm(), 0).tabs
    assert tab.id == "fixture-run" and tab.active and tab.agents == 5 and tab.needs == 0
    assert tab.state == "streaming" and tab.kind == "swarm" and tab.title =~ "Swarm"
    assert tab.started_at == nil and tab.finished_at == nil
  end

  test "agents come from the active run; without an identifiable lead all are workers" do
    view = View.build(swarm(), 0)
    assert Enum.map(view.agents, & &1.id) == ~w(agent-1 agent-2 agent-3 agent-4 agent-5)
    assert Enum.all?(view.agents, &(&1.role == "worker" and &1.parent_id == nil))
    assert Enum.map(view.agents, & &1.hue) == [0, 1, 2, 3, 4]
    assert Enum.map(view.agents, & &1.name) == ~w(agent-1 agent-2 agent-3 agent-4 agent-5)
    assert Enum.map(view.agents, & &1.waiting) == [false, false, false, false, true]
    assert Enum.map(view.agents, & &1.progress) == [0.5, 0.5, 0.5, 0.5, 0.5]
    assert view.run.edges == []
    assert View.build(chat(), 0).agents == []
  end

  test "the agent that authored the earliest non-user item leads, centres and spawns the rest" do
    state = item(swarm(), "002", node_id: "agent-3", state: :waiting_approval)
    view = View.build(state, 0)

    assert [lead | rest] = view.agents
    assert lead.id == "agent-3" and lead.role == "lead" and lead.name == "lead"
    assert lead.hue == 0 and lead.parent_id == nil and not lead.waiting
    assert Enum.map(rest, & &1.id) == ~w(agent-1 agent-2 agent-4 agent-5)
    assert Enum.all?(rest, &(&1.parent_id == "agent-3" and &1.role == "worker"))
    assert Enum.map(rest, & &1.waiting) == [false, false, false, true]
    assert Enum.map(rest, & &1.hue) == [1, 2, 3, 4]

    assert view.run.edges ==
             for(
               id <- ~w(agent-1 agent-2 agent-4 agent-5),
               do: %{from: "agent-3", to: id, kind: "spawn"}
             )

    assert [%{id: "001", agent_id: nil, role: "user"}, %{id: "002", agent_id: "agent-3"}] =
             view.transcript

    assert view.timeline.events == [
             %{at: 0, kind: "you", agent_id: nil},
             %{at: 0, kind: "wait", agent_id: "agent-3"}
           ]
  end

  test "timeline tells the lead from other agents" do
    state =
      swarm()
      |> item("002", node_id: "agent-1", created_sequence: 1, state: :done)
      |> item("003", node_id: "agent-2", created_sequence: 2, state: :streaming)
      |> item("004", node_id: nil, created_sequence: 3, role: :system, state: :done)

    assert Enum.map(View.build(state, 0).timeline.events, & &1.kind) == ~w(you lead agent lead)
  end

  test "transcript keeps the newest 200 items, in sequence, with text capped at 4000" do
    state =
      Enum.reduce(1..250, chat(), fn n, acc ->
        item(acc, "gen-#{String.pad_leading(Integer.to_string(n), 3, "0")}",
          created_sequence: n,
          text: String.duplicate("x", 4_500),
          reasoning: ""
        )
      end)

    view = View.build(state, 0)
    assert length(view.transcript) == 200
    assert hd(view.transcript).id == "gen-051" and List.last(view.transcript).id == "gen-250"
    assert Enum.map(view.transcript, & &1.at) == Enum.to_list(51..250)
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

    assert %{model: "chat-model", effort: "low", mode: "plan", keymap: "vim", project: "demo"} =
             View.build(%{chat | keymap: :vim}, 0, project: "demo").header

    assert %{model: "swarm-model", effort: "max"} = View.build(swarm, 0).header
    assert %{model: nil, mode: nil, effort: nil, project: nil} = View.build(chat(), 0).header
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
end
