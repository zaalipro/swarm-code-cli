defmodule SwarmCode.Daemon.Service.Pass70ConversationTest do
  @moduledoc """
  pass70 C3 (arch F7) and the project half of C2 (arch F12): one persisted
  service lists the project's conversations, creates and opens them in place
  (re-subscribing and re-projecting), changes the project's approval mode and
  trust, and marks things seen. C5 (arch F10): what happens outside the open
  conversation reaches the shell watch as toasts and rate limits.
  """
  use ExUnit.Case, async: false
  import Ecto.Query
  alias SwarmCode.Daemon.Service.PersistedBackend, as: Backend
  alias SwarmCode.Domain.{Cache, Conversations, MCP, Notifications, Projects, Providers, Repo}
  alias SwarmCode.Domain.Engine.{Events, Questions}
  alias SwarmCode.Domain.Conversations.Conversation
  alias SwarmCode.Protocol.{Scope, ServiceRequest}
  alias SwarmCodeCLI.UI.DataSource.{Delta, DTO}

  setup_all do
    path =
      Path.join(System.tmp_dir!(), "pass70-conversation-#{System.unique_integer([:positive])}")

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

  # Every test owns its project, so the list holds exactly what it made.
  setup c do
    Cache.clear()
    root = Path.join(c.path, "project-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    {:ok, project} = Projects.create(%{name: "Conversations", root_path: root})
    {:ok, project} = Projects.update(project, %{approval_mode: "auto"})
    {:ok, older} = Conversations.create(project.id)
    {:ok, current} = Conversations.create(project.id)
    {:ok, older} = Conversations.update(older, %{title: "Older work"})
    {:ok, current} = Conversations.update(current, %{title: "Current work"})
    stamp(older, ~U[2026-09-20 10:00:00.000000Z])
    stamp(current, ~U[2026-09-21 10:00:00.000000Z])

    backend =
      start_supervised!(
        {Backend,
         mode: :persisted,
         repo: Repo,
         project_root: root,
         project_id: project.id,
         conversation_id: current.id,
         source_epoch: Ecto.UUID.generate()}
      )

    %{backend: backend, project: project, older: older, current: current}
  end

  defp stamp(conversation, at),
    do:
      Repo.update_all(from(c in Conversation, where: c.id == ^conversation.id),
        set: [updated_at: at]
      )

  defp global, do: %Scope{kind: :global, id: nil, generation: 0}
  defp conversation(id), do: %Scope{kind: :conversation, id: id, generation: 1}

  test "the list is the project's conversations, newest first, with the open one marked", c do
    assert {:ok, %{"response_kind" => "conversation_list", "value" => body}} =
             list(c.backend, nil, 50)

    assert {:ok, %DTO.ConversationList{} = page} = DTO.ConversationList.decode(body)

    assert Enum.map(page.items, &{&1.title, &1.current, &1.run_count}) ==
             [{"Current work", true, 0}, {"Older work", false, 0}]

    assert {page.project, page.current_id} == {"Conversations", c.current.id}
    assert page.after_cursor == nil

    # Keyset paging: one per page, the second page starts after the first.
    assert {:ok, %{"value" => first}} = list(c.backend, nil, 1)
    assert [%{"id" => id}] = first["items"]
    assert id == c.current.id and first["after_cursor"] == id

    assert {:ok, %{"value" => second}} = list(c.backend, id, 1)
    assert [%{"id" => older}] = second["items"]
    assert older == c.older.id and second["after_cursor"] == nil
  end

  test "new creates and opens a conversation; the shell watch re-snapshots", c do
    watch!(c.backend, "shell", global(), "shell")

    assert {:ok, %{"value" => %{"status" => "accepted", "identifiers" => [new_id]}}} =
             request(c.backend, "new", global(), %ServiceRequest{
               operation: :conversation_new,
               timeout_ms: 5000,
               params: %{}
             })

    assert_receive {:service_resync, _, "shell"}, 2000
    assert %{project_id: project_id} = Conversations.get(new_id)
    assert project_id == c.project.id

    {:ok, %{"value" => body}} = list(c.backend, nil, 50)
    assert body["current_id"] == new_id
    assert [%{"id" => ^new_id, "current" => true} | _] = body["items"]

    # The service follows the open conversation: the new one answers, the old
    # one no longer does.
    assert {:ok, %{"value" => snapshot}} = query(c.backend, conversation(new_id), "workspace")
    assert snapshot["conversation_id"] == new_id
    assert {:error, %{"code" => "not_allowed"}} = query(c.backend, conversation(c.current.id))
  end

  test "open switches to a conversation of the project and refuses any other", c do
    File.mkdir_p!(c.project.root_path <> "-x")
    {:ok, stranger} = Projects.create(%{name: "Stranger", root_path: c.project.root_path <> "-x"})
    {:ok, foreign} = Conversations.create(stranger.id)

    assert {:ok, %{"value" => %{"status" => "rejected"}}} = open(c.backend, "foreign", foreign.id)

    assert {:ok, %{"value" => %{"status" => "accepted", "identifiers" => [older]}}} =
             open(c.backend, "older", c.older.id)

    assert older == c.older.id
    assert {:ok, %{"value" => snapshot}} = query(c.backend, conversation(older), "workspace")
    assert snapshot["title"] == "Older work"

    # Opening is not a durable command: opening the same one twice is fine.
    assert {:ok, %{"value" => %{"status" => "accepted"}}} = open(c.backend, "older-2", older)
  end

  test "the approval mode changes the project, the workspace metadata and raises a toast", c do
    scope = conversation(c.current.id)
    watch!(c.backend, "workspace", scope, "workspace")
    watch!(c.backend, "shell", global(), "shell")

    assert {:ok, %{"value" => %{"status" => "accepted", "feedback" => feedback}}} =
             update(c.backend, "mode", scope, %{"approval_mode" => "full_access"})

    assert feedback["text"] == "Approval mode: full access"
    assert Projects.get(c.project.id).approval_mode == "full_access"

    assert_receive {:service_delta, _, "workspace",
                    %{"kind" => "workspace_metadata", "body" => metadata} = delta},
                   2000

    assert metadata["approval_mode"] == "full_access"

    assert {:ok, %Delta{body: %DTO.WorkspaceMetadata{approval_mode: :full_access}}} =
             Delta.decode(delta)

    assert_receive {:service_delta, _, "shell", %{"kind" => "toast"} = toast}, 2000
    assert {:ok, %Delta{body: %DTO.Toast{level: :success}}} = Delta.decode(toast)
    refute_received {:service_delta, _, "workspace", %{"kind" => "toast"}}
  end

  test "trusting a read-only project stamps trust and lets it work (auto)", c do
    {:ok, _} = Projects.update(Projects.get(c.project.id), %{approval_mode: "read_only"})

    assert {:ok, %{"value" => %{"status" => "accepted", "feedback" => feedback}}} =
             update(c.backend, "trust", global(), %{"trusted" => true})

    assert feedback["text"] == "Project trusted; approval mode auto"
    project = Projects.get(c.project.id)
    assert {project.approval_mode, Projects.trusted?(project)} == {"auto", true}
  end

  test "the workspace snapshot carries the status line's facts", c do
    assert {:ok, %{"value" => snapshot}} =
             query(c.backend, conversation(c.current.id), "workspace")

    assert {:ok, %DTO.WorkspaceSnapshot{} = page} = DTO.WorkspaceSnapshot.decode(snapshot)
    assert {page.approval_mode, page.title, page.trusted} == {:auto, "Current work", false}
    assert is_integer(page.context_window) or page.context_window == nil

    {:ok, _} = Projects.trust(Projects.get(c.project.id))

    assert {:ok, %{"value" => snapshot}} =
             query(c.backend, conversation(c.current.id), "workspace")

    assert snapshot["trusted"] == true
  end

  test "mark seen stamps the open conversation and refuses another", c do
    assert {:ok, %{"value" => %{"status" => "accepted"}}} =
             seen(c.backend, "seen", "conversation", c.current.id)

    assert %DateTime{} = Conversations.get(c.current.id).last_seen_at

    assert {:ok, %{"value" => %{"status" => "rejected"}}} =
             seen(c.backend, "seen-other", "conversation", c.older.id)

    # Idempotent: marking again is accepted again (nothing is ledgered).
    assert {:ok, %{"value" => %{"status" => "accepted"}}} =
             seen(c.backend, "seen", "conversation", c.current.id)
  end

  describe "outside the open conversation (C5)" do
    setup c do
      watch!(c.backend, "shell", global(), "shell")
      :ok
    end

    test "finished notices and domain toasts become shell toasts", c do
      Notifications.notify_finished("Swarm finished: tidy the parser")
      assert %DTO.Toast{level: :success, text: "Swarm finished: tidy the parser"} = toast!()

      Events.ui_broadcast({:toast, "Workflow Nightly resumed"})
      assert %DTO.Toast{level: :info, text: "Workflow Nightly resumed"} = toast!()

      # "Waiting" notices carry no conversation; the waits table does (below).
      Notifications.notify_waiting("worker-a")
      refute_receive {:service_delta, _, "shell", %{"kind" => "toast"}}, 200
      assert Process.alive?(c.backend)
    end

    test "a wait in another conversation is told once; one in the open one is not", c do
      run = Ecto.UUID.generate()
      node = Ecto.UUID.generate()
      on_exit(fn -> Questions.delete_run(run) end)

      Questions.put(c.older.id, run, node, :approval)
      toast = toast!()
      assert {toast.level, toast.conversation_id, toast.run_id} == {:waiting, c.older.id, run}
      assert toast.text == "Older work needs an approval"

      # A conversation already waiting is not told again for a second request.
      Questions.put(c.older.id, run, Ecto.UUID.generate(), :question)
      refute_receive {:service_delta, _, "shell", %{"kind" => "toast"}}, 200

      mine = Ecto.UUID.generate()
      on_exit(fn -> Questions.delete_run(mine) end)
      Questions.put(c.current.id, mine, Ecto.UUID.generate(), :approval)
      refute_receive {:service_delta, _, "shell", %{"kind" => "toast"}}, 200
    end

    test "a provider's rate-limit window reaches the shell and its snapshot", c do
      {:ok, provider} =
        Providers.create(%{
          name: "limits-#{System.unique_integer([:positive])}",
          kind: "openai_compatible",
          base_url: "http://127.0.0.1:9/v1",
          models: ["m"],
          default_model: "m"
        })

      window = %{used_percent: 62.5, resets_at: ~U[2026-09-23 12:00:00Z], scope: "requests"}
      Events.ui_broadcast({:rate_limit, provider.id, window})

      assert_receive {:service_delta, backend, "shell", %{"kind" => "rate_limit"} = delta}, 2000
      send(backend, {:service_credit, self(), "shell", delta["sequence"]})
      assert {:ok, %Delta{entity_id: id, body: %DTO.RateLimit{} = limit}} = Delta.decode(delta)
      assert id == provider.id

      assert {limit.provider, limit.used_percent, limit.scope} ==
               {provider.name, 62.5, "requests"}

      assert limit.resets_at == DateTime.to_unix(window.resets_at, :millisecond)

      # The same window again is not news.
      Events.ui_broadcast({:rate_limit, provider.id, window})
      refute_receive {:service_delta, _, "shell", %{"kind" => "rate_limit"}}, 200

      assert {:ok, %{"value" => shell}} = query(c.backend, global(), "shell")

      assert {:ok, %DTO.ShellSnapshot{rate_limits: [%DTO.RateLimit{used_percent: 62.5}]}} =
               DTO.ShellSnapshot.decode(shell)
    end

    test "an MCP failure is told once and so is its recovery" do
      id = Ecto.UUID.generate()
      MCP.broadcast_status(id, {:error, "connection refused"})
      assert %DTO.Toast{level: :warning, text: "MCP server: connection refused"} = toast!()

      MCP.broadcast_status(id, {:error, "connection refused"})
      refute_receive {:service_delta, _, "shell", %{"kind" => "toast"}}, 200

      MCP.broadcast_status(id, :ready)
      assert %DTO.Toast{level: :success, title: "MCP server ready"} = toast!()
    end
  end

  # A watch sends one delta at a time: each is acknowledged like a client does.
  defp toast! do
    assert_receive {:service_delta, backend, "shell", %{"kind" => "toast"} = delta}, 2000
    send(backend, {:service_credit, self(), "shell", delta["sequence"]})
    assert {:ok, %Delta{body: %DTO.Toast{} = toast}} = Delta.decode(delta)
    toast
  end

  defp watch!(backend, slot, scope, ref) do
    request = %ServiceRequest{
      operation: :watch,
      timeout_ms: 1000,
      params: %{"watch_ref" => ref, "slot" => slot, "page_size" => 20, "byte_limit" => 262_144}
    }

    assert {:watch, 0, _, _, _} =
             GenServer.call(backend, {:service_watch, self(), "watch-#{ref}", scope, request})

    send(backend, {:service_ready, self(), ref})
  end

  defp list(backend, cursor, size),
    do:
      request(backend, "list", global(), %ServiceRequest{
        operation: :conversation_list,
        timeout_ms: 5000,
        params: %{"cursor" => cursor, "page_size" => size, "byte_limit" => 262_144}
      })

  defp open(backend, name, id),
    do:
      request(backend, name, global(), %ServiceRequest{
        operation: :conversation_open,
        timeout_ms: 5000,
        params: %{"conversation_id" => id}
      })

  defp update(backend, name, scope, params),
    do:
      request(backend, name, scope, %ServiceRequest{
        operation: :project_update,
        timeout_ms: 5000,
        params: Map.merge(%{"approval_mode" => nil, "trusted" => nil}, params)
      })

  defp seen(backend, name, kind, id),
    do:
      request(backend, name, global(), %ServiceRequest{
        operation: :mark_seen,
        timeout_ms: 5000,
        params: %{"kind" => kind, "id" => id, "revision" => 1}
      })

  defp query(backend, scope, slot \\ "workspace"),
    do:
      request(backend, "query", scope, %ServiceRequest{
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

  # The command ledger is durable per project: every request names its own.
  defp request(backend, name, scope, request),
    do:
      GenServer.call(
        backend,
        {:service_request, "#{name}-#{System.unique_integer([:positive])}", scope, request},
        10_000
      )
end
