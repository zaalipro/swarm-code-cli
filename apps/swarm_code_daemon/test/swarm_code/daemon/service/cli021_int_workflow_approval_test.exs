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

  setup_all do
    path =
      Path.join(
        System.tmp_dir!(),
        "cli021-int-wf-" <> Base.encode16(:crypto.strong_rand_bytes(8))
      )

    File.mkdir_p!(path)
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
    %{conversation: conv, definition: definition}
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
end
