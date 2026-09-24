defmodule SwarmCode.Daemon.Service.Pass73SendRoutingTest do
  @moduledoc """
  pass73 T3/T8: "the whole point of SwarmCode is that everything you send
  happens asynchronously". With a chat turn running (waiting on an approval):
  a plain message steers it, `/compact` waits on the queue, `/plan <task>`
  starts a run at once, and a refusal that remains says why in words. Every
  outcome names where the send went (`disposition`) and decodes on the client.
  """
  use ExUnit.Case, async: false
  alias SwarmCode.Daemon.Service.PersistedBackend, as: Backend
  alias SwarmCode.Domain.{Cache, Conversations, Engine, Projects, Providers, Repo}
  alias SwarmCode.Protocol.{Scope, ServiceRequest}
  alias SwarmCode.Test.LoopbackHTTP, as: HTTP
  alias SwarmCodeCLI.UI.DataSource.DTO

  setup_all do
    path = Path.join(System.tmp_dir!(), "pass73-route-#{System.unique_integer([:positive])}")
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

    {:ok, project} = Projects.create(%{name: "Route", root_path: root})
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

  # The first model call asks to run `command` (auto asks, so the turn waits
  # on an approval); every later call answers in words.
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

  defp start_turn(c, command) do
    server = command_server(command)
    on_exit(fn -> HTTP.stop(server) end)

    {:ok, provider} =
      Providers.create(%{
        name: "route-#{c.conversation.id}",
        kind: "openai_compatible",
        base_url: server.url <> "/v1",
        models: ["fixture"],
        default_model: "fixture"
      })

    {:ok, _} =
      Conversations.update(c.conversation, %{chat_provider_id: provider.id, chat_model: "fixture"})

    assert {:ok, %{"value" => %{"status" => "accepted", "identifiers" => [run]}}} =
             request(c, "first", send_request("Run the marker command"))

    assert eventually(fn -> pending(c) != [] end)
    [approval] = pending(c)
    {run, approval}
  end

  test "a plain message while the chat turn runs steers that turn", c do
    {run, approval} = start_turn(c, "touch pass73-steer.txt")
    assert_receive {:http_request, 1, _}, 5_000

    assert {:ok, %{"value" => value}} = request(c, "steer", send_request("Also count the lines"))
    assert %{"status" => "accepted", "disposition" => "steered", "identifiers" => [^run]} = value
    assert value["feedback"]["text"] == "Sent to the running turn."
    assert {:ok, %DTO.Outcome{disposition: :steered}} = DTO.Outcome.decode(value)

    # No second turn: the message belongs to the running one.
    assert [%{id: ^run}] = Conversations.list_runs(c.conversation.id)

    assert Enum.any?(Conversations.list_messages(c.conversation.id), fn m ->
             m.role == "user" and m.content == "Also count the lines" and m.run_id == run and
               m.reply_to_run_id == run
           end)

    # The transcript marks it as taken in by the running turn.
    {:ok, %{"value" => workspace}} = query(c, "workspace")
    items = workspace["transcript"]["items"]
    steered = Enum.find(items, &(&1["text"] == "Also count the lines"))
    assert steered["target_kind"] == "steer" and steered["target_id"] == run

    # The model reads it on the turn's next call.
    assert {:ok, _} = resolve(c, run, approval, "approve")
    assert_receive {:http_request, 2, next_call}, 10_000
    assert next_call.body =~ "Also count the lines"
  end

  test "/compact while the chat turn runs waits on the queue, then runs", c do
    {run, approval} = start_turn(c, "touch pass73-compact.txt")

    assert {:ok, %{"value" => value}} = request(c, "compact", send_request("/compact"))
    assert %{"status" => "accepted", "disposition" => "queued"} = value
    assert value["feedback"]["text"] == "Queued · sends after the running turn"
    assert Conversations.get(c.conversation.id).queued == ["/compact"]
    assert [%{id: ^run}] = Conversations.list_runs(c.conversation.id)

    # The terminal can show what waits, not only how many.
    {:ok, %{"value" => workspace}} = query(c, "workspace")

    assert {:ok, %DTO.WorkspaceSnapshot{queued: 1, queued_texts: ["/compact"]}} =
             DTO.WorkspaceSnapshot.decode(workspace)

    assert {:ok, _} = resolve(c, run, approval, "approve")

    assert eventually(fn ->
             Enum.any?(Conversations.list_runs(c.conversation.id), &(&1.kind == "compact"))
           end)

    assert Conversations.get(c.conversation.id).queued == []
  end

  test "/plan with a task starts a planner run at once beside the live turn", c do
    {run, _approval} = start_turn(c, "touch pass73-plan.txt")

    assert {:ok, %{"value" => value}} =
             request(c, "plan", send_request("/plan audit the retry path"))

    assert %{"status" => "accepted", "disposition" => "started", "identifiers" => [planner]} =
             value

    refute planner == run
    assert Conversations.get_run(planner).mode == "plan"
    assert Conversations.get_run(planner).prompt == "audit the retry path"
    # The conversation keeps its own mode; only that run plans.
    assert Conversations.get(c.conversation.id).mode in [nil, "build"]
    assert Engine.chat_running?(c.conversation.id)
  end

  test "a refusal that remains says why and what to do", c do
    assert {:ok, %{"value" => %{"reason" => %{"code" => "not_configured", "text" => said}}}} =
             request(c, "unconfigured", send_request("/compact"))

    assert said =~ "choose one with /model"
    configure(c)

    for {text, code, words} <- [
          {"/compact", "nothing_to_compact", "Nothing to compact yet"},
          {"/swarm", "missing_argument", "/swarm needs <task>."},
          {"/nosuch thing", "unknown_command", "There is no /nosuch; /help lists the commands."},
          {"/review now", "unexpected_argument", "/review takes no argument"}
        ] do
      assert {:ok, %{"value" => value}} = request(c, "refused-" <> code, send_request(text))
      assert %{"status" => "rejected", "reason" => %{"code" => ^code, "text" => said}} = value
      assert said =~ words

      assert {:ok, %DTO.Outcome{status: :rejected, reason: %DTO.Refusal{code: ^code}}} =
               DTO.Outcome.decode(value)
    end
  end

  test "a plain message with nothing running starts its turn", c do
    {run, approval} = start_turn(c, "touch pass73-idle.txt")
    assert {:ok, _} = resolve(c, run, approval, "deny_stop")
    assert eventually(fn -> not Engine.chat_running?(c.conversation.id) end)

    assert {:ok, %{"value" => %{"disposition" => "started", "identifiers" => [started]}}} =
             request(c, "idle", send_request("Say hello"))

    assert Conversations.get_run(started).prompt == "Say hello"
  end

  # The in-memory response cache refused every command past its 4,096th.
  test "the 4,097th command of a session is not refused", c do
    configure(c)

    :sys.replace_state(c.backend, fn state ->
      ids = for n <- 1..4096, do: "cached-#{n}"

      %{
        state
        | requests: Map.new(ids, &{&1, {"fingerprint", {:ok, %{}}}}),
          request_order: :queue.from_list(ids)
      }
    end)

    assert {:ok, %{"value" => %{"status" => "rejected", "reason" => %{"code" => code}}}} =
             request(c, "one-more", send_request("/compact"))

    assert code == "nothing_to_compact"
    state = :sys.get_state(c.backend)
    assert map_size(state.requests) == 4096
    refute Map.has_key?(state.requests, "cached-1")
  end

  defp configure(c) do
    {:ok, provider} =
      Providers.create(%{
        name: "idle-#{c.conversation.id}",
        kind: "openai_compatible",
        base_url: "http://127.0.0.1:9/v1",
        models: ["fixture"],
        default_model: "fixture"
      })

    {:ok, _} =
      Conversations.update(c.conversation, %{chat_provider_id: provider.id, chat_model: "fixture"})
  end

  defp pending(c) do
    {:ok, %{"value" => %{"items" => items}}} = query(c, "pending")
    Enum.filter(items, &(&1["kind"] == "approval"))
  end

  defp resolve(c, run, approval, decision) do
    request(c, "resolve-#{decision}", %ServiceRequest{
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

  defp request(c, id, request),
    do: GenServer.call(c.backend, {:service_request, id(id), c.scope, request}, 10_000)

  defp query(c, slot),
    do:
      request(c, "query-#{System.unique_integer([:positive])}", %ServiceRequest{
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

  defp id(name), do: "#{name}-#{System.unique_integer([:positive])}"

  defp eventually(fun, tries \\ 200) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        receive do
        after
          25 -> eventually(fun, tries - 1)
        end
    end
  end
end
