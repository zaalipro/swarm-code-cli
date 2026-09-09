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
    assert first.project.approval_mode == "auto"
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

  test "rejects unavailable projects and invalid options before creating records", c do
    assert {:error, :invalid_project} = SessionSelection.open(Path.join(c.root, "missing"))
    assert {:error, :invalid_selection} = SessionSelection.open(c.root, unexpected: true)
    assert Projects.list() == []
  end
end
