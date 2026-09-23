defmodule SwarmCode.Daemon.Service.Pass70ConversationTest do
  @moduledoc """
  pass70 C3 (arch F7) and the project half of C2 (arch F12): one persisted
  service lists the project's conversations, creates and opens them in place
  (re-subscribing and re-projecting), changes the project's approval mode and
  trust, and marks things seen.
  """
  use ExUnit.Case, async: false
  import Ecto.Query
  alias SwarmCode.Daemon.Service.PersistedBackend, as: Backend
  alias SwarmCode.Domain.{Cache, Conversations, Projects, Repo}
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

  test "trusting a read-only project lets it work (auto)", c do
    {:ok, _} = Projects.update(Projects.get(c.project.id), %{approval_mode: "read_only"})

    assert {:ok, %{"value" => %{"status" => "accepted"}}} =
             update(c.backend, "trust", global(), %{"trusted" => true})

    assert Projects.get(c.project.id).approval_mode == "auto"
  end

  test "the workspace snapshot carries the status line's facts", c do
    assert {:ok, %{"value" => snapshot}} =
             query(c.backend, conversation(c.current.id), "workspace")

    assert {:ok, %DTO.WorkspaceSnapshot{} = page} = DTO.WorkspaceSnapshot.decode(snapshot)
    assert {page.approval_mode, page.title} == {:auto, "Current work"}
    # Trust is a fact of the synced domain only; before it the field is nil.
    project = Projects.get(c.project.id)

    if Map.has_key?(project, :trusted_at),
      do: assert(is_boolean(page.trusted)),
      else: assert(page.trusted == nil)
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
