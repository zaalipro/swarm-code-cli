defmodule SwarmCode.Daemon.Service.Pass70QaQueueTest do
  @moduledoc """
  pass70 Q3, found driving the release: Tab (and Alt-Enter, and `/queue`)
  while a turn ran always answered "Command rejected: not allowed", because
  the service neither advertised nor accepted a queued dispatch. A queued
  prompt now waits on the conversation's own `queued` list (the desktop's)
  and starts when the running chat turn ends.
  """
  use ExUnit.Case, async: false
  alias SwarmCode.Daemon.Service.PersistedBackend, as: Backend
  alias SwarmCode.Domain.{Cache, Conversations, Engine, Projects, Providers, Repo}
  alias SwarmCode.Protocol.{Scope, ServiceRequest}
  alias SwarmCode.Test.LoopbackHTTP, as: HTTP
  alias SwarmCodeCLI.UI.DataSource.DTO

  setup_all do
    path = Path.join(System.tmp_dir!(), "pass70-queue-#{System.unique_integer([:positive])}")
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

    {:ok, project} = Projects.create(%{name: "Queue", root_path: root})
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
        name: "queue-#{c.conversation.id}",
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

  defp queue_request(text, refs \\ []),
    do: %ServiceRequest{
      operation: :dispatch_send,
      timeout_ms: 5000,
      params: %{
        "action" => "queue",
        "text" => text,
        "target" => %{"kind" => "main", "id" => nil},
        "attachment_refs" => refs
      }
    }

  test "a prompt queued behind a running turn starts when that turn ends", c do
    {run, approval} = start_turn(c, "touch pass70-queued.txt")
    assert Engine.chat_running?(c.conversation.id)

    {:ok, %{"value" => workspace}} = query(c.backend, c.scope, "workspace")
    assert "queue" in workspace["allowed_actions"]
    # pass71 S5: the queue count rides on the workspace metadata.
    assert workspace["queued"] == 0

    assert {:ok, %{"value" => %{"status" => "accepted", "feedback" => %{"text" => words}}}} =
             request(c.backend, "queue", c.scope, queue_request("And then say hello"))

    assert words =~ "Queued"
    assert Conversations.get(c.conversation.id).queued == ["And then say hello"]
    # Nothing new started while the first turn waits.
    assert length(Conversations.list_runs(c.conversation.id)) == 1

    assert eventually(fn -> queued_count(c) == 1 end)

    assert {:ok, %{"value" => %{"status" => "accepted"}}} =
             resolve(c, "approve", run, approval, "approve")

    assert eventually(fn -> Conversations.get_run(run).status == "done" end)

    assert eventually(fn ->
             Enum.any?(
               Conversations.list_runs(c.conversation.id),
               &(&1.prompt == "And then say hello")
             )
           end)

    assert Conversations.get(c.conversation.id).queued == []
    assert eventually(fn -> queued_count(c) == 0 end)
  end

  # pass71 F8: a refused start put the prompt back and armed nothing, so it
  # waited for ever (the flake S saw under load). It is retried, then the
  # user is told, and the prompt stays queued.
  test "a queued prompt whose start is refused is retried, then reported", c do
    {:ok, conversation} = Conversations.set_queued(c.conversation, ["Never starts"])
    # No provider: every start is refused with :not_configured.
    {:ok, _} = Conversations.update(conversation, %{chat_provider_id: nil, chat_model: nil})
    refute Engine.chat_running?(c.conversation.id)

    send(c.backend, {:drain_queue, c.conversation.id})

    assert eventually(fn -> :sys.get_state(c.backend).queue_retries > 0 end)
    assert eventually(fn -> :sys.get_state(c.backend).queue_retries == 0 end)
    assert Conversations.get(c.conversation.id).queued == ["Never starts"]
    assert Conversations.list_runs(c.conversation.id) == []
  end

  test "with no turn running, a queued prompt is an ordinary send", c do
    {_run, approval} = start_turn(c, "touch pass70-first.txt")
    run = approval["run_id"]
    assert {:ok, _} = resolve(c, "deny", run, approval, "deny_stop")
    assert eventually(fn -> not Engine.chat_running?(c.conversation.id) end)

    assert {:ok, %{"value" => %{"status" => "accepted", "identifiers" => [started]}}} =
             request(c.backend, "queue-now", c.scope, queue_request("Right away"))

    assert Conversations.get_run(started).prompt == "Right away"
    assert Conversations.get(c.conversation.id).queued == []
  end

  # pass73 T3/T8 (the owner's rule replaces pass70's "a slash command is never
  # queued"): a command sent to the queue waits for the turn like a prompt.
  test "a slash command sent to the queue waits for the running turn", c do
    {_run, _approval} = start_turn(c, "touch pass70-slash.txt")

    assert {:ok, %{"value" => %{"status" => "accepted", "disposition" => "queued"}}} =
             request(c.backend, "queue-slash", c.scope, queue_request("/model fixture"))

    assert Conversations.get(c.conversation.id).queued == ["/model fixture"]
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

  defp queued_count(c) do
    {:ok, %{"value" => workspace}} = query(c.backend, c.scope, "workspace")
    {:ok, %DTO.WorkspaceSnapshot{queued: queued}} = DTO.WorkspaceSnapshot.decode(workspace)
    queued
  end

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
