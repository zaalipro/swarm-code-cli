defmodule SwarmCode.Daemon.Service.WireContractTest do
  @moduledoc """
  The daemon side of the north-star wire contract (docs/superpowers/plans/
  2026-09-16-north-star-build.md): one fixture run with a lead, two workers, a
  judge, three ops and two checkpoints, and the exact shapes the persisted
  backend emits for it — transcript items, agents, runs, changes, verdicts —
  and the deltas it publishes when they move.
  """
  use ExUnit.Case, async: false
  alias SwarmCode.Daemon.Service.PersistedBackend, as: Backend
  alias SwarmCode.Domain.{Cache, Conversations, Engine, Projects, Repo}
  alias SwarmCode.Domain.Checkpoints.Checkpoint
  alias SwarmCode.Protocol.{Scope, ServiceRequest}
  alias SwarmCodeCLI.UI.DataSource.{Delta, DTO}

  setup_all do
    path = Path.join(System.tmp_dir!(), "wire-contract-#{System.unique_integer([:positive])}")
    root = Path.join(path, "project")
    File.mkdir_p!(root)
    System.cmd("git", ["init", "-q", root])
    prior = Application.get_env(:swarm_code_daemon, :domain_config_dir)
    Application.put_env(:swarm_code_daemon, :domain_config_dir, Path.join(path, "config"))

    on_exit(fn ->
      Cache.clear()

      if prior,
        do: Application.put_env(:swarm_code_daemon, :domain_config_dir, prior),
        else: Application.delete_env(:swarm_code_daemon, :domain_config_dir)

      File.rm_rf!(path)
    end)

    start_supervised!(
      {Repo,
       database: Path.join(path, "fixture.db"),
       domain_fixture: true,
       pool_size: 1,
       journal_mode: :wal,
       log: false}
    )

    Ecto.Migrator.run(
      Repo,
      Application.app_dir(:swarm_code_daemon, "priv/domain_repo/migrations"),
      :up,
      all: true,
      log: false
    )

    {:ok, project} = Projects.create(%{name: "Wire", root_path: root})
    %{project: project, root: root}
  end

  setup c do
    Cache.clear()
    {:ok, conv} = Conversations.create(c.project.id)
    fixture = fixture(c, conv)

    opts = [
      mode: :persisted,
      repo: Repo,
      project_root: c.root,
      project_id: c.project.id,
      conversation_id: conv.id,
      source_epoch: Ecto.UUID.generate()
    ]

    backend = start_supervised!({Backend, opts})
    on_exit(fn -> Engine.stop_all(conv.id) end)

    Map.merge(fixture, %{
      backend: backend,
      conversation: conv,
      scope: %Scope{kind: :conversation, id: conv.id, generation: 1}
    })
  end

  test "run summaries carry tokens, cost, model, agent counts, changes and timings", c do
    assert {:ok, %{"value" => workspace}} = query(c.backend, c.scope, "workspace")
    assert {:ok, _} = DTO.WorkspaceSnapshot.decode(workspace)
    assert [run] = workspace["runs"]
    assert run["id"] == c.run.id
    assert run["tokens_in"] == 1200
    assert run["tokens_out"] == 300
    assert run["cost_usd"] == 0.0421
    assert run["model"] == "fixture-model"
    assert run["agents_total"] == 4
    # The lead and one worker are running; the other worker and the judge are done.
    assert run["agents_running"] == 2
    assert run["needs"] == 0
    assert run["changes"] == 2
    assert run["started_at"] == DateTime.to_unix(c.t0, :millisecond)
    assert run["finished_at"] == nil
    assert run["consensus"] == true
    # A worker failed, but the run is still going: that is the agent's error.
    assert run["error"] == nil
    assert run["kind"] == "consensus"

    # Once the run itself fails without a root error, it borrows the worker's.
    {:ok, _} = Conversations.update_run(c.run, %{status: "failed"})
    assert {:ok, %{"value" => %{"runs" => [failed]}}} = query(c.backend, c.scope, "workspace")
    assert failed["state"] == "failed"
    assert failed["error"] == String.duplicate("e", 200)
    assert failed["agents_running"] == 2
  end

  test "agent summaries carry name, role, step, gauges, lineage and errors", c do
    assert {:ok, %{"value" => detail}} = query(c.backend, run_scope(c), "inspector")
    assert {:ok, _} = DTO.RunDetailSnapshot.decode(detail)
    agents = Map.new(detail["agents"], &{&1["id"], &1})
    assert map_size(agents) == 4

    lead = agents[c.lead.id]
    assert lead["name"] == "Lead"
    assert lead["role"] == "lead"
    assert lead["title"] == "Planning the build"
    # Its only op is finished, so the step is the status word.
    assert lead["step"] == "running"
    assert lead["state"] == "running"
    assert lead["progress"] == 40
    assert lead["tokens_in"] == 800
    assert lead["tokens_out"] == 200
    assert lead["cost_usd"] == 0.03
    assert lead["started_at"] == DateTime.to_unix(c.t0, :millisecond)
    assert lead["finished_at"] == nil
    assert lead["parent_id"] == nil
    assert lead["depth"] == 0
    assert lead["changes_stat"] == nil
    assert lead["error"] == nil
    assert lead["allowed_actions"] == []
    assert lead["launched_by_superseded"] == false
    assert is_integer(lead["revision"])

    worker = agents[c.worker.id]
    assert worker["name"] == "integrations-ops"
    assert worker["role"] == "worker"
    # The newest open child op names the step.
    assert worker["step"] == "edit lib/app.ex"
    assert worker["progress"] == 60
    assert worker["parent_id"] == c.lead.id
    assert worker["depth"] == 1
    assert worker["changes_stat"] == "+12 −3"

    other = agents[c.other.id]
    assert other["role"] == "worker"
    assert other["state"] == "failed"
    assert other["step"] == "failed"
    assert other["title"] == ""
    assert other["progress"] == 0
    assert is_integer(other["finished_at"])
    assert String.length(other["error"]) == 200

    judge = agents[c.judge.id]
    assert judge["role"] == "judge"
    assert judge["name"] == "Judge · round 2"
    assert judge["state"] == "done"

    # A worker's failure inside a running run is not the run's error.
    assert detail["run"]["error"] == nil
  end

  test "transcript items carry kind, tool facts, agent, tokens and time", c do
    assert {:ok, %{"value" => workspace}} = query(c.backend, c.scope, "workspace")
    items = Map.new(workspace["transcript"]["items"], &{&1["id"], &1})

    user = items[c.user_message.id]
    assert user["kind"] == "text"
    assert user["tool"] == nil
    assert user["agent_id"] == c.lead.id
    assert user["tokens_in"] == 0
    assert user["tokens_out"] == 0
    assert user["at"] == DateTime.to_unix(c.user_message.inserted_at, :millisecond)

    answer = items[c.assistant_message.id]
    assert answer["kind"] == "text"
    assert answer["tokens_in"] == 900
    assert answer["tokens_out"] == 250

    failure = items[c.error_message.id]
    assert failure["kind"] == "error"
    assert failure["role"] == "system"

    thinking = items[c.llm.id]
    assert thinking["kind"] == "thinking"
    assert thinking["tool"] == nil
    assert thinking["agent_id"] == c.lead.id
    assert thinking["tokens_in"] == 100
    assert thinking["tokens_out"] == 50
    assert thinking["at"] == DateTime.to_unix(c.t1, :millisecond)

    grep = items[c.grep.id]
    assert grep["kind"] == "tool"
    assert grep["agent_id"] == c.worker.id
    assert grep["role"] == "tool"

    assert grep["tool"] == %{
             "name" => "grep",
             "title" => "grep Bootstrap|Repo",
             "detail" => "3 hits",
             "status" => "done",
             "started_at" => DateTime.to_unix(c.t1, :millisecond),
             "finished_at" => DateTime.to_unix(c.t1, :millisecond) + 400,
             "duration_ms" => 400,
             "result_bytes" => byte_size("lib/a.ex:1\nlib/b.ex:2\nlib/c.ex:3"),
             "files" => []
           }

    edit = items[c.edit.id]
    assert edit["kind"] == "tool"
    assert edit["tool"]["name"] == "edit_file"
    assert edit["tool"]["status"] == "running"
    assert edit["tool"]["files"] == ["lib/app.ex"]
    assert edit["tool"]["finished_at"] == nil
    assert edit["tool"]["duration_ms"] == nil
    assert String.length(edit["tool"]["detail"]) == 200

    # An agent node in the transcript is text spoken by that agent.
    assert items[c.other.id]["kind"] == "text"
    assert items[c.other.id]["agent_id"] == c.other.id
  end

  test "an agent node speaks what it produced, never its own name", c do
    assert {:ok, %{"value" => workspace}} = query(c.backend, c.scope, "workspace")
    items = Map.new(workspace["transcript"]["items"], &{&1["id"], &1})

    # The run's root agent is spoken for by its answer the moment the answer
    # exists, so the lead node is not an item of its own here.
    refute Map.has_key?(items, c.lead.id)

    # A worker's result and error follow each other; the name stays out.
    assert items[c.other.id]["text"] == "Docs findings\n" <> String.duplicate("e", 300)
    refute String.starts_with?(items[c.other.id]["text"], "docs-writer")
  end

  test "workspace metadata names the project and lists every provider's models", c do
    {:ok, provider} =
      SwarmCode.Domain.Providers.create(%{
        name: "Fixture gateway",
        kind: "openai_compatible",
        base_url: "http://127.0.0.1:1/v1",
        api_key: "unused",
        models: ["fixture-model", "fixture-model-mini"]
      })

    on_exit(fn -> SwarmCode.Domain.Providers.delete(provider) end)

    assert {:ok, %{"value" => workspace}} = query(c.backend, c.scope, "workspace")
    assert workspace["project"] == "Wire"

    assert %{
             "provider_id" => provider.id,
             "provider" => "Fixture gateway",
             "model" => "fixture-model"
           } in workspace["models"]

    assert {:ok, decoded} = DTO.WorkspaceSnapshot.decode(workspace)
    assert decoded.project == "Wire"
    assert Enum.any?(decoded.models, &(&1.model == "fixture-model-mini"))
  end

  test "refresh publishes an agent_update for each agent that moved", c do
    watch = %ServiceRequest{
      operation: :watch,
      timeout_ms: 5000,
      params: %{
        "watch_ref" => "agents",
        "slot" => "workspace",
        "page_size" => 50,
        "byte_limit" => 1_048_576
      }
    }

    assert {:watch, 0, _, "workspace_snapshot", _} =
             GenServer.call(c.backend, {:service_watch, self(), "watch", c.scope, watch})

    send(c.backend, {:service_ready, self(), "agents"})

    {:ok, worker} = Conversations.update_node(c.worker, %{progress: 90, status: "done"})
    SwarmCode.Domain.Engine.Events.broadcast(c.conversation.id, {:run_updated, c.run})
    deltas = collect(c.backend, "agents", 40)
    for delta <- deltas, do: assert({:ok, _} = Delta.decode(delta))

    updates = Enum.filter(deltas, &(&1["kind"] == "agent_update"))

    assert %{"body" => body, "run_id" => run_id, "revision" => revision} =
             Enum.find(updates, &(&1["entity_id"] == worker.id))

    assert run_id == c.run.id
    assert body["progress"] == 90
    assert body["state"] == "done"
    assert body["name"] == "integrations-ops"
    assert revision == body["revision"]

    # The lead did not move, so nothing is said about it.
    refute Enum.any?(updates, &(&1["entity_id"] == c.lead.id))
  end

  test "workspace snapshots carry the agents of their runs", c do
    assert {:ok, %{"value" => workspace}} = query(c.backend, c.scope, "workspace")
    assert [_ | _] = agents = workspace["agents"]

    for agent <- agents do
      assert is_binary(agent["id"])
      assert agent["run_id"] == c.run.id
      assert is_binary(agent["name"])
    end

    assert Enum.any?(agents, &(&1["id"] == c.worker.id))
  end

  test "workspace snapshots list changes and verdicts, newest first", c do
    assert {:ok, %{"value" => workspace}} = query(c.backend, c.scope, "workspace")
    assert [worktree_change, project_change] = workspace["changes"]

    assert worktree_change == %{
             "id" => c.worktree_checkpoint.id,
             "run_id" => c.run.id,
             "agent_id" => c.worker.id,
             "path" => "lib/x.ex",
             "restorable" => true,
             "at" => DateTime.to_unix(c.worktree_checkpoint.inserted_at, :millisecond),
             "revision" => DateTime.to_unix(c.worktree_checkpoint.inserted_at, :microsecond)
           }

    assert project_change["id"] == c.project_checkpoint.id
    assert project_change["agent_id"] == c.other.id
    assert project_change["path"] == "README.md"
    assert project_change["restorable"] == false

    assert [verdict] = workspace["verdicts"]

    assert verdict == %{
             "id" => c.judge.id,
             "run_id" => c.run.id,
             "round" => 2,
             "status" => "done",
             "checks" => [
               %{"key" => "tests", "ok" => true, "note" => "42 green"},
               %{"key" => "scope", "ok" => false, "note" => "one file out of scope"},
               %{"key" => "codebase", "ok" => nil, "note" => ""}
             ],
             "summary" => "Plan is sound",
             "revision" => DateTime.to_unix(c.judge.updated_at, :microsecond)
           }

    assert {:ok, decoded} = DTO.WorkspaceSnapshot.decode(workspace)
    assert [%DTO.Change{path: "lib/x.ex"}, %DTO.Change{path: "README.md"}] = decoded.changes
    assert [%DTO.Verdict{round: 2, status: :done}] = decoded.verdicts
  end

  test "refresh publishes change and verdict deltas with the body's revision", c do
    watch = %ServiceRequest{
      operation: :watch,
      timeout_ms: 5000,
      params: %{
        "watch_ref" => "entities",
        "slot" => "workspace",
        "page_size" => 50,
        "byte_limit" => 1_048_576
      }
    }

    assert {:watch, 0, _, "workspace_snapshot", _} =
             GenServer.call(c.backend, {:service_watch, self(), "watch", c.scope, watch})

    send(c.backend, {:service_ready, self(), "entities"})

    # A third checkpoint arrives, one is deleted, and the judge revises.
    added = checkpoint!(c, c.edit.id, Path.join(c.root, "lib/new.ex"), true)
    Repo.delete!(c.project_checkpoint)

    {:ok, judge} =
      Conversations.update_node(c.judge, %{
        result:
          Jason.encode!(%{
            "verdict" => "revise",
            "summary" => "Needs a test",
            "checks" => [%{"key" => "tests", "status" => "fail", "note" => "none"}]
          })
      })

    SwarmCode.Domain.Engine.Events.broadcast(c.conversation.id, {:run_updated, c.run})
    deltas = collect(c.backend, "entities", 40)
    for delta <- deltas, do: assert({:ok, _} = Delta.decode(delta))

    assert %{"body" => body, "run_id" => run_id, "revision" => revision} =
             Enum.find(deltas, &(&1["kind"] == "change_upsert" and &1["entity_id"] == added.id))

    assert run_id == c.run.id
    assert body["path"] == "lib/new.ex"
    assert body["agent_id"] == c.worker.id
    assert revision == body["revision"]

    assert %{"body" => nil, "run_id" => removed_run} =
             Enum.find(
               deltas,
               &(&1["kind"] == "change_remove" and &1["entity_id"] == c.project_checkpoint.id)
             )

    assert removed_run == c.run.id

    assert %{"body" => verdict, "revision" => verdict_revision} =
             Enum.find(deltas, &(&1["kind"] == "verdict_upsert" and &1["entity_id"] == judge.id))

    assert verdict["status"] == "done"
    assert verdict["summary"] == "Needs a test"
    assert verdict["checks"] == [%{"key" => "tests", "ok" => false, "note" => "none"}]
    assert verdict_revision == verdict["revision"]
    assert verdict["revision"] == DateTime.to_unix(judge.updated_at, :microsecond)

    # The run summary in the same refresh counts the new ledger.
    run_update = Enum.find(deltas, &(&1["kind"] == "run_update" and &1["entity_id"] == c.run.id))
    assert run_update["body"]["changes"] == 2

    # Nothing changed since: a refresh publishes no entity delta again.
    assert {:ok, _} = query(c.backend, c.scope, "workspace")

    assert collect(c.backend, "entities", 10)
           |> Enum.reject(&(&1["kind"] in ["run_update", "node_upsert"])) == []
  end

  test "a judge without a parseable result has no verdict and non-file ops carry no files", c do
    {:ok, _} = Conversations.update_node(c.judge, %{result: "not json"})

    {:ok, _} =
      Conversations.update_node(c.edit, %{op_type: "run_command", input: ~s({"path":"x"})})

    assert {:ok, %{"value" => workspace}} = query(c.backend, c.scope, "workspace")
    assert workspace["verdicts"] == []
    edit = Enum.find(workspace["transcript"]["items"], &(&1["id"] == c.edit.id))
    assert edit["tool"]["name"] == "run_command"
    assert edit["tool"]["files"] == []

    # A judge named without a round still verdicts, at round 0.
    {:ok, _} = Conversations.update_node(c.judge, %{name: "Judge", result: ~s({"checks":[]})})
    assert {:ok, %{"value" => workspace}} = query(c.backend, c.scope, "workspace")
    assert [%{"round" => 0, "checks" => [], "summary" => ""}] = workspace["verdicts"]
  end

  # ---------------------------------------------------------------- fixture

  defp fixture(c, conv) do
    t0 = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:millisecond)
    t1 = DateTime.add(t0, 1, :second)
    worktree = Path.join(c.root, ".worktrees/integrations-ops")

    {:ok, run} =
      Conversations.create_run(%{
        conversation_id: conv.id,
        kind: "swarm",
        consensus: true,
        prompt: "Ship the wire contract",
        status: "running",
        tokens_in: 1200,
        tokens_out: 300,
        cost_usd: 0.0421,
        model: "fixture-model",
        started_at: t0
      })

    lead =
      node!(%{
        run_id: run.id,
        kind: "agent",
        role: "lead",
        name: "Lead",
        title: "Planning the build",
        status: "running",
        progress: 40,
        tokens_in: 800,
        tokens_out: 200,
        cost_usd: 0.03,
        depth: 0,
        started_at: t0
      })

    {:ok, run} = Conversations.update_run(run, %{root_node_id: lead.id})

    worker =
      node!(%{
        run_id: run.id,
        parent_id: lead.id,
        kind: "agent",
        role: "worker",
        name: "integrations-ops",
        title: "Wire the daemon",
        status: "running",
        progress: 60,
        depth: 1,
        changes_stat: "+12 −3",
        workspace_path: worktree,
        started_at: t1
      })

    other =
      node!(%{
        run_id: run.id,
        parent_id: lead.id,
        kind: "agent",
        role: "worker",
        name: "docs-writer",
        status: "failed",
        depth: 1,
        result: "Docs findings",
        error: String.duplicate("e", 300),
        started_at: t1,
        finished_at: DateTime.add(t1, 5, :second)
      })

    judge =
      node!(%{
        run_id: run.id,
        parent_id: lead.id,
        kind: "agent",
        role: "worker",
        name: "Judge · round 2",
        status: "done",
        depth: 1,
        result:
          Jason.encode!(%{
            "verdict" => "approve",
            "summary" => "Plan is sound",
            "checks" => [
              %{"key" => "tests", "status" => "pass", "note" => "42 green"},
              %{"key" => "scope", "status" => "fail", "note" => "one file out of scope"},
              %{"key" => "codebase", "status" => "na"}
            ]
          }),
        started_at: t1,
        finished_at: DateTime.add(t1, 9, :second)
      })

    llm =
      node!(%{
        run_id: run.id,
        parent_id: lead.id,
        kind: "op",
        op_type: "llm",
        title: "thinking",
        status: "done",
        result: "Let me plan the build.",
        tokens_in: 100,
        tokens_out: 50,
        started_at: t1,
        finished_at: DateTime.add(t1, 2, :second)
      })

    grep =
      node!(%{
        run_id: run.id,
        parent_id: worker.id,
        kind: "op",
        op_type: "grep",
        title: "grep Bootstrap|Repo",
        detail: "3 hits",
        status: "done",
        result: "lib/a.ex:1\nlib/b.ex:2\nlib/c.ex:3",
        started_at: t1,
        finished_at: DateTime.add(t1, 400, :millisecond)
      })

    edit =
      node!(%{
        run_id: run.id,
        parent_id: worker.id,
        kind: "op",
        op_type: "edit_file",
        title: "edit lib/app.ex",
        detail: String.duplicate("d", 300),
        status: "running",
        input: Jason.encode!(%{"path" => "lib/app.ex", "old_string" => "a", "new_string" => "b"}),
        started_at: DateTime.add(t1, 3, :second)
      })

    {:ok, user_message} =
      Conversations.create_message(%{
        conversation_id: conv.id,
        run_id: run.id,
        role: "user",
        content: "Ship the wire contract"
      })

    {:ok, assistant_message} =
      Conversations.create_message(%{
        conversation_id: conv.id,
        run_id: run.id,
        role: "assistant",
        content: "Working on it.",
        tokens_in: 900,
        tokens_out: 250
      })

    {:ok, error_message} =
      Conversations.create_message(%{
        conversation_id: conv.id,
        run_id: run.id,
        role: "error",
        content: "provider hiccup"
      })

    c = Map.merge(c, %{root: c.root, run: run})
    project_checkpoint = checkpoint!(c, other.id, Path.join(c.root, "README.md"), false)
    worktree_checkpoint = checkpoint!(c, edit.id, Path.join(worktree, "lib/x.ex"), true)

    %{
      t0: t0,
      t1: t1,
      run: run,
      lead: lead,
      worker: worker,
      other: other,
      judge: judge,
      llm: llm,
      grep: grep,
      edit: edit,
      user_message: user_message,
      assistant_message: assistant_message,
      error_message: error_message,
      project_checkpoint: project_checkpoint,
      worktree_checkpoint: worktree_checkpoint
    }
  end

  defp node!(attrs) do
    {:ok, node} = Conversations.insert_node(attrs)
    node
  end

  # Checkpoints are inserted a millisecond apart so "newest first" is decidable.
  defp checkpoint!(c, node_id, path, restorable) do
    Process.sleep(2)

    %Checkpoint{}
    |> Checkpoint.changeset(%{
      conversation_id: c.run.conversation_id,
      run_id: c.run.id,
      node_id: node_id,
      path: path,
      previous_content: "before",
      restorable: restorable,
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })
    |> Repo.insert!()
  end

  defp run_scope(c), do: %{c.scope | kind: :run, id: c.run.id}

  defp collect(backend, ref, tries, acc \\ [])
  defp collect(_backend, _ref, 0, acc), do: Enum.reverse(acc)

  defp collect(backend, ref, tries, acc) do
    receive do
      {:service_delta, ^backend, ^ref, delta} ->
        send(backend, {:service_credit, self(), ref, delta["sequence"]})
        collect(backend, ref, tries, [delta | acc])
    after
      50 -> collect(backend, ref, tries - 1, acc)
    end
  end

  defp query(backend, scope, slot),
    do:
      GenServer.call(
        backend,
        {:service_request, "query-#{System.unique_integer([:positive])}", scope,
         %ServiceRequest{
           operation: :query,
           timeout_ms: 5000,
           params: %{
             "slot" => slot,
             "cursor" => nil,
             "direction" => "after",
             "page_size" => 200,
             "byte_limit" => 1_048_576
           }
         }},
        30000
      )
end
