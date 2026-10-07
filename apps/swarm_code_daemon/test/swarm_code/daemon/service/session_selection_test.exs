defmodule SwarmCode.Daemon.Service.SessionSelectionTest do
  use ExUnit.Case, async: false

  alias SwarmCode.Daemon.Service.SessionSelection
  alias SwarmCode.Domain.{Conversations, Projects, Repo}

  setup do
    path = SchemaFixture.database!(:current, SwarmCode.Daemon.Test.LeaseFixture.build_root())
    start_supervised!({Repo, database: path, domain_fixture: true, pool_size: 1, log: false})
    root = Path.join(Path.dirname(path), "project")
    File.mkdir!(root)
    %{root: root}
  end

  test "creates a project and resumes its saved conversation without duplicate rows", c do
    assert {:ok, first} = SessionSelection.open(c.root)
    assert first.project.root_path == c.root
    # D4: a new project starts read-only until trusted, exactly like the desktop
    # (pass 63 T31); the CLI never picks a mode of its own.
    assert first.project.approval_mode == "read_only"
    assert first.conversation.project_id == first.project.id

    assert {:ok, again} = SessionSelection.open(Path.join(c.root, "."))
    assert again.project.id == first.project.id
    assert again.conversation.id == first.conversation.id
    assert length(Projects.list()) == 1
    assert length(Conversations.list_for_project(first.project.id)) == 1
  end

  test "new conversation is explicit and selecting an id stays inside its project", c do
    assert {:ok, first} = SessionSelection.open(c.root)
    assert {:ok, fresh} = SessionSelection.open(c.root, conversation: :new)
    refute fresh.conversation.id == first.conversation.id
    assert {:ok, selected} = SessionSelection.open(c.root, conversation: first.conversation.id)
    assert selected.conversation.id == first.conversation.id

    other = Path.join(Path.dirname(c.root), "other")
    File.mkdir!(other)
    assert {:ok, foreign} = SessionSelection.open(other)

    assert {:error, :conversation_not_found} =
             SessionSelection.open(c.root, conversation: foreign.conversation.id)

    assert {:error, :conversation_not_found} = SessionSelection.open(c.root, conversation: "bad")
  end

  # cli020 B11 (bugs-11): a start that fails after the session was opened
  # removes what this call created, never what existed before.
  test "a failed start on a fresh database leaves no conversation and no project", c do
    assert {:ok, session} = SessionSelection.open(c.root, conversation: :new)
    assert session.created == %{project: true, conversation: true}

    assert {:error, :provider_required} =
             SwarmCode.Daemon.Service.SessionConfiguration.prepare(session, %{})

    assert :ok = SessionSelection.discard(session)
    assert Projects.list() == []
    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM conversations")
  end

  test "discard keeps rows that existed before the call", c do
    assert {:ok, first} = SessionSelection.open(c.root)
    assert {:ok, again} = SessionSelection.open(c.root)
    assert again.created == %{project: false, conversation: false}
    assert :ok = SessionSelection.discard(again)
    assert [_] = Conversations.list_for_project(first.project.id)

    assert {:ok, fresh} = SessionSelection.open(c.root, conversation: :new)
    assert fresh.created == %{project: false, conversation: true}
    assert :ok = SessionSelection.discard(fresh)
    assert [only] = Conversations.list_for_project(first.project.id)
    assert only.id == first.conversation.id
    assert length(Projects.list()) == 1
  end

  test "rejects unavailable projects and invalid options before creating records", c do
    assert {:error, :invalid_project} = SessionSelection.open(Path.join(c.root, "missing"))
    assert {:error, :invalid_selection} = SessionSelection.open(c.root, unexpected: true)
    assert Projects.list() == []
  end
end
