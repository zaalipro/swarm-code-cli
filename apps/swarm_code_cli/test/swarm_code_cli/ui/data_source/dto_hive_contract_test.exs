defmodule SwarmCodeCLI.UI.DataSource.DTOHiveContractTest do
  @moduledoc "Wave 1 contract: every new field decodes, validates its bounds and defaults."
  use ExUnit.Case, async: true
  import SwarmCodeCLI.TestSupport.HiveWire
  alias SwarmCodeCLI.UI.DataSource.DTO

  @run "33333333-3333-4333-8333-333333333333"
  @agent "44444444-4444-4444-8444-444444444444"

  describe "TranscriptItem" do
    test "decodes kind, tool, agent, tokens and time" do
      assert {:ok, item} = DTO.TranscriptItem.decode(transcript_item())
      assert item.kind == :tool
      assert item.agent_id == @agent
      assert {item.tokens_in, item.tokens_out, item.at} == {812, 64, 1_788_436_730_000}

      assert %DTO.ToolCall{name: "grep", duration_ms: 400, result_bytes: 3_812} = item.tool
      assert item.tool.files == ["lib/swarm_code/repo.ex"]
      assert item.tool.status == :done
      assert {:ok, ^item} = DTO.TranscriptItem.validate(item)
    end

    test "an older daemon that omits the new keys still decodes to the defaults" do
      wire = Map.drop(transcript_item(), ~w(kind tool agent_id tokens_in tokens_out at))
      assert {:ok, item} = DTO.TranscriptItem.decode(wire)
      assert item.kind == :text
      assert item.tool == nil
      assert item.agent_id == nil
      assert {item.tokens_in, item.tokens_out, item.at} == {0, 0, 0}
    end

    test "a tool call omitting its own optional keys decodes to defaults" do
      tool = Map.take(tool_call(), ["name"])
      assert {:ok, item} = DTO.TranscriptItem.decode(Map.put(transcript_item(), "tool", tool))

      assert %DTO.ToolCall{name: "grep", title: "", detail: "", files: [], status: :done} =
               item.tool

      assert item.tool.duration_ms == nil
    end

    test "rejects unknown kinds, unbounded tool strings and negative counters" do
      base = transcript_item()

      for invalid <- [
            Map.put(base, "kind", "invented"),
            Map.put(base, "kind", nil),
            Map.put(base, "agent_id", ""),
            Map.put(base, "tokens_in", -1),
            Map.put(base, "tokens_out", 1.5),
            Map.put(base, "at", -5),
            put_in(base["tool"]["title"], String.duplicate("t", 201)),
            put_in(base["tool"]["detail"], String.duplicate("d", 201)),
            put_in(base["tool"]["name"], String.duplicate("n", 201)),
            put_in(base["tool"]["files"], [String.duplicate("p", 1025)]),
            put_in(base["tool"]["files"], [nil]),
            put_in(base["tool"]["status"], "invented"),
            put_in(base["tool"]["result_bytes"], -1),
            put_in(base["tool"]["extra"], true),
            Map.put(base, "tool", "grep")
          ] do
        assert {:error, :invalid_dto} = DTO.TranscriptItem.decode(invalid)
      end

      assert {:ok, _} =
               DTO.TranscriptItem.decode(
                 put_in(base["tool"]["title"], String.duplicate("t", 200))
               )

      assert {:ok, _} =
               DTO.TranscriptItem.decode(
                 put_in(base["tool"]["files"], [String.duplicate("p", 1024)])
               )
    end

    test "every kind of the closed enum decodes" do
      for kind <- ~w(text thinking tool error system) do
        assert {:ok, %{kind: atom}} =
                 DTO.TranscriptItem.decode(Map.put(transcript_item(), "kind", kind))

        assert Atom.to_string(atom) == kind
      end
    end
  end

  describe "AgentSummary" do
    test "decodes name, role, step, gauges, lineage and error" do
      assert {:ok, agent} = DTO.AgentSummary.decode(agent_summary())
      assert {agent.name, agent.role, agent.title} == {"builder-4", :worker, "Harden refresh"}
      assert {agent.step, agent.progress} == {"edit lib/swarm_code/repo.ex", 40}
      assert {agent.tokens_in, agent.tokens_out, agent.cost_usd} == {5_340, 1_320, 0.058}
      assert {agent.started_at, agent.finished_at} == {1_788_436_690_000, nil}
      assert {agent.parent_id, agent.depth} == {@agent, 1}
      assert {agent.changes_stat, agent.error} == {"+42 −7", nil}
      assert {:ok, ^agent} = DTO.AgentSummary.validate(agent)
    end

    test "an older daemon that omits every new key decodes to the defaults" do
      wire = Map.take(agent_summary(), legacy_agent_keys())
      assert {:ok, agent} = DTO.AgentSummary.decode(wire)

      assert %DTO.AgentSummary{
               name: "",
               role: :unknown,
               title: "",
               step: "",
               progress: 0,
               tokens_in: 0,
               tokens_out: 0,
               cost_usd: nil,
               started_at: nil,
               finished_at: nil,
               parent_id: nil,
               depth: 0,
               changes_stat: nil,
               error: nil
             } = agent
    end

    test "cost may arrive as a whole number and becomes a float" do
      assert {:ok, %{cost_usd: cost}} =
               DTO.AgentSummary.decode(Map.put(agent_summary(), "cost_usd", 0))

      assert cost === 0.0

      assert {:ok, %{cost_usd: nil}} =
               DTO.AgentSummary.decode(Map.put(agent_summary(), "cost_usd", nil))
    end

    test "every role of the closed enum decodes" do
      for role <- ~w(lead sub worker assistant judge unknown) do
        assert {:ok, %{role: atom}} =
                 DTO.AgentSummary.decode(Map.put(agent_summary(), "role", role))

        assert Atom.to_string(atom) == role
      end
    end

    test "rejects out-of-range gauges, unknown roles and unbounded text" do
      base = agent_summary()

      for invalid <- [
            Map.put(base, "role", "manager"),
            Map.put(base, "progress", 101),
            Map.put(base, "progress", -1),
            Map.put(base, "progress", nil),
            Map.put(base, "cost_usd", -0.5),
            Map.put(base, "cost_usd", "free"),
            Map.put(base, "name", String.duplicate("n", 201)),
            Map.put(base, "title", String.duplicate("t", 201)),
            Map.put(base, "step", String.duplicate("s", 201)),
            Map.put(base, "changes_stat", String.duplicate("c", 201)),
            Map.put(base, "error", String.duplicate("e", 201)),
            Map.put(base, "parent_id", ""),
            Map.put(base, "depth", -1),
            Map.put(base, "started_at", "yesterday"),
            Map.put(base, "tokens_in", nil)
          ] do
        assert {:error, :invalid_dto} = DTO.AgentSummary.decode(invalid)
      end

      assert {:ok, _} =
               DTO.AgentSummary.decode(Map.put(base, "error", String.duplicate("e", 200)))
    end
  end

  describe "RunSummary" do
    test "decodes tokens, cost, model, agent counts, needs, changes, times and consensus" do
      assert {:ok, run} = DTO.RunSummary.decode(run_summary())
      assert {run.tokens_in, run.tokens_out, run.cost_usd} == {18_640, 4_210, 0.184}
      assert run.model == "kimi-k2-thinking"
      assert {run.agents_total, run.agents_running, run.needs, run.changes} == {5, 3, 1, 3}
      assert {run.started_at, run.finished_at} == {1_788_436_680_000, nil}
      assert {run.consensus, run.error} == {true, nil}
      assert {:ok, ^run} = DTO.RunSummary.validate(run)
    end

    test "an older daemon that omits every new key decodes to the defaults" do
      assert {:ok, run} = DTO.RunSummary.decode(Map.take(run_summary(), legacy_run_keys()))

      assert %DTO.RunSummary{
               tokens_in: 0,
               tokens_out: 0,
               cost_usd: nil,
               model: nil,
               agents_total: 0,
               agents_running: 0,
               needs: 0,
               changes: 0,
               started_at: nil,
               finished_at: nil,
               consensus: false,
               error: nil
             } = run
    end

    test "rejects unbounded model and error text, non-boolean consensus and negative counts" do
      base = run_summary()

      for invalid <- [
            Map.put(base, "model", String.duplicate("m", 201)),
            Map.put(base, "error", String.duplicate("e", 201)),
            Map.put(base, "consensus", "yes"),
            Map.put(base, "consensus", nil),
            Map.put(base, "needs", -1),
            Map.put(base, "changes", "three"),
            Map.put(base, "agents_running", nil),
            Map.put(base, "cost_usd", -1),
            Map.put(base, "finished_at", -1)
          ] do
        assert {:error, :invalid_dto} = DTO.RunSummary.decode(invalid)
      end

      assert {:ok, %{error: nil}} = DTO.RunSummary.decode(Map.put(base, "error", nil))
      assert {:ok, %{model: nil}} = DTO.RunSummary.decode(Map.put(base, "model", nil))
    end
  end

  describe "Change" do
    test "decodes and validates one checkpoint" do
      assert {:ok, change} = DTO.Change.decode(change())
      assert %DTO.Change{run_id: @run, agent_id: @agent, restorable: true, revision: 2} = change
      assert change.path == "lib/swarm_code/repo.ex"
      assert change.at == 1_788_436_760_000
      assert {:ok, ^change} = DTO.Change.validate(change)
    end

    test "agent, restorable and time have wire defaults; identity and path do not" do
      assert {:ok, change} = DTO.Change.decode(Map.drop(change(), ~w(agent_id restorable at)))
      assert {change.agent_id, change.restorable, change.at} == {nil, false, 0}

      for key <- ~w(id run_id path revision) do
        assert {:error, :invalid_dto} = DTO.Change.decode(Map.delete(change(), key))
      end
    end

    test "bounds the path at 1024 bytes and closes the shape" do
      assert {:ok, _} = DTO.Change.decode(Map.put(change(), "path", String.duplicate("p", 1024)))

      for invalid <- [
            Map.put(change(), "path", String.duplicate("p", 1025)),
            Map.put(change(), "path", nil),
            Map.put(change(), "restorable", "true"),
            Map.put(change(), "agent_id", ""),
            Map.put(change(), "at", -1),
            Map.put(change(), "extra", 1)
          ] do
        assert {:error, :invalid_dto} = DTO.Change.decode(invalid)
      end
    end
  end

  describe "Verdict" do
    test "decodes the judge's checks with a tri-state ok" do
      assert {:ok, verdict} = DTO.Verdict.decode(verdict())
      assert %DTO.Verdict{run_id: @run, round: 1, status: :done, revision: 3} = verdict

      assert Enum.map(verdict.checks, & &1.key) ==
               ~w(tests_pass no_regressions docs_updated style)

      assert Enum.map(verdict.checks, & &1.ok) == [true, true, false, nil]
      assert Enum.map(verdict.checks, & &1.note) |> hd() == "142 tests, 0 failures"
      assert verdict.summary =~ "meet the bar"
      assert {:ok, ^verdict} = DTO.Verdict.validate(verdict)
    end

    test "round, status, checks and summary have wire defaults" do
      assert {:ok, verdict} =
               DTO.Verdict.decode(Map.drop(verdict(), ~w(round status checks summary)))

      assert %DTO.Verdict{round: 0, status: :done, checks: [], summary: ""} = verdict

      assert {:ok, %{checks: [%DTO.VerdictCheck{key: "style", ok: nil, note: ""}]}} =
               DTO.Verdict.decode(Map.put(verdict(), "checks", [%{"key" => "style"}]))
    end

    test "bounds summary at 400, key at 200 and note at 400 bytes" do
      assert {:ok, _} =
               DTO.Verdict.decode(Map.put(verdict(), "summary", String.duplicate("s", 400)))

      for invalid <- [
            Map.put(verdict(), "summary", String.duplicate("s", 401)),
            Map.put(verdict(), "status", "invented"),
            Map.put(verdict(), "round", -1),
            put_in(verdict(), ["checks", Access.at(0), "key"], String.duplicate("k", 201)),
            put_in(verdict(), ["checks", Access.at(0), "note"], String.duplicate("n", 401)),
            put_in(verdict(), ["checks", Access.at(0), "ok"], "yes"),
            Map.put(verdict(), "checks", [%{"ok" => true}]),
            Map.put(verdict(), "checks", nil),
            Map.put(verdict(), "extra", true)
          ] do
        assert {:error, :invalid_dto} = DTO.Verdict.decode(invalid)
      end
    end
  end

  describe "WorkspaceSnapshot" do
    test "carries changes and verdicts and defaults both when omitted" do
      assert {:ok, page} = DTO.WorkspaceSnapshot.decode(workspace())
      assert [%DTO.Change{id: "change-1"}] = page.changes
      assert [%DTO.Verdict{id: "judge-1", checks: [_, _, _, _]}] = page.verdicts

      assert {:ok, %{changes: [], verdicts: []}} =
               DTO.WorkspaceSnapshot.decode(Map.drop(workspace(), ~w(changes verdicts)))

      assert {:error, :invalid_dto} =
               DTO.WorkspaceSnapshot.decode(Map.put(workspace(), "changes", [%{"id" => "x"}]))

      assert {:error, :invalid_dto} =
               DTO.WorkspaceSnapshot.decode(Map.put(workspace(), "verdicts", nil))
    end
  end
end
