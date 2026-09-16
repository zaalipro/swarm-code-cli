defmodule SwarmCodeCLI.UI.DataSource.FakeHiveTest do
  @moduledoc "The fake source emits every hive fact: named agents, tool items, changes, a verdict."
  use ExUnit.Case, async: true
  alias SwarmCode.Protocol.Scope
  alias SwarmCodeCLI.UI.DataSource.{Delivery, Delta, DTO, Fake, Watch}
  alias SwarmCodeCLI.UI.DataSource.Fake.{Script, Source}

  defp fixture,
    do: File.read!(Path.expand("../../../fixtures/fake/three_run_script.json", __DIR__))

  defp source do
    {:ok, script} = Script.decode(fixture())
    start_supervised!({Source, script: script, source_epoch: "epoch-1"})
  end

  defp watch(scope, ref \\ "watch-1"),
    do: %Watch{
      watch_ref: ref,
      slot: :workspace,
      scope: scope,
      generation: 0,
      page_size: 200,
      byte_limit: 1_048_576
    }

  defp conversation(key), do: %Scope{kind: :conversation, id: Script.id(key), generation: 0}

  test "the decoded script carries named agents, run gauges, three changes and a verdict" do
    {:ok, script} = Script.decode(fixture())
    assert {:ok, ^script} = Script.validate(script)

    agents = script.agents |> Map.values() |> Enum.sort_by(& &1.id)
    assert Enum.map(agents, & &1.name) == ~w(lead scout-1 scout-2 builder-4 judge)
    assert Enum.map(agents, & &1.role) == [:lead, :sub, :sub, :worker, :judge]
    assert Enum.all?(agents, &(&1.run_id == Script.id(:a2)))
    assert Enum.all?(agents, &(&1.step != "" and &1.title != "" and &1.tokens_in > 0))
    assert Enum.map(agents, & &1.progress) == [35, 70, 55, 40, 0]
    assert Enum.map(agents, & &1.depth) == [0, 1, 1, 1, 1]
    assert Enum.map(agents, & &1.parent_id) |> tl() |> Enum.uniq() == [Script.id(:lead)]
    assert script.agents[Script.id(:builder_4)].changes_stat == "+42 −7"
    assert script.agents[Script.id(:judge)].state == :queued

    a2 = script.runs[Script.id(:a2)]
    assert {a2.tokens_in, a2.tokens_out, a2.cost_usd} == {18_640, 4_210, 0.184}
    assert {a2.model, a2.agents_total, a2.agents_running} == {"kimi-k2-thinking", 5, 3}
    assert {a2.changes, a2.consensus, a2.needs} == {3, true, 0}
    assert is_integer(a2.started_at) and a2.finished_at == nil
    assert Enum.all?(Map.values(script.runs), &(&1.model != nil and &1.tokens_in > 0))

    changes = script.changes |> Map.values() |> Enum.sort_by(& &1.at)
    assert length(changes) == 3

    assert Enum.map(changes, & &1.path) ==
             ~w(lib/swarm_code/repo.ex test/swarm_code/repo_test.exs docs/architecture.md)

    assert Enum.map(changes, & &1.agent_id) == [
             Script.id(:builder_4),
             Script.id(:builder_4),
             Script.id(:lead)
           ]

    assert Enum.all?(changes, &(&1.run_id == Script.id(:a2)))

    assert [%DTO.Verdict{id: verdict_id, run_id: run_id, checks: checks, round: 1}] =
             Map.values(script.verdicts)

    assert {verdict_id, run_id} == {Script.id(:judge), Script.id(:a2)}
    assert Enum.map(checks, & &1.key) == ~w(tests_pass no_regressions docs_updated style)
    assert Enum.map(checks, & &1.ok) == [true, true, false, nil]

    assert Enum.all?(Map.values(script.transcript), &(&1.at > 0 and &1.kind == :text))
    assert script.transcript["message-A-2"].agent_id == Script.id(:lead)
  end

  test "a conversation workspace snapshot lists its runs' changes newest first and its verdicts" do
    pid = source()
    Source.attach(pid, "client", self())
    assert :ok = Source.watch(pid, "client", watch(conversation(:a)))
    assert_receive {:fake_source, "client", %Delivery{kind: :watch_ready, body: page} = ready}
    assert {:ok, ^ready} = Delivery.validate(ready)

    assert Enum.map(page.changes, & &1.id) == [
             Script.id(:change_3),
             Script.id(:change_2),
             Script.id(:change_1)
           ]

    assert [%DTO.Verdict{id: judge}] = page.verdicts
    assert judge == Script.id(:judge)
    assert Enum.map(page.runs, & &1.id) == [Script.id(:a1), Script.id(:a2)]

    assert :ok = Source.watch(pid, "client", watch(conversation(:b), "watch-2"))
    assert_receive {:fake_source, "client", %Delivery{kind: :watch_ready, body: other}}
    assert {other.changes, other.verdicts} == {[], []}
  end

  test "the first barrier emits tool, thinking and error items, agent steps, a change and a verdict" do
    pid = source()
    Source.attach(pid, "client", self())
    assert :ok = Source.advance(pid, "a1-a2-b1-step-1")
    assert_receive {:fake_source, "client", deltas}
    assert Enum.all?(deltas, &match?({:ok, _}, Delta.validate(&1)))

    items =
      for %Delta{kind: :node_upsert, body: item} <- deltas,
          item.run_id == Script.id(:a2),
          do: item

    assert Enum.map(items, & &1.kind) == [:tool, :tool, :thinking, :tool, :error]
    assert Enum.all?(items, &(&1.agent_id != nil and &1.at > 0))

    [grep, read, thinking, edit, error] = items

    assert %DTO.ToolCall{name: "grep", duration_ms: 400, result_bytes: 3_812, files: []} =
             grep.tool

    assert grep.tool.title =~ "grep"
    assert read.tool.files == ["test/session_test.exs"]
    assert edit.tool.files == ["lib/swarm_code/repo.ex"]
    assert {edit.tool.name, edit.tool.detail} == {"edit_file", "+42 −7"}
    assert thinking.reasoning =~ "refresh path"
    assert thinking.tool == nil
    assert error.state == :failed and error.text =~ "exited with status 1"

    agents = for %Delta{kind: :agent_update, body: agent} <- deltas, do: agent

    assert Enum.map(agents, &{&1.name, &1.step, &1.state}) == [
             {"scout-1", "done", :done},
             {"builder-4", "run mix test", :running}
           ]

    assert Enum.all?(agents, &(&1.revision == 2))

    assert [%Delta{body: %DTO.Change{restorable: true, revision: 2}} = change] =
             Enum.filter(deltas, &(&1.kind == :change_upsert))

    assert {change.entity_id, change.run_id, change.conversation_id} ==
             {Script.id(:change_3), Script.id(:a2), Script.id(:a)}

    assert [%Delta{body: %DTO.Verdict{revision: 2}} = verdict] =
             Enum.filter(deltas, &(&1.kind == :verdict_upsert))

    assert verdict.conversation_id == Script.id(:a)

    a2 = Enum.find(deltas, &(&1.kind == :run_update and &1.entity_id == Script.id(:a2))).body
    assert {a2.state, a2.needs} == {:waiting_question, 1}

    script = Source.snapshot(pid)
    assert {:ok, ^script} = Script.validate(script)
    assert script.changes[Script.id(:change_3)].restorable == true
    assert script.verdicts[Script.id(:judge)].revision == 2
    assert Map.has_key?(script.transcript, "tool-A-2-1")

    # Answering the question drops the run's need count back to zero.
    q = script.interactions[Script.id(:q1)]

    request = %SwarmCodeCLI.UI.DataSource.Request{
      request_id: "request-1",
      kind: {:answer_question, q.run_id, q.node_id, q.id, q.expected_revision, ["option-2"]},
      origin: {:interaction, q.id, q.expected_revision},
      scope: %Scope{kind: :global, id: nil, generation: 0},
      generation: 0,
      deadline: Script.clock_ms() + 1000,
      expected_response: :outcome
    }

    assert :ok = Source.request(pid, "client", request)
    assert Source.snapshot(pid).runs[Script.id(:a2)].needs == 0

    # Replaying the barrier never re-emits the hive facts.
    assert :ok = Source.advance(pid, "a1-a2-b1-step-1")
    assert map_size(Source.snapshot(pid).transcript) == map_size(script.transcript)
  end

  test "the client adapter delivers change and verdict deltas to a conversation workspace watch" do
    pid = source()
    client = start_supervised!({Fake, source: pid, source_epoch: "epoch-1", client_id: "client"})
    assert {:ok, "binding"} = Fake.bind_owner(client, self(), "binding")
    assert :ok = Fake.watch(client, watch(conversation(:a)))
    assert_receive {:swarm_code_ui_data, "epoch-1", %Delivery{kind: :watch_ready, body: page}}
    assert length(page.changes) == 3 and length(page.verdicts) == 1

    assert :ok = Source.advance(pid, "a1-a2-b1-step-1")
    kinds = collect(MapSet.new(), 40)
    assert MapSet.subset?(MapSet.new([:change_upsert, :verdict_upsert, :node_upsert]), kinds)
  end

  defp collect(kinds, 0), do: kinds

  defp collect(kinds, remaining) do
    receive do
      {:swarm_code_ui_data, _, %Delivery{kind: :delta, body: %Delta{kind: kind}}} ->
        collect(MapSet.put(kinds, kind), remaining - 1)
    after
      500 -> kinds
    end
  end
end
