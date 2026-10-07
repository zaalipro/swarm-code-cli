defmodule SwarmCode.Domain.Engine.CliDirtyTreeTest do
  @moduledoc """
  cli020 A9 (ux-live-2, desktop 93b58ea6 = spec 74 BUGS-59): a worker that
  changed nothing used to report the user's uncommitted changes as its own
  ("75 files changed"), because its clone started from the dirty working tree.
  The synced engine (desktop 4c7c577) starts every isolated worker at HEAD.

  A git project with three uncommitted files (modified, staged, untracked), a
  swarm on a loopback provider whose worker answers without a tool call, under
  both isolation backends: the worker's report ends with `[No file changes.]`,
  has no `Delta patch captured` line, and the project's dirty files are exactly
  as they were.

  Not async: it shares the guarded Repo launch pattern of
  `pass70_saved_turn_test.exs` (global application state).
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 180_000
  @moduletag :capture_log

  alias SwarmCode.Daemon.RepoLauncher
  alias SwarmCode.Domain.{Cache, Conversations, Engine, Projects, Providers, Settings}
  alias SwarmCode.Test.LoopbackHTTP, as: HTTP

  @marker "CLI020-NOOP-TASK"

  setup_all do
    SwarmCode.Domain.TestGlobalDir.isolate!()

    old_llm = Application.get_env(:swarm_code_daemon, :llm_providers)

    Application.put_env(:swarm_code_daemon, :llm_providers, %{
      "openai_compatible" => SwarmCode.Domain.LLM.OpenAI
    })

    on_exit(fn ->
      if old_llm,
        do: Application.put_env(:swarm_code_daemon, :llm_providers, old_llm),
        else: Application.delete_env(:swarm_code_daemon, :llm_providers)
    end)

    source = SchemaFixture.database!(:current, SwarmCode.Daemon.Test.LeaseFixture.build_root())
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
           process_start_id: "cli020-dirty-tree",
           boot_id: "cli020-dirty-tree"
         }}
      end
    ]

    {:ok, launcher} = RepoLauncher.start_link(boot_config: boot, pool_size: 3)
    Process.unlink(launcher)
    {:ok, _repo} = RepoLauncher.await_ready(launcher, 90_000)
    on_exit(fn -> :ok = RepoLauncher.close(launcher) end)

    %{root: root}
  end

  for backend <- ["worktree", "clone"] do
    test "a worker that changes nothing reports no changes (#{backend})", c do
      report = run_noop_worker(c.root, unquote(backend))

      assert report =~ "\n\n[No file changes.]",
             "no [No file changes.] note: " <> String.slice(report, -400, 400)

      refute report =~ "Changes on branch"
    end

    # The contract's full assertion (00_contract.md A9). Desktop 4c7c577
    # appended "Delta patch captured: 0 bytes, 0 files changed" after the
    # note; lane F (F4) adds it only when the patch has bytes, and A'1 synced
    # that (7b8f379f), so the strict form runs.
    test "the report ends with [No file changes.] and no delta line (#{backend})", c do
      report = run_noop_worker(c.root, unquote(backend))

      assert String.ends_with?(String.trim_trailing(report), "[No file changes.]"),
             "the worker report does not end with [No file changes.]: " <>
               String.slice(report, -400, 400)

      refute report =~ "Delta patch captured"
    end
  end

  defp run_noop_worker(root, backend) do
    Cache.clear()
    {:ok, _settings} = Settings.update(%{worktrees_enabled: true, isolation_backend: backend})
    project_root = dirty_project!(root, backend)
    before = project_state(project_root)

    on_exit(fn ->
      Engine.stop_all()
      eventually(fn -> Engine.running_run_ids() == [] end, 30_000)

      # The run-end isolation cleanups (`schedule_cleanup/2`, the
      # finalization) write to the Repo; they finish before the module's
      # guarded Repo closes.
      for supervisor <- [
            SwarmCode.Domain.Engine.CleanupSupervisor,
            SwarmCode.Domain.TaskSupervisor
          ] do
        eventually(fn -> Task.Supervisor.children(supervisor) == [] end, 10_000)
      end

      Cache.clear()
    end)

    {:ok, project} = Projects.create(%{name: "Dirty #{backend}", root_path: project_root})
    {:ok, project} = Projects.trust(project)

    test = self()

    server =
      HTTP.start(fn socket, request, _turn ->
        body = Jason.decode!(request.body)
        messages = body["messages"] || []
        last = List.last(messages) || %{}

        cond do
          last["role"] == "tool" ->
            send(test, {:worker_report, IO.iodata_to_binary(content(last["content"]))})
            answer(socket, %{"content" => "Lead done."}, false)

          Enum.any?(messages, &(&1["role"] == "user" and content(&1["content"]) =~ @marker)) ->
            answer(socket, %{"content" => "Nothing to change."}, false)

          true ->
            answer(
              socket,
              tool_call("s1", "spawn_agent", %{
                "name" => "noop",
                "task" => @marker <> ": reply with one sentence and change no file."
              }),
              true
            )
        end
      end)

    on_exit(fn -> HTTP.stop(server) end)
    conversation = conversation!(project, server)

    assert {:ok, run_id} = Engine.start_swarm(conversation, "coordinate one helper")
    assert_receive {:worker_report, report}, 60_000

    assert eventually(
             fn -> Conversations.get_run(run_id).status in ["done", "failed"] end,
             60_000
           )

    assert project_state(project_root) == before
    report
  end

  # -- helpers ----------------------------------------------------------------

  # A committed a.txt, b.txt and c.txt; then a.txt modified, b.txt modified and
  # staged, wip.txt untracked: three dirty files.
  defp dirty_project!(root, backend) do
    dir = Path.join(root, "dirty-#{backend}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    git!(dir, ["init", "-q"])
    for name <- ~w(a b c), do: File.write!(Path.join(dir, name <> ".txt"), name <> "\n")
    git!(dir, ["add", "-A"])

    git!(dir, [
      "-c",
      "user.name=cli020",
      "-c",
      "user.email=cli020@example.com",
      "-c",
      "commit.gpgsign=false",
      "commit",
      "-q",
      "-m",
      "base"
    ])

    File.write!(Path.join(dir, "a.txt"), "a, modified by the user\n")
    File.write!(Path.join(dir, "b.txt"), "b, staged by the user\n")
    git!(dir, ["add", "b.txt"])
    File.write!(Path.join(dir, "wip.txt"), "the user's work in progress\n")
    dir
  end

  defp project_state(dir) do
    files =
      for name <- ~w(a.txt b.txt c.txt wip.txt),
          into: %{},
          do: {name, File.read!(Path.join(dir, name))}

    {files, git!(dir, ["status", "--porcelain"])}
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
    out
  end

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
      Conversations.update(conversation, %{
        chat_provider_id: provider.id,
        chat_model: "fixture",
        swarm_provider_id: provider.id,
        swarm_model: "fixture"
      })

    conversation
  end

  defp content(text) when is_binary(text), do: text
  defp content(parts) when is_list(parts), do: Enum.map(parts, &(&1["text"] || ""))
  defp content(_), do: ""

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

  defp eventually(fun, timeout) do
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
          receive do
          after
            25 -> poll(fun, deadline)
          end
        end
    end
  end
end
