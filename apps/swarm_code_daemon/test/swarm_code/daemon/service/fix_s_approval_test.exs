defmodule SwarmCode.Daemon.Service.FixSApprovalTest do
  @moduledoc """
  cli020 fix round, lane S:

    * S1: `ncode -p --approval <mode>` (the backend's `approval_mode` option)
      also governs a prompt or command drained from the queue
      (`PersistedBackend.start_queued`), not only the sends the session makes.
    * S3: picking an approval mode by hand marks an untrusted project trusted
      (the desktop's `set_approval_mode`), and the notice says so.
  """
  use ExUnit.Case, async: false
  alias SwarmCode.Daemon.Service.PersistedBackend, as: Backend
  alias SwarmCode.Domain.{Cache, Conversations, Engine, Projects, Providers, Repo}
  alias SwarmCode.Protocol.{Scope, ServiceRequest}
  alias SwarmCode.Test.LoopbackHTTP, as: HTTP

  setup_all do
    path = Path.join(System.tmp_dir!(), "cli020-fix-s-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    prior = Application.get_env(:swarm_code_daemon, :domain_config_dir)
    old_llm = Application.get_env(:swarm_code_daemon, :llm_providers)

    Application.put_env(:swarm_code_daemon, :llm_providers, %{
      "openai_compatible" => SwarmCode.Domain.LLM.OpenAI
    })

    Application.put_env(:swarm_code_daemon, :domain_config_dir, Path.join(path, "config"))

    on_exit(fn ->
      Cache.clear()

      if old_llm,
        do: Application.put_env(:swarm_code_daemon, :llm_providers, old_llm),
        else: Application.delete_env(:swarm_code_daemon, :llm_providers)

      if prior,
        do: Application.put_env(:swarm_code_daemon, :domain_config_dir, prior),
        else: Application.delete_env(:swarm_code_daemon, :domain_config_dir)

      File.rm_rf!(path)
    end)

    unless Process.whereis(SwarmCode.Domain.Hooks.TaskSupervisor),
      do: start_supervised!({Task.Supervisor, name: SwarmCode.Domain.Hooks.TaskSupervisor})

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

    %{path: path}
  end

  # A fresh project (untrusted, read-only, as the synced engine creates it)
  # with one conversation and a backend over it.
  defp session(c, opts \\ []) do
    root = Path.join(c.path, "project-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    {:ok, project} = Projects.create(%{name: "Fix S", root_path: root})

    project =
      if opts[:trusted] do
        {:ok, project} = Projects.trust(project)
        {:ok, project} = Projects.update(project, %{approval_mode: "read_only"})
        project
      else
        project
      end

    {:ok, conv} = Conversations.create(project.id)
    on_exit(fn -> Engine.stop_all(conv.id) end)

    backend_opts =
      [
        mode: :persisted,
        repo: Repo,
        project_root: root,
        project_id: project.id,
        conversation_id: conv.id,
        source_epoch: Ecto.UUID.generate()
      ] ++ Keyword.take(opts, [:approval_mode])

    backend =
      start_supervised!({Backend, backend_opts}, id: {:backend, System.unique_integer()})

    %{
      backend: backend,
      project: project,
      conversation: conv,
      root: root,
      scope: %Scope{kind: :conversation, id: conv.id, generation: 3}
    }
  end

  defp write_server(path) do
    HTTP.start(fn socket, _request, turn ->
      delta =
        if turn == 1 do
          call = %{
            "index" => 0,
            "id" => "call-1",
            "type" => "function",
            "function" => %{
              "name" => "write_file",
              "arguments" => Jason.encode!(%{"path" => path, "content" => "hello\n"})
            }
          }

          %{"tool_calls" => [call]}
        else
          %{"content" => "Done."}
        end

      finish = if turn == 1, do: "tool_calls", else: "stop"

      HTTP.stream(socket, [
        HTTP.sse(%{"choices" => [%{"index" => 0, "delta" => delta, "finish_reason" => finish}]})
      ])
    end)
  end

  defp with_provider(s, path) do
    server = write_server(path)
    on_exit(fn -> HTTP.stop(server) end)

    {:ok, provider} =
      Providers.create(%{
        name: "fix-s-#{s.conversation.id}",
        kind: "openai_compatible",
        base_url: server.url <> "/v1",
        models: ["fixture"],
        default_model: "fixture"
      })

    {:ok, conv} =
      Conversations.update(s.conversation, %{chat_provider_id: provider.id, chat_model: "fixture"})

    %{s | conversation: conv}
  end

  defp project_update(s, params),
    do:
      GenServer.call(
        s.backend,
        {:service_request, "u-#{System.unique_integer([:positive])}", s.scope,
         %ServiceRequest{
           operation: :project_update,
           timeout_ms: 5000,
           params: Map.merge(%{"approval_mode" => nil, "trusted" => nil}, params)
         }},
        10_000
      )

  defp drain(s, text) do
    {:ok, _} = Conversations.set_queued(s.conversation, [text])
    send(s.backend, {:drain_queue, s.conversation.id})
  end

  describe "S1: --approval reaches what the queue starts" do
    test "a queued prompt writes without asking in an --approval auto session", c do
      s = c |> session(trusted: true, approval_mode: "auto") |> with_provider("queued.txt")

      drain(s, "Write the file")

      assert eventually(fn -> File.exists?(Path.join(s.root, "queued.txt")) end)
      assert File.read!(Path.join(s.root, "queued.txt")) == "hello\n"
      assert Projects.get(s.project.id).approval_mode == "read_only"
    end

    test "a queued slash command that starts a turn takes the session's mode too", c do
      s = c |> session(trusted: true, approval_mode: "auto") |> with_provider("review.txt")

      drain(s, "/review")

      assert eventually(fn -> File.exists?(Path.join(s.root, "review.txt")) end)
      assert Projects.get(s.project.id).approval_mode == "read_only"
    end

    test "the dispatcher takes the session's mode as an option, and only a real mode", c do
      s = session(c, trusted: true)

      dispatch =
        &SwarmCode.Daemon.Service.CommandDispatcher.dispatch(s.conversation.id, "/help", &1)

      assert {:ok, %{type: :report}} = dispatch.(approval_mode: "auto")
      assert {:error, :invalid_request} = dispatch.(approval_mode: "yolo")
      assert {:error, :invalid_request} = dispatch.(approval_mode: :auto)
      assert {:error, :invalid_request} = dispatch.(approval_mode: "auto", approval_mode: "auto")
    end

    test "without --approval the queued prompt keeps the project's mode and asks", c do
      s = c |> session(trusted: true) |> with_provider("asks.txt")

      drain(s, "Write the file")

      assert eventually(fn ->
               match?([_ | _], Conversations.list_runs(s.conversation.id))
             end)

      assert eventually(fn -> pending_approvals(s) != [] end)
      refute File.exists?(Path.join(s.root, "asks.txt"))
    end
  end

  describe "S3: a manual mode pick marks the project trusted, and says so" do
    test "project.update to auto on an untrusted project trusts it", c do
      s = session(c)
      refute Projects.trusted?(Projects.get(s.project.id))

      assert {:ok, %{"value" => %{"status" => "accepted", "feedback" => feedback}}} =
               project_update(s, %{"approval_mode" => "auto"})

      assert feedback["text"] == "Approvals: read-only → auto · this project is now trusted"
      project = Projects.get(s.project.id)
      assert {project.approval_mode, Projects.trusted?(project)} == {"auto", true}
    end

    test "on a trusted project the notice is unchanged and nothing is announced twice", c do
      s = session(c, trusted: true)

      assert {:ok, %{"value" => %{"feedback" => %{"text" => "Approval mode: auto"}}}} =
               project_update(s, %{"approval_mode" => "auto"})

      assert {:ok, %{"value" => %{"feedback" => %{"text" => "Approval mode: full access"}}}} =
               project_update(s, %{"approval_mode" => "full_access"})
    end

    test "/approval auto in an untrusted project says the same", c do
      s = session(c)

      assert {:ok, %{text: "Approvals: read-only → auto · this project is now trusted"}} =
               SwarmCode.Daemon.Service.CommandDispatcher.dispatch(
                 s.conversation.id,
                 "/approval auto"
               )

      assert Projects.trusted?(Projects.get(s.project.id))
    end
  end

  defp pending_approvals(s) do
    {:ok, %{"value" => %{"items" => items}}} =
      GenServer.call(
        s.backend,
        {:service_request, "q-#{System.unique_integer([:positive])}", s.scope,
         %ServiceRequest{
           operation: :query,
           timeout_ms: 5000,
           params: %{
             "slot" => "pending",
             "cursor" => nil,
             "direction" => "before",
             "page_size" => 50,
             "byte_limit" => 1_048_576
           }
         }},
        10_000
      )

    Enum.filter(items, &(&1["kind"] == "approval"))
  end

  defp eventually(fun, n \\ 300)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, n) do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, n - 1)
    end
  end
end
