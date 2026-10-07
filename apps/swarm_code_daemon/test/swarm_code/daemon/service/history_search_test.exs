defmodule SwarmCode.Daemon.Service.HistorySearchTest do
  @moduledoc """
  cli020 C20 (competitors-19): Ctrl-R searches the prompts of this project's
  conversations, never another project's.
  """
  use ExUnit.Case, async: false
  import SwarmCode.Test.C020Backend
  alias SwarmCode.Domain.{Conversations, Projects}

  setup_all do
    world = setup_world("history")
    other_root = world.root <> "-other"
    File.mkdir_p!(other_root)
    {:ok, other} = Projects.create(%{name: "Other", root_path: other_root})
    {:ok, here_a} = Conversations.create(world.project.id)
    {:ok, here_b} = Conversations.create(world.project.id)
    {:ok, elsewhere} = Conversations.create(other.id)

    for {conv, text} <- [
          {here_a, "deploy the staging server"},
          {here_b, "deploy the staging server"},
          {here_b, "write the release notes"},
          {elsewhere, "deploy production now"},
          {here_a, "de_prefix with an underscore"}
        ] do
      {:ok, _} =
        Conversations.create_message(%{conversation_id: conv.id, role: "user", content: text})
    end

    {:ok, _} =
      Conversations.create_message(%{
        conversation_id: here_a.id,
        role: "assistant",
        content: "deploy done"
      })

    Map.merge(world, %{here: here_a})
  end

  defp search(c, backend, query) do
    assert {:ok,
            %{"value" => %{"status" => "accepted", "result" => %{"kind" => "history"} = result}}} =
             command(backend, id("history"), scope(c.here), :history_search, %{"query" => query})

    Enum.map(result["rows"], & &1["text"])
  end

  test "a word finds this project's prompts once each, newest first", c do
    backend = start_backend(c, c.here)
    assert search(c, backend, "deploy") == ["deploy the staging server"]
    assert search(c, backend, "release not") == ["write the release notes"]
  end

  test "a short query is a prefix; an empty one lists the newest", c do
    backend = start_backend(c, c.here)

    assert search(c, backend, "de") == [
             "de_prefix with an underscore",
             "deploy the staging server"
           ]

    assert search(c, backend, "d_") == []

    assert search(c, backend, "") == [
             "de_prefix with an underscore",
             "write the release notes",
             "deploy the staging server"
           ]
  end
end
