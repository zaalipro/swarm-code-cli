defmodule SwarmCode.Daemon.Service.Pass72PanelWireTest do
  @moduledoc """
  pass72 S: the persisted backend puts the side panel's facts on the wire,
  derived from seeded rows only (a swarm with a waiting lead, a working and a
  finished reviewer, a consensus run, two goal iterations and a workflow), and
  the CLI's DTOs decode them.
  """
  use ExUnit.Case, async: false
  alias SwarmCode.Daemon.Service.PersistedBackend, as: Backend
  alias SwarmCode.Domain.{Cache, Conversations, Engine, Projects, Repo}
  alias SwarmCode.Domain.Checkpoints.Checkpoint
  alias SwarmCode.Protocol.{Scope, ServiceRequest}
  alias SwarmCodeCLI.UI.DataSource.DTO

  setup_all do
    path = Path.join(System.tmp_dir!(), "pass72-panel-#{System.unique_integer([:positive])}")
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

    {:ok, project} = Projects.create(%{name: "Panel", root_path: root})
    %{project: project, root: root}
  end

  setup c do
    Cache.clear()
    {:ok, conv} = Conversations.create(c.project.id)
    fixture = fixture(c, conv)

    backend =
      start_supervised!(
        {Backend,
         [
           mode: :persisted,
           repo: Repo,
           project_root: c.root,
           project_id: c.project.id,
           conversation_id: conv.id,
           source_epoch: Ecto.UUID.generate()
         ]}
      )

    on_exit(fn -> Engine.stop_all(conv.id) end)

    Map.merge(fixture, %{
      backend: backend,
      scope: %Scope{kind: :conversation, id: conv.id, generation: 1}
    })
  end

  test "agents carry the P3 state, a plain sentence, the lane, the finding and files", c do
    assert {:ok, %{"value" => workspace}} = query(c.backend, c.scope, "workspace")
    assert {:ok, snapshot} = DTO.WorkspaceSnapshot.decode(workspace)
    agents = Map.new(snapshot.agents, &{&1.id, &1})

    lead = agents[c.lead.id]
    assert lead.panel_state == :waiting
    assert lead.now == "waiting on 2 agents"
    assert lead.lane_now == :idle

    web = agents[c.web.id]
    assert web.panel_state == :working
    assert web.now == "running mix test test/app_test.exs"
    assert web.lane_now == :tools
    assert length(web.lane) == 12
    assert web.lane_at == DateTime.to_unix(c.t0, :millisecond) + 35_000
    assert List.last(web.lane) == :tools
    assert :write in web.lane and :think in web.lane
    assert web.files_changed == 1
    assert web.elapsed_ms == nil
    assert web.tokens == 1_500

    data = agents[c.data.id]
    assert data.panel_state == :done
    assert data.finding == "Flushes can race the stop in lib/app/run_server.ex:88."
    assert data.now == data.finding
    assert data.finding_refs == ["lib/app/run_server.ex:88", "lib/app/flush.ex:12"]
    assert data.lane == []
    assert data.elapsed_ms == 40_000

    for agent <- snapshot.agents,
        text <- [agent.now, agent.finding || ""] ++ agent.finding_refs do
      refute text =~ "swarm/"
      refute text =~ "worktrees"
      refute text =~ c.run.id
    end
  end

  test "runs carry reported of total, consensus rounds, goal iterations and phases", c do
    assert {:ok, %{"value" => workspace}} = query(c.backend, c.scope, "workspace")
    assert {:ok, snapshot} = DTO.WorkspaceSnapshot.decode(workspace)
    runs = Map.new(snapshot.runs, &{&1.id, &1})

    swarm = runs[c.run.id]
    assert {swarm.reported, swarm.total} == {1, 2}
    assert swarm.needs_you == []
    assert swarm.round == nil and swarm.phases == []

    consensus = runs[c.consensus.id]
    assert {consensus.round, consensus.rounds} == {1, 3}
    assert consensus.verdict == "One file is out of scope."

    assert {runs[c.goal_1.id].goal_iteration, runs[c.goal_1.id].goal_iterations} == {1, 2}
    assert {runs[c.goal_2.id].goal_iteration, runs[c.goal_2.id].goal_status} == {2, "active"}

    workflow = runs[c.workflow.id]
    assert workflow.phase == "implement"

    assert [
             %DTO.Phase{name: "scan", state: :done},
             %DTO.Phase{name: "implement", state: :running, agent_count: 1, live: 1},
             %DTO.Phase{name: "report", state: :queued}
           ] = workflow.phases
  end

  test "an agent's detail: brief, grouped activity, raw operations, life lane and files", c do
    assert {:ok, %{"response_kind" => "agent_detail", "value" => value}} =
             agent_detail(c.backend, c.scope, c.run.id, c.web.id)

    assert {:ok, detail} = DTO.AgentDetail.decode(value)

    assert {detail.state, detail.name, detail.role, detail.panel_state} ==
             {:idle, "web-review", :sub, :working}

    assert detail.parent_name == "Lead"
    assert detail.brief == ""

    assert Enum.map(detail.activity, &{&1.kind, &1.title}) == [
             {:think, "thought"},
             {:read, "read 1 file"},
             {:edit, "edited lib/app.ex"},
             {:command, "ran mix compile"},
             {:command, "ran mix test test/app_test.exs"}
           ]

    assert Enum.at(detail.activity, 3).quote == "Generated app"
    assert List.last(detail.activity).state == :running
    assert length(detail.operations) == 5
    assert detail.files_read == ["lib/app.ex"]
    assert detail.files_changed == ["lib/app.ex"]
    assert detail.life_started_at == DateTime.to_unix(c.t0, :millisecond)
    assert detail.life_bucket_ms == 1_000 and length(detail.life) == 35
    assert detail.think_ms == 4_000
    assert {detail.tokens_in, detail.tokens_out} == {1_200, 300}

    for text <- [detail.now | detail.files_read ++ Enum.map(detail.operations, & &1.title)] do
      refute text =~ "worktrees"
    end
  end

  test "a finished reviewer's detail lists its numbered findings with severity and ref", c do
    assert {:ok, %{"value" => value}} = agent_detail(c.backend, c.scope, c.run.id, c.data.id)
    assert {:ok, detail} = DTO.AgentDetail.decode(value)

    assert [
             %DTO.Finding{n: 1, severity: :high, ref: "lib/app/run_server.ex:88"} = first,
             %DTO.Finding{n: 2, severity: :low, ref: "lib/app/flush.ex:12"}
           ] = detail.findings

    assert first.text =~ "a stop during a flush loses the last batch"
    assert detail.result =~ "## Findings"
    refute detail.result =~ "worktrees"
    assert detail.finished_at == DateTime.to_unix(c.t0, :millisecond) + 40_000
  end

  test "an agent of another run, or not an agent, is not allowed", c do
    assert {:error, %{"code" => "not_allowed"}} =
             agent_detail(c.backend, c.scope, c.consensus.id, c.web.id)

    assert {:error, %{"code" => "not_allowed"}} =
             agent_detail(c.backend, c.scope, c.run.id, Ecto.UUID.generate())
  end

  test "an agent's transcript item never carries the engine's isolation line", c do
    assert {:ok, %{"value" => workspace}} = query(c.backend, c.scope, "workspace")
    item = Enum.find(workspace["transcript"]["items"], &(&1["id"] == c.web.id))
    assert item
    refute item["text"] =~ "isolated in"
    refute item["text"] =~ "swarm/"
    assert item["detail_ref"] == nil
  end

  test "the facts are a function of the database: a second projection publishes the same bodies",
       c do
    assert {:ok, %{"value" => first}} = query(c.backend, c.scope, "workspace")
    assert {:ok, %{"value" => second}} = query(c.backend, c.scope, "workspace")
    assert first["agents"] == second["agents"]
    assert first["runs"] == second["runs"]
  end

  # ---------------------------------------------------------------- fixture

  defp fixture(c, conv) do
    t0 = ~U[2026-09-24 10:00:00.000000Z]
    at = fn s -> DateTime.add(t0, s, :second) end
    worktree = Path.join(c.root, ".swarm_code/worktrees/2404157a/web-review-bd868c6f")

    {:ok, run} =
      Conversations.create_run(%{
        conversation_id: conv.id,
        kind: "swarm",
        prompt: "Review the engine",
        status: "running",
        started_at: t0
      })

    lead =
      node!(%{
        run_id: run.id,
        kind: "agent",
        role: "lead",
        name: "Lead",
        status: "running",
        started_at: t0
      })

    {:ok, run} = Conversations.update_run(run, %{root_node_id: lead.id})

    web =
      node!(%{
        run_id: run.id,
        parent_id: lead.id,
        kind: "agent",
        role: "sub",
        name: "web-review",
        status: "running",
        depth: 1,
        tokens_in: 1_200,
        tokens_out: 300,
        detail: "isolated in swarm/2404157a/web-review-bd868c6f",
        workspace_path: worktree,
        started_at: t0
      })

    data =
      node!(%{
        run_id: run.id,
        parent_id: lead.id,
        kind: "agent",
        role: "sub",
        name: "data-review",
        status: "done",
        depth: 1,
        result:
          "## Summary\n\nFlushes can race the stop in `lib/app/run_server.ex:88`. " <>
            "The fix is in #{worktree}/lib/app/flush.ex:12.\n\n## Findings\n\n" <>
            "1. **High:** a stop during a flush loses the last batch (lib/app/run_server.ex:88).\n" <>
            "2. Minor: the flush timer is never cancelled. See lib/app/flush.ex:12.\n",
        started_at: t0,
        finished_at: at.(40)
      })

    for name <- ["web-review", "data-review"],
        do: op!(run, lead, "spawn_agent", "agent " <> name, t0, nil, "running")

    op!(run, web, "llm", "thinking", at.(0), at.(4), "done")
    op!(run, web, "read_file", "read #{worktree}/lib/app.ex", at.(5), at.(6), "done")
    write = op!(run, web, "edit_file", "edit lib/app.ex", at.(10), at.(14), "done")

    node!(%{
      run_id: run.id,
      parent_id: web.id,
      kind: "op",
      op_type: "run_command",
      title: "run: mix compile",
      status: "done",
      result: "Compiling 3 files\nGenerated app\n\n",
      started_at: at.(15),
      finished_at: at.(20)
    })

    op!(
      run,
      web,
      "run_command",
      "run: mix test test/app_test.exs (in #{worktree})",
      at.(30),
      nil,
      "running"
    )

    checkpoint!(run, write.id, Path.join(worktree, "lib/app.ex"))

    {:ok, consensus} =
      Conversations.create_run(%{
        conversation_id: conv.id,
        kind: "swarm",
        consensus: true,
        consensus_config: %{"rounds" => 3},
        prompt: "Plan it",
        status: "running",
        started_at: t0
      })

    node!(%{
      run_id: consensus.id,
      kind: "agent",
      role: "worker",
      name: "Judge · round 1",
      status: "done",
      result:
        Jason.encode!(%{
          "verdict" => "revise",
          "summary" => "One file is out of scope.",
          "checks" => []
        }),
      started_at: t0,
      finished_at: at.(9)
    })

    {:ok, goal} = Conversations.add_goal(conv.id, "Make the tests green")

    goal_run = fn prompt ->
      {:ok, r} =
        Conversations.create_run(%{
          conversation_id: conv.id,
          kind: "chat",
          goal_id: goal.id,
          prompt: prompt,
          status: "done",
          started_at: t0
        })

      Process.sleep(2)
      r
    end

    goal_1 = goal_run.("iteration one")
    goal_2 = goal_run.("iteration two")

    {:ok, workflow} =
      Conversations.create_run(%{
        conversation_id: conv.id,
        kind: "workflow",
        prompt: "ship",
        status: "running",
        started_at: t0
      })

    %SwarmCode.Domain.Workflows.Run{}
    |> SwarmCode.Domain.Workflows.Run.changeset(%{
      run_id: workflow.id,
      conversation_id: conv.id,
      display_name: "Ship",
      source: "meta = %{}",
      budget: 8,
      max_live: 2,
      phases: ~w(scan implement report),
      phase: "implement"
    })
    |> Repo.insert!()

    node!(%{
      run_id: workflow.id,
      kind: "agent",
      role: "worker",
      name: "implementer",
      status: "running",
      phase: "implement",
      started_at: t0
    })

    %{
      t0: t0,
      run: run,
      lead: lead,
      web: web,
      data: data,
      consensus: consensus,
      goal_1: goal_1,
      goal_2: goal_2,
      workflow: workflow
    }
  end

  defp node!(attrs) do
    {:ok, node} = Conversations.insert_node(attrs)
    node
  end

  defp op!(run, agent, type, title, started, finished, status),
    do:
      node!(%{
        run_id: run.id,
        parent_id: agent.id,
        kind: "op",
        op_type: type,
        title: title,
        status: status,
        started_at: started,
        finished_at: finished
      })

  defp checkpoint!(run, node_id, path) do
    %Checkpoint{conversation_id: run.conversation_id, run_id: run.id, node_id: node_id}
    |> Checkpoint.changeset(%{
      path: path,
      previous_content: "before",
      restorable: true,
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })
    |> Checkpoint.validate()
    |> Repo.insert!()
  end

  defp agent_detail(backend, scope, run_id, node_id),
    do:
      GenServer.call(
        backend,
        {:service_request, "detail-#{System.unique_integer([:positive])}", scope,
         %ServiceRequest{
           operation: :agent_detail,
           timeout_ms: 5000,
           params: %{"run_id" => run_id, "node_id" => node_id}
         }},
        30000
      )

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
