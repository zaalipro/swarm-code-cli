defmodule SwarmCode.Domain.Engine.Pass70SavedTurnTest do
  @moduledoc """
  Pass 70 A6: the synced (desktop 6dd8d82) engine runs a saved-mode chat turn
  end to end under the guarded Repo. The database starts at the desktop's 53
  migrations, so the CLI's own backup and forward migration to 57 (the FTS5
  index and its triggers included) happen first; then a loopback provider asks
  for `run_command` (with `yield_ms`), then `edit_file`, then answers. A second
  turn waits on a real RunServer approval and is released through the
  `pending_interactions/1` row, the way the service boundary does it.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 180_000

  alias SwarmCode.Daemon.RepoLauncher
  alias SwarmCode.Domain.{Cache, Conversations, Engine, Projects, Providers, Repo}
  alias SwarmCode.Domain.Engine.RunServer
  alias SwarmCode.Test.LoopbackHTTP, as: HTTP

  # The guarded launch (verified backup, then the 53 -> 57 migration) costs
  # seconds, so both turns share one launch; each test gets its own project.
  setup_all do
    SwarmCode.Domain.TestGlobalDir.isolate!()
    ensure_runtime_children!()

    old_llm = Application.get_env(:swarm_code_daemon, :llm_providers)

    Application.put_env(:swarm_code_daemon, :llm_providers, %{
      "openai_compatible" => SwarmCode.Domain.LLM.OpenAI
    })

    on_exit(fn ->
      if old_llm,
        do: Application.put_env(:swarm_code_daemon, :llm_providers, old_llm),
        else: Application.delete_env(:swarm_code_daemon, :llm_providers)
    end)

    source =
      SchemaFixture.database!(
        {:prefix, 20_261_015_000_003},
        SwarmCode.Daemon.Test.LeaseFixture.build_root()
      )

    database = Path.join(Path.dirname(source), "swarm_code.db")
    File.rename!(source, database)
    root = Path.dirname(database)
    uid = File.stat!(root).uid

    boot = [
      platform: :linux,
      mode: :test,
      home: root,
      env:
        Map.new(
          ~w(XDG_DATA_HOME XDG_CONFIG_HOME XDG_STATE_HOME XDG_CACHE_HOME XDG_RUNTIME_DIR),
          &{&1, root}
        ),
      database_path: database,
      app_version: "0.1.0-dev",
      desktop_detector: fn -> :none end,
      directory_ensure: fn path, owner ->
        case File.mkdir(path) do
          :ok -> File.chmod!(path, 0o700)
          {:error, :eexist} -> :ok
        end

        SwarmCode.Daemon.Platform.PrivateDirectory.ensure(path, owner)
      end,
      identity: fn ->
        {:ok,
         %SwarmCode.Daemon.Platform.ProcessIdentity{
           uid: uid,
           pid: String.to_integer(System.pid()),
           process_start_id: "pass70-saved-turn",
           boot_id: "pass70-saved-turn"
         }}
      end
    ]

    {:ok, launcher} = RepoLauncher.start_link(boot_config: boot, pool_size: 3)
    # The launcher outlives the setup_all process so the runs can be stopped
    # (and flush their last rows) before the guarded pool closes.
    Process.unlink(launcher)
    {:ok, _repo} = RepoLauncher.await_ready(launcher, 90_000)
    on_exit(fn -> :ok = RepoLauncher.close(launcher) end)

    %{root: root}
  end

  setup c do
    Cache.clear()
    project_root = Path.join(c.root, "project-#{System.unique_integer([:positive])}")
    File.mkdir_p!(project_root)
    {_, 0} = System.cmd("git", ["init", "-q", project_root])
    File.write!(Path.join(project_root, "notes.md"), "alpha\nbeta\n")

    on_exit(fn ->
      Engine.stop_all()
      eventually(fn -> Engine.running_run_ids() == [] end, 30_000)
      Cache.clear()
    end)

    %{project_root: project_root}
  end

  test "a 53-migration database is moved to 57 and a tool turn completes on it", c do
    assert [[57]] = Repo.query!("SELECT count(*) FROM schema_migrations").rows

    {:ok, project} =
      Projects.create(%{
        name: "Saved turn",
        root_path: c.project_root,
        approval_mode: "full_access"
      })

    {:ok, project} = Projects.trust(project)
    assert project.approval_mode == "full_access"

    server =
      HTTP.start(fn socket, _request, turn ->
        delta =
          case turn do
            1 ->
              tool_call("t1", "run_command", %{"command" => "printf ready", "yield_ms" => 5_000})

            2 ->
              tool_call("t2", "edit_file", %{
                "path" => "notes.md",
                "old_string" => "beta",
                "new_string" => "gamma"
              })

            _ ->
              %{"content" => "Changed notes.md."}
          end

        answer(socket, delta, turn <= 2)
      end)

    on_exit(fn -> HTTP.stop(server) end)
    conversation = conversation!(project, server)

    assert {:ok, run_id} = Engine.start_chat_turn(conversation, "change beta to gamma")
    assert eventually(fn -> Conversations.get_run(run_id).status == "done" end)

    assert File.read!(Path.join(c.project_root, "notes.md")) == "alpha\ngamma\n"

    assert_receive {:http_request, 2, second}, 5_000
    assert second.body =~ "ready"
    assert_receive {:http_request, 3, third}, 5_000
    assert third.body =~ "edited notes.md"

    ops =
      Repo.query!(
        "SELECT op_type, status FROM nodes WHERE run_id = ? AND kind = 'op' ORDER BY position",
        [run_id]
      ).rows

    assert ["run_command", "done"] in ops
    assert ["edit_file", "done"] in ops

    assert [[1]] =
             Repo.query!(
               "SELECT count(*) FROM checkpoints WHERE run_id = ? AND path LIKE '%notes.md'",
               [run_id]
             ).rows

    # The pass-69 FTS5 triggers fire for the engine's own writes under the
    # guarded connection (rel F10 step 2).
    assert [[n]] =
             Repo.query!("SELECT count(*) FROM messages_fts WHERE messages_fts MATCH 'gamma'").rows

    assert n >= 1
  end

  test "an approval waits on the op node and the pending row releases it", c do
    {:ok, project} = Projects.create(%{name: "Approval turn", root_path: c.project_root})
    {:ok, project} = Projects.trust(project)
    assert project.approval_mode == "auto"

    server =
      HTTP.start(fn socket, _request, turn ->
        delta =
          if turn == 1,
            do:
              tool_call("a1", "run_command", %{
                "command" => "touch made.txt",
                "justification" => "leave a marker"
              }),
            else: %{"content" => "Marker left."}

        answer(socket, delta, turn == 1)
      end)

    on_exit(fn -> HTTP.stop(server) end)
    conversation = conversation!(project, server)

    assert {:ok, run_id} = Engine.start_chat_turn(conversation, "leave a marker")
    assert row = eventually(fn -> List.first(RunServer.pending_interactions(run_id)) end)

    project_root = Projects.get!(project.id).root_path

    assert %{
             kind: :approval,
             tool: "run_command",
             command: "touch made.txt",
             cwd: ^project_root,
             reason: "leave a marker",
             command_family: "touch",
             classification: :normal,
             permission: :execute,
             allowed_decisions: [:approve, :approve_run, :always_prefix, :deny, :deny_stop]
           } = row

    assert %DateTime{} = row.requested_at
    assert is_binary(row.agent_id) and row.agent_id != row.node_id

    # RunServer flushes node rows in batches; the persisted op catches up.
    assert eventually(fn ->
             Repo.query!("SELECT kind, op_type, status FROM nodes WHERE id = ?", [row.node_id]).rows ==
               [["op", "run_command", "awaiting_approval"]]
           end)

    refute File.exists?(Path.join(c.project_root, "made.txt"))
    :ok = RunServer.resolve_approval(run_id, row.node_id, {:always_prefix, "anything"})

    assert eventually(fn -> Conversations.get_run(run_id).status == "done" end)
    assert File.exists?(Path.join(c.project_root, "made.txt"))
    assert RunServer.pending_interactions(run_id) == []
    # The family the server computed is what the project remembers, not the client's.
    assert "touch" in (Projects.get!(project.id).auto_approve_prefixes || [])
    refute "anything" in (Projects.get!(project.id).auto_approve_prefixes || [])
  end

  # -- helpers ----------------------------------------------------------------

  defp conversation!(project, server) do
    {:ok, provider} =
      Providers.create(%{
        name: "loopback-#{System.unique_integer([:positive])}",
        kind: "openai_compatible",
        base_url: server.url <> "/v1",
        models: ["fixture"],
        default_model: "fixture"
      })

    {:ok, conversation} = Conversations.create(project.id)

    {:ok, conversation} =
      Conversations.update(conversation, %{chat_provider_id: provider.id, chat_model: "fixture"})

    conversation
  end

  defp tool_call(id, name, args) do
    %{
      "tool_calls" => [
        %{
          "index" => 0,
          "id" => id,
          "type" => "function",
          "function" => %{"name" => name, "arguments" => Jason.encode!(args)}
        }
      ]
    }
  end

  defp answer(socket, delta, tool?) do
    HTTP.stream(socket, [
      HTTP.sse(%{
        "choices" => [
          %{
            "index" => 0,
            "delta" => delta,
            "finish_reason" => if(tool?, do: "tool_calls", else: "stop")
          }
        ]
      })
    ])
  end

  # The synced engine needs these beside `SwarmCode.Domain.Runtime` (owner B
  # adds them there in B6); start whichever the runtime does not own yet.
  defp ensure_runtime_children! do
    for child <- [
          SwarmCode.Domain.Tools.BackgroundProcs,
          {Task.Supervisor, name: SwarmCode.Domain.Hooks.TaskSupervisor},
          SwarmCode.Domain.LSP.Supervisor
        ] do
      name =
        case child do
          {Task.Supervisor, opts} -> opts[:name]
          module -> module
        end

      if Process.whereis(name) == nil, do: start_supervised!(child)
    end
  end

  defp eventually(fun, timeout \\ 20_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(fun, deadline)
  end

  defp poll(fun, deadline) do
    case fun.() do
      value when value not in [nil, false] ->
        value

      _other ->
        if System.monotonic_time(:millisecond) > deadline do
          false
        else
          Process.sleep(25)
          poll(fun, deadline)
        end
    end
  end
end
