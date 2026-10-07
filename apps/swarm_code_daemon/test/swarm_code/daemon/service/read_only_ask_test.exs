defmodule SwarmCode.Daemon.Service.ReadOnlyAskTest do
  @moduledoc """
  cli020 A'2 (ux-live-5, F1): in a read-only project a write is asked about
  with the approval card (y once / d deny), not refused. The card offers
  approve, deny and deny_stop only and says which mode asked; approving
  writes the file, denying leaves it unwritten with "denied by user".
  """
  use ExUnit.Case, async: false
  alias SwarmCode.Daemon.Service.PersistedBackend, as: Backend
  alias SwarmCode.Domain.{Cache, Conversations, Engine, Projects, Providers, Repo}
  alias SwarmCode.Protocol.{Scope, ServiceRequest}
  alias SwarmCode.Test.LoopbackHTTP, as: HTTP
  alias SwarmCodeCLI.UI.DataSource.DTO

  setup_all do
    path =
      Path.join(System.tmp_dir!(), "cli020-read-only-ask-#{System.unique_integer([:positive])}")

    root = Path.join(path, "project")
    File.mkdir_p!(root)
    System.cmd("git", ["init", "-q", root])
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

    # Tool post-hooks run under this supervisor; the persisted runtime starts
    # it (owner B), a bare test does it here.
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

    {:ok, project} = Projects.create(%{name: "Read-only asks", root_path: root})
    # cli020 A'2: read-only asks for each write (F1) instead of refusing it.
    {:ok, project} = Projects.update(project, %{approval_mode: "read_only"})
    %{project: project, root: root}
  end

  setup c do
    # A remembered family ("touch") would approve the next test's command.
    {:ok, _} = Projects.update(Projects.get(c.project.id), %{auto_approve_prefixes: []})
    Cache.clear()
    {:ok, conv} = Conversations.create(c.project.id)

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

    %{
      backend: backend,
      conversation: conv,
      scope: %Scope{kind: :conversation, id: conv.id, generation: 3}
    }
  end

  defp write_server(path) do
    HTTP.start(fn socket, _request, turn ->
      delta =
        if turn == 1 do
          %{
            "tool_calls" => [
              %{
                "index" => 0,
                "id" => "call-1",
                "type" => "function",
                "function" => %{
                  "name" => "write_file",
                  "arguments" => Jason.encode!(%{"path" => path, "content" => "hello\n"})
                }
              }
            ]
          }
        else
          %{"content" => "Done."}
        end

      HTTP.stream(socket, [
        HTTP.sse(%{
          "choices" => [
            %{
              "index" => 0,
              "delta" => delta,
              "finish_reason" => if(turn == 1, do: "tool_calls", else: "stop")
            }
          ]
        })
      ])
    end)
  end

  defp start_turn(c, path) do
    server = write_server(path)
    on_exit(fn -> HTTP.stop(server) end)

    {:ok, provider} =
      Providers.create(%{
        name: "read-only-#{c.conversation.id}",
        kind: "openai_compatible",
        base_url: server.url <> "/v1",
        models: ["fixture"],
        default_model: "fixture"
      })

    {:ok, _} =
      Conversations.update(c.conversation, %{chat_provider_id: provider.id, chat_model: "fixture"})

    assert {:ok, %{"value" => %{"status" => "accepted", "identifiers" => [run]}}} =
             request(c.backend, "prompt", c.scope, send_request("Write the file"))

    assert eventually(fn -> pending(c) != [] end)
    [approval] = pending(c)
    {run, approval}
  end

  defp pending(c) do
    {:ok, %{"value" => %{"items" => items}}} = query(c.backend, c.scope, "pending")
    Enum.filter(items, &(&1["kind"] == "approval"))
  end

  defp resolve(c, id, run, approval, decision) do
    request(c.backend, id, c.scope, %ServiceRequest{
      operation: :approval_resolve,
      timeout_ms: 5000,
      params: %{
        "run_id" => run,
        "node_id" => approval["node_id"],
        "interaction_id" => approval["id"],
        "expected_revision" => approval["expected_revision"],
        "decision" => decision
      }
    })
  end

  test "a read-only write is one approval with y and d; approving writes the file", c do
    {run, approval} = start_turn(c, "ro-approved.txt")

    assert {:ok, %DTO.PendingInteraction{approval: %DTO.Approval{} = card}} =
             DTO.PendingInteraction.decode(approval)

    assert card.tool == "write_file"
    assert card.allowed_decisions == [:approve, :deny, :deny_stop]
    assert card.approval_mode == "read_only"
    refute File.exists?(Path.join(c.root, "ro-approved.txt"))

    assert {:ok, %{"value" => %{"status" => "accepted"}}} =
             resolve(c, "approve", run, approval, "approve")

    assert eventually(fn -> Conversations.get_run(run).status == "done" end)
    assert File.read!(Path.join(c.root, "ro-approved.txt")) == "hello\n"
  end

  test "a denied read-only write leaves the file unwritten: denied by user", c do
    {run, approval} = start_turn(c, "ro-denied.txt")

    assert {:ok, %{"value" => %{"status" => "accepted"}}} =
             resolve(c, "deny", run, approval, "deny")

    assert eventually(fn -> Conversations.get_run(run).status == "done" end)
    refute File.exists?(Path.join(c.root, "ro-denied.txt"))

    op = Enum.find(Conversations.list_nodes(run), &(&1.op_type == "write_file"))
    assert op.error =~ "denied by user"
  end

  # cli020 finisher (B23 + F8): `ncode -p --approval auto` starts the
  # backend with `approval_mode: "auto"`; its runs write without asking and
  # the project row keeps read_only.
  test "a session started with approval_mode auto writes without asking", c do
    root = Path.join(Path.dirname(c.root), "approval-override")
    File.mkdir_p!(root)
    {:ok, project} = Projects.create(%{name: "Approval override", root_path: root})
    {:ok, project} = Projects.trust(project)
    {:ok, project} = Projects.update(project, %{approval_mode: "read_only"})
    {:ok, conv} = Conversations.create(project.id)
    on_exit(fn -> Engine.stop_all(conv.id) end)

    backend =
      start_supervised!(
        {Backend,
         mode: :persisted,
         repo: Repo,
         project_root: root,
         project_id: project.id,
         conversation_id: conv.id,
         source_epoch: Ecto.UUID.generate(),
         approval_mode: "auto"},
        id: :approval_override_backend
      )

    c = %{c | backend: backend, conversation: conv}
    c = %{c | scope: %Scope{kind: :conversation, id: conv.id, generation: 3}}
    server = write_server("override.txt")
    on_exit(fn -> HTTP.stop(server) end)

    {:ok, provider} =
      Providers.create(%{
        name: "override-#{conv.id}",
        kind: "openai_compatible",
        base_url: server.url <> "/v1",
        models: ["fixture"],
        default_model: "fixture"
      })

    {:ok, _} = Conversations.update(conv, %{chat_provider_id: provider.id, chat_model: "fixture"})

    assert {:ok, %{"value" => %{"status" => "accepted", "identifiers" => [run]}}} =
             request(c.backend, "prompt", c.scope, send_request("Write the file"))

    assert eventually(fn -> Conversations.get_run(run).status == "done" end)
    assert File.read!(Path.join(root, "override.txt")) == "hello\n"
    assert pending(c) == []
    assert Projects.get(project.id).approval_mode == "read_only"
  end

  defp send_request(text),
    do: %ServiceRequest{
      operation: :dispatch_send,
      timeout_ms: 5000,
      params: %{
        "action" => "send",
        "text" => text,
        "target" => %{"kind" => "main", "id" => nil},
        "attachment_refs" => []
      }
    }

  defp request(backend, id, scope, request),
    do: GenServer.call(backend, {:service_request, id(id), scope, request}, 10_000)

  defp query(backend, scope, slot),
    do:
      request(backend, "query-#{System.unique_integer([:positive])}", scope, %ServiceRequest{
        operation: :query,
        timeout_ms: 5000,
        params: %{
          "slot" => slot,
          "cursor" => nil,
          "direction" => "before",
          "page_size" => 50,
          "byte_limit" => 1_048_576
        }
      })

  # The command ledger is durable per project: every test names its own.
  defp id(name), do: "#{name}-#{System.unique_integer([:positive])}"

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
