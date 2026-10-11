defmodule SwarmCode.Daemon.Service.Cli021IntWorkflowApprovalTest do
  @moduledoc """
  cli021 integration (K3 + P2, fix-round open item S1): the session's
  `ncode -p --approval <mode>` reaches a workflow launch through the synced
  `Workflows.launch/1` (desktop pass 74 K3). An untrusted project refuses
  `auto`/`full_access` before anything is written, in words; `read_only` and
  no override start the run.
  """
  use ExUnit.Case, async: false
  alias SwarmCode.Daemon.Service.CommandDispatcher, as: Dispatcher
  alias SwarmCode.Domain.{Cache, Conversations, Engine, Projects, Repo, Workflows}
  alias SwarmCode.Domain.Tools.{StartSwarm, WorkflowRun}
  alias SwarmCode.Domain.Engine.RunServer
  alias SwarmCode.Test.C020Backend, as: Fixture

  setup_all do
    path =
      Path.join(
        System.tmp_dir!(),
        "cli021-int-wf-" <> Base.encode16(:crypto.strong_rand_bytes(8))
      )

    File.mkdir_p!(path)
    prior = Application.get_env(:swarm_code_daemon, :domain_config_dir)
    old_llm = Application.get_env(:swarm_code_daemon, :llm_providers)
    Application.put_env(:swarm_code_daemon, :domain_config_dir, Path.join(path, "config"))

    Application.put_env(:swarm_code_daemon, :llm_providers, %{
      "openai_compatible" => SwarmCode.Domain.LLM.OpenAI
    })

    on_exit(fn ->
      Cache.clear()

      if prior,
        do: Application.put_env(:swarm_code_daemon, :domain_config_dir, prior),
        else: Application.delete_env(:swarm_code_daemon, :domain_config_dir)

      if old_llm,
        do: Application.put_env(:swarm_code_daemon, :llm_providers, old_llm),
        else: Application.delete_env(:swarm_code_daemon, :llm_providers)

      File.rm_rf!(path)
    end)

    start_supervised!(
      {Repo,
       database: Path.join(path, "domain.db"),
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

    unless Process.whereis(SwarmCode.Domain.Hooks.TaskSupervisor),
      do: start_supervised!({Task.Supervisor, name: SwarmCode.Domain.Hooks.TaskSupervisor})

    %{path: path}
  end

  # A user-scope workflow runs in an untrusted project (a project-scope one
  # needs trust whatever the mode), so only the approval override can refuse.
  setup c do
    Cache.clear()
    root = Path.join(c.path, "project-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    {:ok, project} = Projects.create(%{name: "Workflow approval", root_path: root})
    {:ok, conv} = Conversations.create(project.id)
    on_exit(fn -> Engine.stop_all(conv.id) end)

    source = ~s(meta = %{name: "int-flow", description: "Fixture"}\n"finished")
    {:ok, definition} = Workflows.parse(source, "user")
    refute Projects.trusted?(Projects.get!(project.id))
    %{conversation: conv, definition: definition, project: project, root: root}
  end

  defp launch(c, opts),
    do: Dispatcher.dispatch(c.conversation.id, "/int-flow", [workflows: [c.definition]] ++ opts)

  test "auto in an untrusted project is refused in words, and nothing is written", c do
    for mode <- ["auto", "full_access"] do
      assert {:error, {:untrusted_project, words}} = launch(c, approval_mode: mode)
      assert words =~ "trusted project"
    end

    assert Conversations.list_messages(c.conversation.id) == []
    assert Conversations.list_runs(c.conversation.id) == []
  end

  test "read-only, or no override, starts the run", c do
    assert {:ok, %{type: :started, run_id: id}} = launch(c, approval_mode: "read_only")
    assert Conversations.get_run(id).conversation_id == c.conversation.id

    assert {:ok, %{type: :started, run_id: other}} = launch(c, [])
    assert other != id
  end

  for kind <- [:swarm, :saved_workflow, :one_off_workflow] do
    test "#{kind} retains valid and nil modes at actual child writes", c do
      c = Map.merge(c, parent_run(c))
      {:ok, project} = Projects.trust(c.project)
      {:ok, project} = Projects.update(project, %{approval_mode: "full_access"})
      c = Map.put(c, :project, project)
      backend = Fixture.start_backend(c, c.conversation)
      scope = Fixture.scope(c.conversation)

      for mode <- ["read_only", "auto", "full_access", nil] do
        Cache.clear()
        file = "#{unquote(kind)}-#{mode || "project"}.txt"

        {conv, _, server} =
          Fixture.provider!(c, c.conversation, fn
            1 ->
              {:tool, "run_command",
               %{"command" => "touch #{file}", "justification" => "fixture write"}}

            _ ->
              :hang
          end)

        c = %{c | conversation: conv}
        before = Conversations.list_runs(conv.id)
        assert {:ok, words} = child_launch(c, unquote(kind), mode)
        [run] = Conversations.list_runs(conv.id) -- before
        assert run.conversation_id == conv.id

        if unquote(kind) == :swarm do
          assert run.launched_by_run_id == c.parent_run.id
          assert words =~ "Swarm started"

          assert {:error,
                  "a swarm is already running in this conversation — wait for it or stop it"} =
                   child_launch(c, :swarm, mode)
        else
          wf = Workflows.get_run_row(run.id)
          assert wf.created_by == "model"
          assert words =~ "Started #{wf.display_name}."
        end

        if mode in ["read_only", "auto"] do
          assert Fixture.eventually(fn -> Fixture.pending_approvals(backend, scope) != [] end),
                 inspect({Conversations.get_run(run.id), Conversations.list_nodes(run.id)})

          [approval] = Fixture.pending_approvals(backend, scope)
          assert approval["run_id"] == run.id
          assert approval["state"] == "pending"
          card = approval["approval"]
          assert card["approval_mode"] == mode
          assert card["tool"] == "run_command"

          if mode == "read_only",
            do: assert(card["allowed_decisions"] == ["approve", "deny", "deny_stop"])

          op = Conversations.get_node(approval["node_id"])
          assert op.kind == "op"
          assert op.op_type == "run_command"
          refute File.exists?(Path.join(c.root, file))

          assert {:ok, %{"value" => %{"status" => "accepted"}}} =
                   Fixture.command(backend, "deny-child", scope, :approval_resolve, %{
                     "run_id" => run.id,
                     "node_id" => op.id,
                     "interaction_id" => approval["id"],
                     "expected_revision" => approval["expected_revision"],
                     "decision" => "deny"
                   })

          assert Fixture.eventually(fn ->
                   Conversations.get_node(op.id).error == "denied by user"
                 end)

          refute File.exists?(Path.join(c.root, file))
        else
          assert Fixture.eventually(fn -> File.exists?(Path.join(c.root, file)) end)
          assert File.read!(Path.join(c.root, file)) == ""
          assert Fixture.pending_approvals(backend, scope) == []
        end

        assert RunServer.get_state(run.id).approval_override == mode
        assert Projects.get!(project.id).approval_mode == "full_access"
        assert Projects.trusted?(Projects.get!(project.id))
        Engine.stop_all(conv.id)
        assert Fixture.eventually(fn -> Engine.running_runs(conv.id) == [] end)
        SwarmCode.Test.LoopbackHTTP.stop(server)
      end
    end
  end

  defp parent_run(c) do
    {:ok, parent} =
      Conversations.create_run(%{
        conversation_id: c.conversation.id,
        kind: "chat",
        started_at: DateTime.utc_now()
      })

    %{parent_run: parent}
  end

  defp child_launch(c, kind, mode) do
    ctx = %{
      conversation_id: c.conversation.id,
      project_id: c.project.id,
      run_id: c.parent_run.id,
      approval_override: mode
    }

    if kind == :swarm do
      StartSwarm.run(%{"task" => "fixture write"}, ctx, nil)
    else
      source = ~S"""
      meta = %{name: "child-flow", description: "Fixture"}
      agent("fixture write", capability: :execute)
      complete("child result")
      """

      args =
        if kind == :saved_workflow do
          {:ok, _} = Workflows.save(c.project, "user", "child-flow", source)
          %{"name" => "child-flow"}
        else
          %{"source" => source, "budget" => 1}
        end

      WorkflowRun.run(args, ctx, nil)
    end
  end

  test "untrusted and invalid child launches preserve refusals without writing rows", c do
    c = Map.merge(c, parent_run(c))

    for kind <- [:swarm, :saved_workflow, :one_off_workflow],
        mode <- ["auto", "full_access", "invalid"] do
      before = Conversations.list_runs(c.conversation.id)
      workflows = Repo.all(SwarmCode.Domain.Workflows.Run)
      reason = if mode == "invalid", do: ":invalid_approval_mode", else: ":untrusted_project"
      expected = if kind == :swarm, do: "could not start the swarm: " <> reason, else: reason
      assert {:error, ^expected} = child_launch(c, kind, mode)
      assert Conversations.list_runs(c.conversation.id) == before
      assert Repo.all(SwarmCode.Domain.Workflows.Run) == workflows
      assert Conversations.list_messages(c.conversation.id) == []
    end

    refute Map.has_key?(StartSwarm.parameters()["properties"], "approval_mode")
    refute Map.has_key?(WorkflowRun.parameters()["properties"], "approval_mode")
  end

  test "invalid overrides also refuse on a trusted full-access project without child rows", c do
    c = Map.merge(c, parent_run(c))
    {:ok, project} = Projects.trust(c.project)
    {:ok, project} = Projects.update(project, %{approval_mode: "full_access"})
    c = %{c | project: project}

    for kind <- [:swarm, :saved_workflow, :one_off_workflow] do
      before = Conversations.list_runs(c.conversation.id)
      workflows = Repo.all(SwarmCode.Domain.Workflows.Run)

      expected =
        if kind == :swarm,
          do: "could not start the swarm: :invalid_approval_mode",
          else: ":invalid_approval_mode"

      assert {:error, ^expected} = child_launch(c, kind, "invalid")
      assert Conversations.list_runs(c.conversation.id) == before
      assert Repo.all(SwarmCode.Domain.Workflows.Run) == workflows
      assert Conversations.list_messages(c.conversation.id) == []
    end
  end
end
