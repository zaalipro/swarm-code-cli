defmodule SwarmCode.Daemon.Service.PersistedBackendTest do
  use ExUnit.Case, async: false
  alias SwarmCode.Daemon.Service.PersistedBackend, as: Backend
  alias SwarmCode.Domain.{Cache, Conversations, Engine, Projects, Providers, Repo}
  alias SwarmCode.Protocol.{Scope, ServiceRequest}
  alias SwarmCode.Test.LoopbackHTTP, as: HTTP

  defmodule ApprovalOwner do
    use GenServer, restart: :temporary

    def start_link(opts),
      do:
        GenServer.start_link(__MODULE__, opts,
          name: SwarmCode.Domain.Engine.RunServer.via(opts.run, {opts.conversation, "chat"})
        )

    def init(opts), do: {:ok, opts}
    def handle_call(:pending_interactions, _, state), do: {:reply, state.items, state}
    def handle_call(:stop, _, state), do: {:stop, :normal, :ok, state}

    def handle_cast({:resolve_approval, node, decision}, state) do
      send(state.owner, {:approval_resolved, node, decision})
      {:noreply, state}
    end
  end

  setup_all do
    path = Path.join(System.tmp_dir!(), "persisted-backend-#{System.unique_integer([:positive])}")
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

    {:ok, project} = Projects.create(%{name: "Persisted", root_path: root})
    %{project: project, root: root}
  end

  setup c do
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
      opts: opts,
      conversation: conv,
      scope: %Scope{kind: :conversation, id: conv.id, generation: 3}
    }
  end

  test "requires explicit persistence and existing project membership", c do
    assert {:error, _} = Backend.start_link(Keyword.delete(c.opts, :mode))

    assert {:error, _} =
             Backend.start_link(Keyword.put(c.opts, :project_id, Ecto.UUID.generate()))

    assert {:error, %{"code" => "not_allowed"}} =
             query(c.backend, %{c.scope | id: Ecto.UUID.generate()}, "workspace")

    assert {:error, %{"code" => "not_allowed"}} =
             query(c.backend, %{c.scope | generation: -1}, "workspace")
  end

  test "slash mode dispatch is persisted and identities deduplicate", c do
    first = request(c.backend, "mode", c.scope, send_request("/plan"))
    assert {:ok, %{"value" => %{"status" => "accepted"}}} = first
    assert Conversations.get!(c.conversation.id).mode == "plan"
    assert request(c.backend, "mode", c.scope, send_request("/plan")) == first
    assert Conversations.get!(c.conversation.id).mode == "plan"

    assert {:ok, %{"value" => %{"error" => %{"code" => "request_conflict"}}}} =
             request(c.backend, "mode", c.scope, send_request("/ultra"))

    assert Conversations.list_messages(c.conversation.id) == []
  end

  test "staged image limit rejects the fifth image before creating another file", c do
    path = Path.join(c.root, "stage-cap.png")
    File.write!(path, <<137, "PNG", 13, 10, 26, 10>>)

    for index <- 1..4 do
      assert {:ok, %{"value" => %{"status" => "accepted"}}} =
               request(
                 c.backend,
                 "stage-#{index}",
                 c.scope,
                 send_request("/attach stage-cap.png")
               )
    end

    before = File.ls!(SwarmCode.Domain.Attachments.dir()) |> Enum.sort()

    assert {:ok, %{"value" => %{"status" => "rejected"}}} =
             request(c.backend, "stage-5", c.scope, send_request("/attach stage-cap.png"))

    assert File.ls!(SwarmCode.Domain.Attachments.dir()) |> Enum.sort() == before
  end

  test "staged image ids survive a backend restart and replay", c do
    path = Path.join(c.root, "restart-stage.png")
    File.write!(path, <<137, "PNG", 13, 10, 26, 10>>)

    first =
      request(c.backend, "stage-restart", c.scope, send_request("/attach restart-stage.png"))

    assert {:ok, %{"value" => %{"status" => "accepted", "identifiers" => [attachment_id]}}} =
             first

    stop_supervised!(Backend)

    restarted =
      start_supervised!({Backend, Keyword.put(c.opts, :source_epoch, Ecto.UUID.generate())})

    assert :sys.get_state(restarted).attachment_ids == [attachment_id]

    assert request(
             restarted,
             "stage-restart",
             %{c.scope | generation: 4},
             send_request("/attach restart-stage.png")
           ) == first

    assert :sys.get_state(restarted).attachment_ids == [attachment_id]
  end

  test "workspace metadata follows saved configuration, live mode changes and backend restart",
       c do
    {:ok, provider} =
      Providers.create(%{
        name: "metadata-#{c.conversation.id}",
        kind: "openai_compatible",
        base_url: "http://127.0.0.1:1/v1",
        api_key: "",
        default_model: "default-model",
        models: ["chat-model", "worker-model"]
      })

    {:ok, _} =
      Conversations.update(c.conversation, %{
        mode: "plan",
        chat_provider_id: provider.id,
        chat_model: "chat-model",
        swarm_provider_id: provider.id,
        swarm_model: "worker-model",
        effort: "high",
        swarm_effort: "low"
      })

    watch = %ServiceRequest{
      operation: :watch,
      timeout_ms: 1000,
      params: %{
        "watch_ref" => "metadata",
        "slot" => "workspace",
        "page_size" => 20,
        "byte_limit" => 262_144
      }
    }

    assert {:watch, 0, _, "workspace_snapshot", baseline} =
             GenServer.call(c.backend, {:service_watch, self(), "watch-metadata", c.scope, watch})

    assert baseline["mode"] == "plan"
    assert baseline["chat_model"] == "chat-model"
    assert baseline["swarm_model"] == "worker-model"
    assert baseline["effort"] == "high"
    send(c.backend, {:service_ready, self(), "metadata"})

    assert {:ok, %{"value" => %{"status" => "accepted"}}} =
             request(c.backend, "change-metadata", c.scope, send_request("/ultra"))

    assert_receive {:service_delta, _, "metadata", delta}, 2000
    assert delta["kind"] == "workspace_metadata"
    assert delta["body"]["mode"] == "ultra"
    assert {:ok, _} = SwarmCodeCLI.UI.DataSource.Delta.decode(delta)
    stop_supervised!(Backend)
    restarted = start_supervised!({Backend, c.opts})
    assert {:ok, %{"value" => snapshot}} = query(restarted, c.scope, "workspace")
    assert snapshot["mode"] == "ultra"
    assert snapshot["chat_model"] == "chat-model"
  end

  test "goal report returns displayable text without launching a model", c do
    assert {:ok, %{"value" => %{"status" => "accepted", "feedback" => empty}}} =
             request(c.backend, "empty-goal", c.scope, send_request("/goal"))

    assert empty["kind"] == "report"
    assert empty["title"] == "Conversation goal"
    assert empty["text"] =~ "No goal"

    {:ok, goal} =
      Conversations.add_goal(
        c.conversation,
        String.duplicate("Finish the terminal port. ", 40) <> "Keep the whole goal.",
        "chat"
      )

    assert {:ok, %{"value" => %{"status" => "accepted", "feedback" => report}}} =
             request(c.backend, "goal-report", c.scope, send_request("/goal"))

    assert report["conversation_id"] == c.conversation.id
    assert report["text"] =~ goal.text
    assert report["text"] =~ goal.status
    assert Conversations.list_runs(c.conversation.id) == []
  end

  test "selection commands return a bounded destination and mode changes explain their result",
       c do
    for {text, feature} <- [
          {"/rewind", "checkpoints"},
          {"/workflows", "workflows"},
          {"/deep_research", "research"}
        ] do
      assert {:ok, %{"value" => %{"status" => "accepted", "feedback" => feedback}}} =
               request(c.backend, "select-" <> feature, c.scope, send_request(text))

      assert feedback["kind"] == "navigate"
      assert feedback["feature"] == feature
    end

    assert {:ok, %{"value" => %{"feedback" => mode}}} =
             request(c.backend, "mode-feedback", c.scope, send_request("/plan"))

    assert mode["kind"] == "notice"
    assert mode["text"] =~ "Plan"
  end

  test "real chat has multi-turn provider context and survives backend reload", c do
    server =
      HTTP.start(fn socket, _request, _index ->
        HTTP.stream(socket, [
          HTTP.sse(%{
            "choices" => [
              %{"delta" => %{"content" => "Saved answer."}, "finish_reason" => "stop"}
            ]
          })
        ])
      end)

    on_exit(fn -> HTTP.stop(server) end)

    {:ok, provider} =
      Providers.create(%{
        name: "persisted-#{c.conversation.id}",
        kind: "openai_compatible",
        base_url: server.url <> "/v1",
        api_key: "",
        models: ["fixture"],
        default_model: "fixture"
      })

    {:ok, _} =
      Conversations.update(c.conversation, %{chat_provider_id: provider.id, chat_model: "fixture"})

    assert {:ok, %{"value" => %{"identifiers" => [run]}}} =
             request(c.backend, "first", c.scope, send_request("Remember first turn"))

    assert_receive {:http_request, _, _}, 10_000
    assert eventually(fn -> Conversations.get_run(run).status == "done" end)

    assert {:ok, %{"value" => %{"identifiers" => [second]}}} =
             request(c.backend, "second", c.scope, send_request("Continue second turn"))

    assert_receive {:http_request, _, http}, 10_000
    assert http.body =~ "Remember first turn"
    assert http.body =~ "Saved answer."
    assert eventually(fn -> Conversations.get_run(second).status == "done" end)
    assert {:ok, %{"value" => before}} = query(c.backend, c.scope, "workspace")
    assert Enum.any?(before["transcript"]["items"], &(&1["text"] == "Saved answer."))
    stop_supervised!(Backend)
    restarted = start_supervised!({Backend, c.opts})
    assert {:ok, %{"value" => after_reload}} = query(restarted, c.scope, "workspace")
    assert Enum.map(after_reload["runs"], & &1["id"]) == Enum.map(before["runs"], & &1["id"])

    assert Enum.map(after_reload["transcript"]["items"], & &1["text"]) ==
             Enum.map(before["transcript"]["items"], & &1["text"])
  end

  test "transcript projection does not duplicate the assistant message with root or llm nodes",
       c do
    {:ok, run} =
      Conversations.create_run(%{
        conversation_id: c.conversation.id,
        kind: "chat",
        prompt: "duplicate projection",
        status: "done",
        started_at: DateTime.utc_now()
      })

    {:ok, message} =
      Conversations.create_message(%{
        conversation_id: c.conversation.id,
        run_id: run.id,
        role: "assistant",
        content: "one final answer"
      })

    {:ok, root} =
      SwarmCode.Domain.Conversations.insert_node(%{
        run_id: run.id,
        kind: "agent",
        status: "done",
        result: "one final answer"
      })

    {:ok, _llm} =
      SwarmCode.Domain.Conversations.insert_node(%{
        run_id: run.id,
        parent_id: root.id,
        kind: "op",
        op_type: "llm",
        status: "done",
        result: "one final answer"
      })

    {:ok, _} = Conversations.update_run(run, %{root_node_id: root.id})

    {:ok, child} =
      Conversations.insert_node(%{
        run_id: run.id,
        parent_id: root.id,
        kind: "agent",
        status: "done",
        result: "Worker findings"
      })

    {:ok, child_llm} =
      Conversations.insert_node(%{
        run_id: run.id,
        parent_id: child.id,
        kind: "op",
        op_type: "llm",
        status: "done",
        result: "Worker trace"
      })

    {:ok, tool} =
      Conversations.insert_node(%{
        run_id: run.id,
        parent_id: root.id,
        kind: "op",
        op_type: "command",
        status: "done",
        result: "Tool output"
      })

    assert {:ok, %{"value" => workspace}} = query(c.backend, c.scope, "workspace")

    answers =
      Enum.filter(
        workspace["transcript"]["items"],
        &String.contains?(&1["text"], message.content)
      )

    assert length(answers) == 1
    ids = Enum.map(workspace["transcript"]["items"], & &1["id"])
    assert Enum.all?([message.id, child.id, child_llm.id, tool.id], &(&1 in ids))
    refute root.id in ids
  end

  test "a real agent interview exposes every question and continues after indexed and custom answers",
       c do
    qs = [
      %{
        "question" => "Choose a format",
        "options" => [%{"label" => "JSON"}, %{"label" => "YAML"}]
      },
      %{
        "question" => "What should it be called?",
        "options" => [%{"label" => "One"}, %{"label" => "Two"}]
      }
    ]

    server =
      HTTP.start(fn socket, _request, turn ->
        delta =
          if turn == 1 do
            %{
              "tool_calls" => [
                %{
                  "index" => 0,
                  "id" => "interview",
                  "type" => "function",
                  "function" => %{
                    "name" => "ask_user",
                    "arguments" => Jason.encode!(%{"questions" => qs})
                  }
                }
              ]
            }
          else
            %{"content" => "Interview complete."}
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

    on_exit(fn -> HTTP.stop(server) end)

    {:ok, provider} =
      Providers.create(%{
        name: "interview-#{c.conversation.id}",
        kind: "openai_compatible",
        base_url: server.url <> "/v1",
        models: ["fixture"],
        default_model: "fixture"
      })

    {:ok, _} =
      Conversations.update(c.conversation, %{chat_provider_id: provider.id, chat_model: "fixture"})

    assert {:ok, %{"value" => %{"status" => "accepted", "identifiers" => [run]}}} =
             request(c.backend, "interview", c.scope, send_request("Ask me two questions"))

    assert eventually(fn ->
             length(SwarmCode.Domain.Engine.Questions.list(c.conversation.id)) == 1
           end)

    {:ok, %{"value" => %{"items" => questions}}} = query(c.backend, c.scope, "pending")
    assert length(questions) == 2

    for q <- questions,
        do: assert({:ok, _} = SwarmCodeCLI.UI.DataSource.DTO.PendingInteraction.decode(q))

    {:ok, %{"value" => workspace}} = query(c.backend, c.scope, "workspace")
    assert {:ok, _} = SwarmCodeCLI.UI.DataSource.DTO.WorkspaceSnapshot.decode(workspace)
    first = Enum.find(questions, &(&1["question"]["prompt"] == "Choose a format"))
    second = Enum.find(questions, &(&1["id"] != first["id"]))

    submit = fn q, ids, custom, req_id ->
      request(c.backend, req_id, c.scope, %ServiceRequest{
        operation: :question_answer,
        timeout_ms: 5000,
        params: %{
          "run_id" => run,
          "node_id" => q["node_id"],
          "interaction_id" => q["id"],
          "expected_revision" => q["expected_revision"],
          "answers" => ids,
          "custom_text" => custom
        }
      })
    end

    assert {:ok, %{"value" => %{"status" => "accepted"}}} =
             submit.(first, [hd(first["question"]["options"])["id"]], "", "answer-1")

    {:ok, %{"value" => %{"items" => [remaining]}}} = query(c.backend, c.scope, "pending")
    assert remaining["id"] == second["id"]

    assert {:ok, %{"value" => %{"status" => "accepted"}}} =
             submit.(second, [], "Atlas", "answer-2")

    assert eventually(fn -> Conversations.get_run(run).status == "done" end)
    assert_receive {:http_request, 2, followup}, 5000
    assert followup.body =~ "JSON"
    assert followup.body =~ "Atlas"
    {:ok, %{"value" => %{"items" => []}}} = query(c.backend, c.scope, "pending")
  end

  test "watch receives typed deltas with credit and foreign controls are rejected", c do
    watch = %ServiceRequest{
      operation: :watch,
      timeout_ms: 5000,
      params: %{
        "watch_ref" => "saved",
        "slot" => "workspace",
        "page_size" => 50,
        "byte_limit" => 262_144
      }
    }

    assert {:watch, 0, _, "workspace_snapshot", _} =
             GenServer.call(c.backend, {:service_watch, self(), "watch", c.scope, watch})

    {:ok, run} =
      Conversations.create_run(%{
        conversation_id: c.conversation.id,
        kind: "chat",
        prompt: "Persisted update",
        status: "done",
        started_at: DateTime.utc_now()
      })

    SwarmCode.Domain.Engine.Events.broadcast(c.conversation.id, {:run_updated, run})
    send(c.backend, {:service_ready, self(), "saved"})
    assert_receive {:service_delta, _, "saved", delta}, 5000
    assert delta["kind"] == "run_update"
    assert delta["body"]["id"] == run.id
    refute_receive {:service_delta, _, _, _}, 20
    send(c.backend, {:service_credit, self(), "saved", delta["sequence"]})
    {:ok, other} = Conversations.create(c.project.id)

    {:ok, foreign} =
      Conversations.create_run(%{
        conversation_id: other.id,
        kind: "chat",
        started_at: DateTime.utc_now()
      })

    control = %ServiceRequest{
      operation: :run_control,
      timeout_ms: 5000,
      params: %{"run_id" => foreign.id, "action" => "stop"}
    }

    assert {:ok, %{"value" => %{"status" => "rejected", "error" => %{"code" => "not_allowed"}}}} =
             request(c.backend, "foreign", c.scope, control)

    assert Conversations.get_run(foreign.id).status == "running"
  end

  test "query before scheduled refresh preserves watch changes and SQL paging bounds history",
       c do
    watch = %ServiceRequest{
      operation: :watch,
      timeout_ms: 5000,
      params: %{
        "watch_ref" => "page-watch",
        "slot" => "workspace",
        "page_size" => 50,
        "byte_limit" => 262_144
      }
    }

    assert {:watch, 0, _, _, _} =
             GenServer.call(c.backend, {:service_watch, self(), "watch", c.scope, watch})

    {:ok, run} =
      Conversations.create_run(%{
        conversation_id: c.conversation.id,
        kind: "chat",
        prompt: "Paged history",
        status: "done",
        started_at: DateTime.utc_now()
      })

    assert {:ok, _} = query(c.backend, c.scope, "workspace")
    send(c.backend, {:service_ready, self(), "page-watch"})

    assert_receive {:service_delta, _, "page-watch",
                    %{"kind" => "run_update", "entity_id" => id}},
                   5000

    assert id == run.id
    send(c.backend, {:service_unwatch, self(), "page-watch"})

    for i <- 1..230 do
      {:ok, _} =
        Conversations.create_message(%{
          conversation_id: c.conversation.id,
          run_id: run.id,
          role: "user",
          content: "#{i}:" <> String.duplicate("x", 9000)
        })
    end

    page = %ServiceRequest{
      operation: :query,
      timeout_ms: 5000,
      params: %{
        "slot" => "transcript",
        "cursor" => nil,
        "direction" => "before",
        "page_size" => 50,
        "byte_limit" => 1_048_576
      }
    }

    assert {:ok, %{"value" => first}} = request(c.backend, "page1", c.scope, page)
    assert length(first["items"]) == 50
    assert first["before_cursor"] != nil
    item = hd(first["items"])

    detail = %ServiceRequest{
      operation: :detail,
      timeout_ms: 5000,
      params: %{"detail_ref" => item["detail_ref"]["id"], "offset" => 4096, "bytes" => 1024}
    }

    assert {:ok, %{"value" => %{"state" => "idle", "text" => full_chunk}}} =
             request(c.backend, "long-detail", c.scope, detail)

    assert byte_size(full_chunk) == 1024
    assert Enum.all?(first["items"], &(byte_size(&1["text"]) <= 2048))
    page = %{page | params: %{page.params | "cursor" => first["before_cursor"]}}
    assert {:ok, %{"value" => second}} = request(c.backend, "page2", c.scope, page)
    assert length(second["items"]) == 50
    assert MapSet.disjoint?(MapSet.new(first["covered_ids"]), MapSet.new(second["covered_ids"]))
    state = :sys.get_state(c.backend)
    assert map_size(state.runs) <= 200
    assert Enum.sum(Enum.map(state.runs, fn {_, r} -> length(r.records) end)) <= 200

    assert Enum.all?(state.runs, fn {_, r} ->
             Enum.all?(r.records, &(byte_size(&1.text) <= 8192))
           end)
  end

  test "assistant text streams before provider finish and survives an intervening query", c do
    owner = self()

    server =
      HTTP.start(fn socket, _request, _index ->
        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\nconnection: close\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\n\r\n"
          )

        part =
          HTTP.sse(%{
            "choices" => [%{"delta" => %{"content" => "Live partial"}, "finish_reason" => nil}]
          })

        :gen_tcp.send(socket, [Integer.to_string(byte_size(part), 16), "\r\n", part, "\r\n"])
        send(owner, {:partial_sent, self()})

        receive do
          :finish -> :ok
        after
          10000 -> :ok
        end

        part =
          HTTP.sse(%{
            "choices" => [%{"delta" => %{"content" => " final"}, "finish_reason" => "stop"}]
          })

        :gen_tcp.send(socket, [
          Integer.to_string(byte_size(part), 16),
          "\r\n",
          part,
          "\r\n0\r\n\r\n"
        ])
      end)

    on_exit(fn -> HTTP.stop(server) end)

    {:ok, provider} =
      Providers.create(%{
        name: "stream-#{c.conversation.id}",
        kind: "openai_compatible",
        base_url: server.url <> "/v1",
        api_key: "",
        models: ["fixture"],
        default_model: "fixture"
      })

    {:ok, _} =
      Conversations.update(c.conversation, %{chat_provider_id: provider.id, chat_model: "fixture"})

    watch = %ServiceRequest{
      operation: :watch,
      timeout_ms: 5000,
      params: %{
        "watch_ref" => "stream",
        "slot" => "workspace",
        "page_size" => 50,
        "byte_limit" => 262_144
      }
    }

    assert {:watch, 0, _, _, _} =
             GenServer.call(c.backend, {:service_watch, self(), "watch", c.scope, watch})

    send(c.backend, {:service_ready, self(), "stream"})

    assert {:ok, %{"value" => %{"identifiers" => [run]}}} =
             request(c.backend, "stream-send", c.scope, send_request("Stream a response"))

    assert_receive {:partial_sent, handler}, 5000
    assert receive_text(c.backend, "stream", "Live partial", 80)
    assert Conversations.get_run(run).status == "running"
    assert {:ok, %{"value" => body}} = query(c.backend, c.scope, "workspace")
    assert Enum.any?(body["transcript"]["items"], &(&1["text"] == "Live partial"))
    send(handler, :finish)
    assert eventually(fn -> Conversations.get_run(run).status == "done" end)
  end

  test "multiple approvals require the exact selected node", c do
    {:ok, run} =
      Conversations.create_run(%{
        conversation_id: c.conversation.id,
        kind: "chat",
        prompt: "Approvals",
        started_at: DateTime.utc_now()
      })

    nodes =
      for _ <- 1..2 do
        {:ok, node} =
          Conversations.insert_node(%{run_id: run.id, kind: "agent", status: "awaiting_approval"})

        SwarmCode.Domain.Engine.Questions.put(c.conversation.id, run.id, node.id, :approval)
        node
      end

    on_exit(fn -> SwarmCode.Domain.Engine.Questions.delete_run(run.id) end)

    items =
      Enum.map(
        nodes,
        &%{
          node_id: &1.id,
          kind: :approval,
          permission: :write,
          tool: "write_file",
          args: "{}",
          questions: []
        }
      )

    start_supervised!(
      {ApprovalOwner,
       %{run: run.id, conversation: c.conversation.id, owner: self(), items: items}}
    )

    assert {:ok, %{"value" => %{"items" => pending}}} = query(c.backend, c.scope, "pending")
    assert length(pending) == 2
    first = Enum.find(pending, &(&1["node_id"] == hd(nodes).id))

    command = %ServiceRequest{
      operation: :approval_resolve,
      timeout_ms: 5000,
      params: %{
        "run_id" => run.id,
        "node_id" => List.last(nodes).id,
        "interaction_id" => first["id"],
        "expected_revision" => first["expected_revision"],
        "decision" => "approve"
      }
    }

    assert {:ok, %{"value" => %{"status" => "rejected"}}} =
             request(c.backend, "mismatched-approval", c.scope, command)

    refute_receive {:approval_resolved, _, _}, 20
    command = %{command | params: %{command.params | "node_id" => first["node_id"]}}

    assert {:ok, %{"value" => %{"status" => "accepted"}}} =
             request(c.backend, "matched-approval", c.scope, command)

    assert_receive {:approval_resolved, node, :approve}
    assert node == first["node_id"]
  end

  test "concurrent duplicate identity admits one durable outcome", c do
    req = send_request("/plan")

    results =
      1..2
      |> Task.async_stream(fn _ -> request(c.backend, "concurrent-identity", c.scope, req) end,
        max_concurrency: 2,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.uniq(results) |> length() == 1
    assert hd(results) |> elem(0) == :ok
    assert Conversations.get!(c.conversation.id).mode == "plan"
  end

  test "unfinished durable reservation stays unknown after backend restart", c do
    command = send_request("/plan")

    fingerprint =
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary(
          {%{kind: c.scope.kind, id: c.scope.id}, command.operation, command.params}
        )
      )
      |> Base.encode16(case: :lower)

    assert :new =
             SwarmCode.Daemon.Service.CommandLedger.admit(
               c.project.id,
               "unfinished",
               c.scope,
               fingerprint
             )

    stop_supervised!(Backend)

    resumed =
      start_supervised!({Backend, Keyword.put(c.opts, :source_epoch, Ecto.UUID.generate())})

    assert {:ok, %{"value" => outcome}} =
             request(resumed, "unfinished", %{c.scope | generation: 8}, command)

    assert outcome["status"] == "outcome_unknown"
    assert {:ok, _} = SwarmCodeCLI.UI.DataSource.DTO.Outcome.decode(outcome)
    assert Conversations.get!(c.conversation.id).mode == "build"
  end

  test "completed mutation replays exactly after backend restart", c do
    request = send_request("/plan")
    first = request(c.backend, "restart-identity", c.scope, request)
    assert {:ok, %{"value" => %{"status" => "accepted"}}} = first
    stop_supervised!(Backend)

    replacement =
      start_supervised!({Backend, Keyword.put(c.opts, :source_epoch, Ecto.UUID.generate())})

    resumed_scope = %{c.scope | generation: c.scope.generation + 1}
    assert request(replacement, "restart-identity", resumed_scope, request) == first
    assert Conversations.get!(c.conversation.id).mode == "plan"
    conflict = request(replacement, "restart-identity", c.scope, send_request("/ultra"))

    assert {:ok,
            %{"value" => %{"status" => "rejected", "error" => %{"code" => "request_conflict"}}}} =
             conflict
  end

  test "global feature mutation is clamped to admitted project and socket command is typed", c do
    foreign_root = Path.join(Path.dirname(c.root), "foreign")
    File.mkdir_p!(foreign_root)
    {:ok, other} = Projects.create(%{name: "Foreign feature", root_path: foreign_root})

    {:ok, foreign} =
      SwarmCode.Domain.Scheduled.create(%{
        name: "foreign",
        prompt: "noop",
        kind: "chat",
        project_id: other.id,
        schedule_kind: "daily",
        time_of_day: "09:00",
        timezone: "UTC"
      })

    global = %Scope{kind: :global, id: nil, generation: 4}

    request = %ServiceRequest{
      operation: :feature_command,
      timeout_ms: 5000,
      params: %{
        "feature" => "schedules",
        "action" => "toggle",
        "id" => foreign.id,
        "attributes" => %{}
      }
    }

    assert {:ok, %{"value" => %{"status" => "rejected", "error" => %{"code" => "not_allowed"}}}} =
             request(c.backend, "foreign-global", global, request)

    assert SwarmCode.Domain.Scheduled.get(foreign.id).enabled == true

    assert {:ok, %{"value" => %{"status" => "accepted"}}} =
             request(c.backend, "project-settings", global, %ServiceRequest{
               operation: :feature_command,
               timeout_ms: 5000,
               params: %{
                 "feature" => "settings",
                 "action" => "update",
                 "id" => "settings",
                 "attributes" => %{"max_concurrent_agents" => 6}
               }
             })

    path = Path.join(Path.dirname(c.root), "feature.sock")
    File.chmod!(Path.dirname(path), 0o700)
    nonce = String.duplicate("B", 43)

    start_supervised!(
      {SwarmCode.Daemon.Service,
       socket_path: path, nonce: nonce, source_epoch: c.opts[:source_epoch], backend: c.backend}
    )

    {:ok, socket} =
      :gen_tcp.connect({:local, path}, 0, [:binary, active: false, packet: :raw], 1000)

    on_exit(fn -> :gen_tcp.close(socket) end)

    hello = %SwarmCode.Protocol.Message{
      version: 1,
      type: :hello,
      request_id: Ecto.UUID.generate(),
      nonce: nonce,
      scope: nil,
      sequence: nil,
      occurred_at: nil,
      body: SwarmCode.Protocol.ServiceHandshake.hello()
    }

    :ok = :gen_tcp.send(socket, SwarmCode.Protocol.Frame.encode!(hello))
    assert socket_frame(socket).type == :hello_ok

    ui_request =
      struct!(SwarmCodeCLI.UI.DataSource.Request,
        request_id: "settings-command",
        kind: {:feature_command, :settings, :update, "settings", %{"max_concurrent_agents" => 8}},
        scope: global,
        generation: global.generation,
        origin: {:feature, :settings},
        deadline: 5000,
        expected_response: :outcome
      )

    {:ok, command} =
      SwarmCodeCLI.UI.DataSource.Daemon.Codec.request(ui_request, Ecto.UUID.generate(), nonce, 0)

    :ok = :gen_tcp.send(socket, SwarmCode.Protocol.Frame.encode!(command))
    response = socket_frame(socket)
    assert response.type == :response

    assert {:ok, _} =
             SwarmCodeCLI.UI.DataSource.Daemon.Codec.response(
               response,
               ui_request,
               command.request_id,
               nonce
             )

    assert response.body["value"]["status"] == "accepted"
    assert SwarmCode.Domain.Settings.get().max_concurrent_agents == 8

    {:ok, own} =
      SwarmCode.Domain.Scheduled.create(%{
        name: "owned",
        prompt: "noop",
        kind: "chat",
        project_id: c.project.id,
        schedule_kind: "daily",
        time_of_day: "09:00",
        timezone: "UTC"
      })

    toggle = %{
      ui_request
      | request_id: "schedule-toggle",
        kind: {:feature_command, :schedules, :toggle, own.id, %{}},
        origin: {:feature, :schedules}
    }

    {:ok, wire} =
      SwarmCodeCLI.UI.DataSource.Daemon.Codec.request(toggle, Ecto.UUID.generate(), nonce, 0)

    :ok = :gen_tcp.send(socket, SwarmCode.Protocol.Frame.encode!(wire))
    result = socket_frame(socket)

    assert {:ok, _} =
             SwarmCodeCLI.UI.DataSource.Daemon.Codec.response(
               result,
               toggle,
               wire.request_id,
               nonce
             )

    assert result.body["value"]["status"] == "accepted"
    assert SwarmCode.Domain.Scheduled.get(own.id).enabled == false
  end

  test "real socket watch payloads pass the client Codec", c do
    nonce = String.duplicate("A", 43)
    path = Path.join(Path.dirname(c.root), "service.sock")
    File.chmod!(Path.dirname(path), 0o700)

    start_supervised!(
      {SwarmCode.Daemon.Service,
       socket_path: path, nonce: nonce, source_epoch: c.opts[:source_epoch], backend: c.backend}
    )

    {:ok, socket} =
      :gen_tcp.connect({:local, path}, 0, [:binary, active: false, packet: :raw], 1000)

    on_exit(fn -> :gen_tcp.close(socket) end)

    hello = %SwarmCode.Protocol.Message{
      version: 1,
      type: :hello,
      request_id: Ecto.UUID.generate(),
      nonce: nonce,
      scope: nil,
      sequence: nil,
      occurred_at: nil,
      body: SwarmCode.Protocol.ServiceHandshake.hello()
    }

    :ok = :gen_tcp.send(socket, SwarmCode.Protocol.Frame.encode!(hello))
    assert socket_frame(socket).type == :hello_ok

    watch =
      struct!(SwarmCodeCLI.UI.DataSource.Watch,
        watch_ref: "wire",
        slot: :workspace,
        scope: c.scope,
        generation: c.scope.generation,
        page_size: 50,
        byte_limit: 262_144
      )

    request = %{
      hello
      | type: :request,
        request_id: Ecto.UUID.generate(),
        scope: c.scope,
        body: %{
          "op" => "watch",
          "watch_ref" => "wire",
          "slot" => "workspace",
          "page_size" => 50,
          "byte_limit" => 262_144,
          "timeout_ms" => 5000
        }
    }

    :ok = :gen_tcp.send(socket, SwarmCode.Protocol.Frame.encode!(request))
    ready = socket_frame(socket)

    assert {:ok, _} =
             apply(SwarmCodeCLI.UI.DataSource.Daemon.Codec, :event, [ready, watch, nonce])

    {:ok, run} =
      Conversations.create_run(%{
        conversation_id: c.conversation.id,
        kind: "chat",
        prompt: "Socket update",
        status: "done",
        started_at: DateTime.utc_now()
      })

    delta = socket_frame(socket)
    assert delta.body["value"]["entity_id"] == run.id

    assert {:ok, _} =
             apply(SwarmCodeCLI.UI.DataSource.Daemon.Codec, :event, [delta, watch, nonce])

    assert delta.body["value"]["kind"] == "run_update"

    {:ok, message} =
      Conversations.create_message(%{
        conversation_id: c.conversation.id,
        run_id: run.id,
        role: "assistant",
        content: "Node after run update"
      })

    socket_ack(socket, request, delta.sequence)
    node_delta = socket_node(socket, request, watch, nonce, 10)
    assert node_delta.body["value"]["entity_id"] == message.id
    assert node_delta.body["value"]["body"]["text"] == "Node after run update"
  end

  defp socket_ack(socket, template, sequence) do
    ack = %{
      template
      | request_id: Ecto.UUID.generate(),
        body: %{
          "op" => "ack",
          "watch_ref" => "wire",
          "sequence" => sequence,
          "timeout_ms" => 5000
        }
    }

    :gen_tcp.send(socket, SwarmCode.Protocol.Frame.encode!(ack))
  end

  defp socket_node(_, _, _, _, 0), do: flunk("No node delta received")

  defp socket_node(socket, template, watch, nonce, n) do
    event = socket_frame(socket)

    if event.type == :event do
      assert {:ok, _} =
               apply(SwarmCodeCLI.UI.DataSource.Daemon.Codec, :event, [event, watch, nonce])

      socket_ack(socket, template, event.sequence)

      if event.body["value"]["kind"] == "node_upsert",
        do: event,
        else: socket_node(socket, template, watch, nonce, n - 1)
    else
      socket_node(socket, template, watch, nonce, n - 1)
    end
  end

  defp socket_frame(socket) do
    {:ok, <<length::32>>} = :gen_tcp.recv(socket, 4, 5000)
    {:ok, bytes} = :gen_tcp.recv(socket, length, 5000)
    {:ok, message} = SwarmCode.Protocol.Envelope.decode(bytes)
    message
  end

  defp receive_text(_, _, _, 0), do: false

  defp receive_text(backend, ref, text, attempts) do
    receive do
      {:service_delta, ^backend, ^ref, delta} ->
        send(backend, {:service_credit, self(), ref, delta["sequence"]})

        if get_in(delta, ["body", "text"]) == text,
          do: true,
          else: receive_text(backend, ref, text, attempts - 1)
    after
      100 -> receive_text(backend, ref, text, attempts - 1)
    end
  end

  test "stream events retain tokens, resets and channels while credit is withheld", c do
    {:ok, run} =
      Conversations.create_run(%{
        conversation_id: c.conversation.id,
        kind: "chat",
        started_at: DateTime.utc_now()
      })

    {:ok, message} =
      Conversations.create_message(%{
        conversation_id: c.conversation.id,
        run_id: run.id,
        role: "assistant",
        content: ""
      })

    query(c.backend, c.scope, "workspace")

    watch_request = %ServiceRequest{
      operation: :watch,
      timeout_ms: 5000,
      params: %{
        "watch_ref" => "stream",
        "slot" => "workspace",
        "page_size" => 50,
        "byte_limit" => 262_144
      }
    }

    assert {:watch, 0, _, "workspace_snapshot", _} =
             GenServer.call(c.backend, {:service_watch, self(), "stream", c.scope, watch_request})

    send(c.backend, {:service_ready, self(), "stream"})

    events = [
      {:assistant_delta, "first", "stream_append", "text"},
      {:assistant_delta, " second", "stream_append", "text"},
      {:reasoning_delta, "thinking", "stream_append", "reasoning"},
      {:assistant_reset, "replacement", "stream_reset", "text"},
      {:assistant_delta, " tail", "stream_append", "text"}
    ]

    for {event, text, _, _} <- events, do: send(c.backend, {event, message.id, text})
    :sys.get_state(c.backend)

    watch = %SwarmCodeCLI.UI.DataSource.Watch{
      watch_ref: "stream",
      scope: c.scope,
      generation: 3,
      slot: :workspace,
      page_size: 50,
      byte_limit: 262_144
    }

    nonce = String.duplicate("A", 43)

    for {{_, text, kind, channel}, sequence} <- Enum.with_index(events, 1) do
      assert_receive {:service_delta, _, "stream", delta}, 1000
      assert delta["kind"] == kind
      assert delta["text"] == text
      assert delta["channel"] == channel
      assert delta["sequence"] == sequence

      envelope = %SwarmCode.Protocol.Message{
        version: 1,
        type: :event,
        request_id: nil,
        nonce: nonce,
        scope: c.scope,
        sequence: sequence,
        occurred_at: "2026-09-07T00:00:00Z",
        body: %{"op" => "delta", "watch_ref" => "stream", "value" => delta}
      }

      assert {:ok, _} = SwarmCodeCLI.UI.DataSource.Daemon.Codec.event(envelope, watch, nonce)
      send(c.backend, {:service_credit, self(), "stream", sequence})
    end

    # The scheduled projection refresh may publish a correlated run update
    # after the stream events; it is not part of the token ordering assertion.
    send(c.backend, {:service_credit, self(), "stream", length(events)})
    send(c.backend, {:assistant_delta, message.id, String.duplicate("x", 65_537)})
    assert_receive {:service_overflow, _, "stream"}, 1000
  end

  test "run inspector pages older persisted message records with transcript cursors", c do
    {:ok, run} =
      Conversations.create_run(%{
        conversation_id: c.conversation.id,
        kind: "chat",
        prompt: "Paged run",
        status: "done",
        started_at: DateTime.utc_now()
      })

    messages =
      for i <- 1..45 do
        {:ok, message} =
          Conversations.create_message(%{
            conversation_id: c.conversation.id,
            run_id: run.id,
            role: "user",
            content: "Message #{i}"
          })

        message
      end

    expected = messages |> Enum.sort_by(&{&1.inserted_at, &1.id}) |> Enum.map(& &1.id)
    scope = %{c.scope | kind: :run, id: run.id}

    params = %{
      "watch_ref" => "run-page",
      "slot" => "inspector",
      "page_size" => 20,
      "byte_limit" => 1_048_576
    }

    watch = %ServiceRequest{operation: :watch, timeout_ms: 5000, params: params}

    assert {:watch, _, _, "run_detail_snapshot", first} =
             GenServer.call(c.backend, {:service_watch, self(), "watch-run", scope, watch})

    assert first["run"]["id"] == run.id
    assert Enum.map(first["transcript"]["items"], & &1["id"]) == Enum.take(expected, -20)
    cursor = first["transcript"]["before_cursor"]
    assert is_binary(cursor)

    query = %ServiceRequest{
      operation: :query,
      timeout_ms: 5000,
      params: %{
        "slot" => "inspector",
        "cursor" => cursor,
        "direction" => "before",
        "page_size" => 20,
        "byte_limit" => 1_048_576
      }
    }

    assert {:ok, %{"response_kind" => "run_detail_snapshot", "value" => second}} =
             request(c.backend, "older-run", scope, query)

    first_ids = Enum.map(first["transcript"]["items"], & &1["id"])
    second_ids = Enum.map(second["transcript"]["items"], & &1["id"])
    assert second_ids == Enum.slice(expected, 5, 20)
    assert MapSet.disjoint?(MapSet.new(first_ids), MapSet.new(second_ids))
    assert second["run"]["id"] == run.id
    assert is_binary(second["transcript"]["before_cursor"])
    assert second["transcript"]["before_cursor"] != cursor

    query = %{query | params: %{query.params | "cursor" => second["transcript"]["before_cursor"]}}
    assert {:ok, %{"value" => third}} = request(c.backend, "oldest-run", scope, query)
    assert Enum.map(third["transcript"]["items"], & &1["id"]) == Enum.take(expected, 5)
    assert third["transcript"]["before_cursor"] == nil
  end

  test "a root spoken for by its answer leaves an already open transcript", c do
    {:ok, run} =
      Conversations.create_run(%{
        conversation_id: c.conversation.id,
        kind: "chat",
        status: "running",
        started_at: DateTime.utc_now()
      })

    {:ok, root} =
      Conversations.insert_node(%{
        run_id: run.id,
        kind: "agent",
        status: "running",
        name: "Assistant"
      })

    {:ok, _} = Conversations.update_run(run, %{root_node_id: root.id})

    watch = %ServiceRequest{
      operation: :watch,
      timeout_ms: 5000,
      params: %{
        "watch_ref" => "deduplicate",
        "slot" => "workspace",
        "page_size" => 20,
        "byte_limit" => 262_144
      }
    }

    # Before the answer exists the root agent is the run's only voice.
    assert {:watch, _, _, _, baseline} =
             GenServer.call(c.backend, {:service_watch, self(), "deduplicate", c.scope, watch})

    assert Enum.any?(baseline["transcript"]["items"], &(&1["id"] == root.id))
    send(c.backend, {:service_ready, self(), "deduplicate"})

    # The answer arrives, still empty and streaming: it speaks for the root
    # from now on, so the root's own item is retired rather than doubled.
    {:ok, _} =
      Conversations.create_message(%{
        conversation_id: c.conversation.id,
        run_id: run.id,
        role: "assistant",
        content: ""
      })

    assert {:ok, %{"value" => workspace}} = query(c.backend, c.scope, "workspace")
    refute Enum.any?(workspace["transcript"]["items"], &(&1["id"] == root.id))
    assert receive_removal(c.backend, "deduplicate", root.id, 20)
  end

  defp receive_removal(_, _, _, 0), do: false

  defp receive_removal(backend, ref, id, remaining) do
    receive do
      {:service_delta, ^backend, ^ref, delta} ->
        send(backend, {:service_credit, self(), ref, delta["sequence"]})

        (delta["kind"] == "transcript_remove" and delta["entity_id"] == id) or
          receive_removal(backend, ref, id, remaining - 1)
    after
      100 -> receive_removal(backend, ref, id, remaining - 1)
    end
  end

  defp send_request(text),
    do: %ServiceRequest{
      operation: :dispatch_send,
      timeout_ms: 30000,
      params: %{
        "action" => "send",
        "text" => text,
        "target" => %{"kind" => "main", "id" => nil},
        "attachment_refs" => []
      }
    }

  defp request(backend, id, scope, request),
    do: GenServer.call(backend, {:service_request, id, scope, request}, 30000)

  defp query(backend, scope, slot),
    do:
      request(backend, "query", scope, %ServiceRequest{
        operation: :query,
        timeout_ms: 5000,
        params: %{
          "slot" => slot,
          "cursor" => nil,
          "direction" => "after",
          "page_size" => 200,
          "byte_limit" => 1_048_576
        }
      })

  defp eventually(fun, n \\ 200)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, n),
    do:
      if(fun.(),
        do: true,
        else:
          (
            Process.sleep(25)
            eventually(fun, n - 1)
          )
      )
end
