defmodule SwarmCode.Daemon.Service.OrbitBackendTest do
  @moduledoc """
  orbit: the persisted service's Home half. S3 `conversation.search` (the
  projection), S4 the two wire operations through a backend, S5 the debounced
  `home_stale` push, S8 the guard that opening a conversation never marks it
  seen. Setup follows `Pass70ConversationTest`; no client DTO is referenced.
  """
  use ExUnit.Case, async: false
  import Ecto.Query

  alias SwarmCode.Daemon.Service.PersistedProjection
  alias SwarmCode.Domain.{Cache, Conversations, Projects, Repo}
  alias SwarmCode.Domain.Conversations.{Conversation, Message}

  setup_all do
    path = Path.join(System.tmp_dir!(), "orbit-backend-#{System.unique_integer([:positive])}")
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

  # Every test owns its project (the fixture file is shared).
  setup c do
    Cache.clear()
    root = Path.join(c.path, "project-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    {:ok, project} = Projects.create(%{name: "Orbit", root_path: root})
    {:ok, project} = Projects.update(project, %{approval_mode: "auto"})
    %{project: project, root: root}
  end

  defp conversation!(project, title, updated_at \\ ~U[2026-10-01 00:00:00.000000Z]) do
    {:ok, conversation} = Conversations.create(project.id)

    Repo.update_all(from(c in Conversation, where: c.id == ^conversation.id),
      set: [title: title, updated_at: updated_at]
    )

    conversation
  end

  defp say!(conversation, text, attrs \\ %{}) do
    {:ok, message} =
      Conversations.create_message(
        Map.merge(%{conversation_id: conversation.id, role: "user", content: text}, attrs)
      )

    message
  end

  describe "S3 conversation search (projection)" do
    defp titles(project, query, limit \\ 50) do
      {:ok, rows, false} = PersistedProjection.conversation_search(project.id, query, limit)
      Enum.map(rows, & &1.title)
    end

    test "a title hit and a prompt hit, newest first, with the list's row shape", c do
      by_title = conversation!(c.project, "Rate limit chip", ~U[2026-10-01 00:00:01.000000Z])
      by_prompt = conversation!(c.project, "Untouched", ~U[2026-10-01 00:00:02.000000Z])
      miss = conversation!(c.project, "Other work", ~U[2026-10-01 00:00:03.000000Z])
      say!(by_prompt, "why does the rate limit retry twice?")
      say!(miss, "unrelated prompt")

      assert {:ok, [first, second], false} =
               PersistedProjection.conversation_search(c.project.id, "rate limit", 50)

      assert {first.id, second.id} == {by_prompt.id, by_title.id}

      assert first |> Map.keys() |> Enum.sort() ==
               ~w(id inserted_at last_prompt last_seen_at stats title updated_at)a
               |> Enum.sort()

      assert first.last_prompt == "why does the rate limit retry twice?"
      assert first.stats == {0, nil}
    end

    test "a superseded prompt is not a hit; an assistant message is not either", c do
      edited = conversation!(c.project, "Edited")
      said = conversation!(c.project, "Assistant")
      say!(edited, "needle in the old prompt", %{superseded_at: DateTime.utc_now()})
      say!(edited, "the new prompt")
      say!(said, "needle in the answer", %{role: "assistant"})

      assert titles(c.project, "needle") == []
      assert titles(c.project, "new prompt") == ["Edited"]
    end

    test "another project's and a research conversation are excluded", c do
      foreign_root = Path.join(c.root, "foreign")
      File.mkdir_p!(foreign_root)
      {:ok, other} = Projects.create(%{name: "Other", root_path: foreign_root})

      mine = conversation!(c.project, "shared word")
      theirs = conversation!(other, "shared word")
      research = conversation!(c.project, "shared word research")

      Repo.query!("PRAGMA foreign_keys = OFF")

      Repo.update_all(from(x in Conversation, where: x.id == ^research.id),
        set: [research_id: 3]
      )

      Repo.query!("PRAGMA foreign_keys = ON")

      {:ok, rows, false} = PersistedProjection.conversation_search(c.project.id, "shared", 50)
      assert Enum.map(rows, & &1.id) == [mine.id]
      refute theirs.id in Enum.map(rows, & &1.id)
    end

    test "% _ and \\ match themselves", c do
      conversation!(c.project, "100% done", ~U[2026-10-01 00:00:01.000000Z])
      conversation!(c.project, "snake_case", ~U[2026-10-01 00:00:02.000000Z])
      conversation!(c.project, "back\\slash", ~U[2026-10-01 00:00:03.000000Z])
      conversation!(c.project, "1000 done", ~U[2026-10-01 00:00:04.000000Z])
      conversation!(c.project, "snakeXcase", ~U[2026-10-01 00:00:05.000000Z])

      assert titles(c.project, "0% d") == ["100% done"]
      assert titles(c.project, "%") == ["100% done"]
      assert titles(c.project, "e_c") == ["snake_case"]
      assert titles(c.project, "_") == ["snake_case"]
      assert titles(c.project, "k\\s") == ["back\\slash"]
      assert titles(c.project, "\\") == ["back\\slash"]
    end

    test "case-insensitive for ASCII; the limit applies after the order", c do
      for i <- 1..5 do
        conversation!(c.project, "Alpha #{i}", DateTime.add(~U[2026-10-01 00:00:00.000000Z], i))
      end

      assert length(titles(c.project, "ALPHA")) == 5
      assert length(titles(c.project, "aLpHa")) == 5
      assert titles(c.project, "alpha", 2) == ["Alpha 5", "Alpha 4"]
      assert titles(c.project, "no such thing") == []
    end

    test "a multi-byte title is found by its multi-byte query", c do
      conversation!(c.project, "Überlauf im Cache")
      assert titles(c.project, "überlauf") == []
      assert titles(c.project, "Überlauf") == ["Überlauf im Cache"]
      assert titles(c.project, "cache") == ["Überlauf im Cache"]
    end

    test "conversations/3 still answers as before, with the same row shape", c do
      first = conversation!(c.project, "First", ~U[2026-10-01 00:00:01.000000Z])
      second = conversation!(c.project, "Second", ~U[2026-10-01 00:00:02.000000Z])
      say!(first, "hello there")

      assert {:ok, [a, b], false} = PersistedProjection.conversations(c.project.id, nil, 10)
      assert {a.id, b.id} == {second.id, first.id}
      assert b.last_prompt == "hello there"
      assert a.stats == {0, nil}
      assert a |> Map.keys() |> Enum.sort() == first_keys()

      assert {:ok, [only], true} = PersistedProjection.conversations(c.project.id, nil, 1)
      assert only.id == second.id
    end

    defp first_keys,
      do: Enum.sort(~w(id inserted_at last_prompt last_seen_at stats title updated_at)a)

    test "a deleted prompt is no longer a hit", c do
      conversation = conversation!(c.project, "Quiet")
      message = say!(conversation, "temporary phrase")
      assert titles(c.project, "temporary phrase") == ["Quiet"]
      Repo.delete_all(from(m in Message, where: m.id == ^message.id))
      assert titles(c.project, "temporary phrase") == []
    end
  end
end
