defmodule SwarmCode.Domain.Tools.C75AgentTitleTest do
  @moduledoc """
  Pass 75 (tasks 106-108): the Lead's display name for a spawned agent is
  cleaned by `AgentTitle.clean/2` (first line, no control characters, one pair
  of quotes off, three words, 24 characters, 32 bytes, the slug when nothing is
  left), `spawn_agent` advertises it as optional, and `RunServer.start_agent/2`
  stores it in the shared `nodes.title` column (the slug when none is given).

  The module is not async: the stored-title test shares the guarded Repo
  launch and the loopback provider of `pass70_saved_turn_test.exs`, which set
  global application state.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 180_000

  alias SwarmCode.Daemon.RepoLauncher
  alias SwarmCode.Domain.{Cache, Conversations, Engine, Projects, Providers, Repo}
  alias SwarmCode.Domain.Conversations.Node
  alias SwarmCode.Domain.Engine.RunServer
  alias SwarmCode.Domain.Tools.{AgentTitle, SpawnAgent}
  alias SwarmCode.Test.LoopbackHTTP, as: HTTP

  @slug "build-verify-review"

  @cases [
    {"Build check", "Build check"},
    {"\"Strategy fit\"\nsecond line", "Strategy fit"},
    {"verify the whole build pipeline end to end", "verify the whole"},
    {nil, @slug},
    {"   ", @slug},
    {String.duplicate("é", 30), String.duplicate("é", 16)},
    # cli75 W review (W-5): a cut on the word gap leaves no trailing space.
    {"aaaaaaaaaaaaaaaaaaaaaaa bb cc", "aaaaaaaaaaaaaaaaaaaaaaa"}
  ]

  # The guarded launch (verified backup, then the 53 -> 57 migration) costs
  # seconds; only the stored-title test needs it.
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
      app_version: "0.1.0",
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
           process_start_id: "c75-agent-title",
           boot_id: "c75-agent-title"
         }}
      end
    ]

    {:ok, launcher} = RepoLauncher.start_link(boot_config: boot, pool_size: 3)
    Process.unlink(launcher)
    {:ok, _repo} = RepoLauncher.await_ready(launcher, 90_000)
    on_exit(fn -> :ok = RepoLauncher.close(launcher) end)

    %{root: root}
  end

  for {{input, expected}, index} <- Enum.with_index(@cases) do
    test "clean/2 case #{index + 1}" do
      assert AgentTitle.clean(unquote(input), @slug) == unquote(expected)
    end
  end

  test "a control character and a quoted multi-line title" do
    assert AgentTitle.clean("\"Build\u0007 check\"\nmore", @slug) == "Build check"
  end

  test "the tool advertises title" do
    assert get_in(SpawnAgent.parameters(), ["properties", "title", "type"]) == "string"
    refute "title" in SpawnAgent.parameters()["required"]
  end

  test "start_agent stores the title", c do
    Cache.clear()
    project_root = Path.join(c.root, "project-#{System.unique_integer([:positive])}")
    File.mkdir_p!(project_root)
    {_, 0} = System.cmd("git", ["init", "-q", project_root])

    on_exit(fn ->
      Engine.stop_all()
      eventually(fn -> Engine.running_run_ids() == [] end, 30_000)
      Cache.clear()
    end)

    {:ok, project} = Projects.create(%{name: "Agent title", root_path: project_root})
    {:ok, project} = Projects.trust(project)

    # The first request (the root agent's) waits for :release, so the run is
    # alive while the test registers sub-agents under it; every other request
    # (the sub-agents', the root's next turn) answers plain text.
    server =
      HTTP.start(fn socket, _request, turn ->
        if turn == 1 do
          receive do
            :release -> :ok
          after
            30_000 -> :ok
          end
        end

        answer(socket, %{"content" => "Done."})
      end)

    on_exit(fn -> HTTP.stop(server) end)
    conversation = conversation!(project, server)

    assert {:ok, run_id} = Engine.start_chat_turn(conversation, "name your helpers")
    assert_receive {:http_request, 1, _first}, 10_000

    assert [[lead_id]] =
             eventually(fn ->
               rows =
                 Repo.query!(
                   "SELECT id FROM nodes WHERE run_id = ? AND kind = 'agent' AND parent_id IS NULL",
                   [run_id]
                 ).rows

               rows != [] && rows
             end)

    attrs = %{
      parent_id: lead_id,
      name: @slug,
      task: "t",
      context: nil,
      depth: 1,
      agent_def: nil,
      model_override: nil,
      effort_override: nil,
      output_schema: nil
    }

    assert {:ok, titled} = RunServer.start_agent(run_id, Map.put(attrs, :title, "Build check"))
    assert {:ok, untitled} = RunServer.start_agent(run_id, attrs)

    # RunServer flushes node rows in batches; the persisted rows catch up.
    assert %Node{name: @slug, title: "Build check"} =
             eventually(fn -> Repo.get(Node, titled) end)

    assert %Node{name: @slug, title: @slug} = eventually(fn -> Repo.get(Node, untitled) end)

    send(server.pid, :release)
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

  defp answer(socket, delta) do
    HTTP.stream(socket, [
      HTTP.sse(%{
        "choices" => [%{"index" => 0, "delta" => delta, "finish_reason" => "stop"}]
      })
    ])
  end

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
