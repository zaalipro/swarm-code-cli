defmodule SwarmCode.Daemon.Service.Pass70ApprovalTest do
  @moduledoc """
  pass70 C2 (rel F2, ux M1): a real RunServer parks a `run_command` on its
  **op** node; the persisted backend projects the approval card and admits the
  decision against that op node. Before this, every real approval was rejected
  because only agent nodes were admitted.
  """
  use ExUnit.Case, async: false
  alias SwarmCode.Daemon.Service.PersistedBackend, as: Backend
  alias SwarmCode.Domain.{Cache, Conversations, Engine, Projects, Providers, Repo}
  alias SwarmCode.Protocol.{Scope, ServiceRequest}
  alias SwarmCode.Test.LoopbackHTTP, as: HTTP
  alias SwarmCodeCLI.UI.DataSource.DTO

  setup_all do
    path = Path.join(System.tmp_dir!(), "pass70-approval-#{System.unique_integer([:positive])}")
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

    {:ok, project} = Projects.create(%{name: "Approvals", root_path: root})
    # `auto` asks for every shell command that is not read-only (`touch` is
    # `:normal`, `echo` would be `:safe` and run unasked), and the synced
    # engine creates new projects read-only, so the mode is explicit.
    {:ok, project} = Projects.update(project, %{approval_mode: "auto"})
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

  defp command_server(command) do
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
                  "name" => "run_command",
                  "arguments" =>
                    Jason.encode!(%{
                      "command" => command,
                      "justification" => "Print a marker for the test."
                    })
                }
              }
            ]
          }
        else
          %{"content" => "Command finished."}
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

  defp start_turn(c, command) do
    server = command_server(command)
    on_exit(fn -> HTTP.stop(server) end)

    {:ok, provider} =
      Providers.create(%{
        name: "approval-#{c.conversation.id}",
        kind: "openai_compatible",
        base_url: server.url <> "/v1",
        models: ["fixture"],
        default_model: "fixture"
      })

    {:ok, _} =
      Conversations.update(c.conversation, %{chat_provider_id: provider.id, chat_model: "fixture"})

    assert {:ok, %{"value" => %{"status" => "accepted", "identifiers" => [run]}}} =
             request(c.backend, "prompt", c.scope, send_request("Run the marker command"))

    assert eventually(fn -> pending(c) != [] end)
    [approval] = pending(c)
    {run, approval}
  end

  defp pending(c) do
    {:ok, %{"value" => %{"items" => items}}} = query(c.backend, c.scope, "pending")
    Enum.filter(items, &(&1["kind"] == "approval"))
  end

  defp resolve(c, id, run, approval, decision, node \\ nil) do
    request(c.backend, id, c.scope, %ServiceRequest{
      operation: :approval_resolve,
      timeout_ms: 5000,
      params: %{
        "run_id" => run,
        "node_id" => node || approval["node_id"],
        "interaction_id" => approval["id"],
        "expected_revision" => approval["expected_revision"],
        "decision" => decision
      }
    })
  end

  test "a real op-node approval is projected as a card and approving it finishes the run", c do
    {run, approval} = start_turn(c, "touch pass70-approved.txt")

    assert {:ok, %DTO.PendingInteraction{approval: %DTO.Approval{} = card}} =
             DTO.PendingInteraction.decode(approval)

    # The waiting node is the run_command op, not the run's agent.
    agents = Conversations.list_nodes(run) |> Enum.filter(&(&1.kind == "agent"))
    op = Enum.find(Conversations.list_nodes(run), &(&1.id == approval["node_id"]))
    assert %{kind: "op", op_type: "run_command"} = op
    refute approval["node_id"] in Enum.map(agents, & &1.id)

    assert {card.tool, card.permission, card.command} ==
             {"run_command", :execute, "touch pass70-approved.txt"}

    assert {card.cwd, card.reason} == {".", "Print a marker for the test."}
    assert card.agent_id == op.parent_id
    assert is_integer(card.requested_at)
    assert :approve in card.allowed_decisions and :deny_stop in card.allowed_decisions

    # An agent's id is not the request's node: the exact op is required.
    assert {:ok, %{"value" => %{"status" => "rejected"}}} =
             resolve(c, "wrong-node", run, approval, "approve", hd(agents).id)

    assert {:ok, %{"value" => %{"status" => "accepted", "identifiers" => [^run]}}} =
             resolve(c, "approve", run, approval, "approve")

    assert eventually(fn -> Conversations.get_run(run).status == "done" end)
    assert pending(c) == []
  end

  test "deny and stop settles the request, stops the run and leaves no waiting words", c do
    {run, approval} = start_turn(c, "touch pass70-denied.txt")

    assert {:ok, %{"value" => %{"status" => "accepted"}}} =
             resolve(c, "deny-stop", run, approval, "deny_stop")

    assert eventually(fn -> Conversations.get_run(run).status in ["stopped", "done"] end)
    assert eventually(fn -> pending(c) == [] end)

    {:ok, %{"value" => workspace}} = query(c.backend, c.scope, "workspace")

    refute Enum.any?(workspace["transcript"]["items"], fn item ->
             item["text"] =~ "awaiting approval" or
               (is_map(item["tool"]) and item["tool"]["detail"] =~ "awaiting approval")
           end)
  end

  test "a run stopped while it waits no longer reads awaiting approval (rel F11)", c do
    {run, _approval} = start_turn(c, "touch pass70-stopped.txt")

    assert {:ok, %{"value" => %{"status" => "accepted"}}} =
             request(c.backend, "stop", c.scope, %ServiceRequest{
               operation: :run_control,
               timeout_ms: 5000,
               params: %{"run_id" => run, "action" => "stop"}
             })

    assert eventually(fn -> Conversations.get_run(run).status == "stopped" end)
    assert eventually(fn -> pending(c) == [] end)

    op = Enum.find(Conversations.list_nodes(run), &(&1.op_type == "run_command"))
    {:ok, %{"value" => workspace}} = query(c.backend, c.scope, "workspace")
    item = Enum.find(workspace["transcript"]["items"], &(&1["id"] == op.id))

    assert item["state"] in ["stopped", "failed", "done"]
    refute item["text"] =~ "awaiting"
    refute item["tool"]["detail"] =~ "awaiting"
  end

  test "always allowing a command family remembers it on the project", c do
    {run, approval} = start_turn(c, "touch pass70-family.txt")
    card = approval["approval"]

    assert {card["command_family"], card["classification"]} == {"touch", "normal"}
    assert "always_prefix" in card["allowed_decisions"]

    assert {:ok, %{"value" => %{"status" => "accepted"}}} =
             resolve(c, "prefix", run, approval, "always_prefix")

    assert eventually(fn -> Conversations.get_run(run).status == "done" end)
    assert "touch" in Projects.get(c.project.id).auto_approve_prefixes
  end

  test "a dangerous command offers no family and refuses always_prefix", c do
    {run, approval} = start_turn(c, "rm -rf pass70-build")
    card = approval["approval"]

    assert {card["command_family"], card["classification"]} == {nil, "dangerous"}
    refute "always_prefix" in card["allowed_decisions"]

    assert {:ok, %{"value" => %{"status" => "rejected", "error" => %{"code" => "not_allowed"}}}} =
             resolve(c, "prefix", run, approval, "always_prefix")

    assert {:ok, %{"value" => %{"status" => "accepted"}}} =
             resolve(c, "deny", run, approval, "deny")

    assert eventually(fn -> Conversations.get_run(run).status == "done" end)
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
