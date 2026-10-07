defmodule SwarmCode.Daemon.Service.C020ProjectionTest do
  @moduledoc """
  cli020 lane C: the facts the persisted projection adds to the wire (the
  retry status of a run, ...), read through a workspace query.
  """
  use ExUnit.Case, async: false
  import Ecto.Query, only: [from: 2]
  import SwarmCode.Test.C020Backend
  alias SwarmCode.Domain.{Conversations, Repo}
  alias SwarmCode.Domain.Conversations.Node

  setup_all do
    setup_world("projection")
  end

  defp running_chat(c, prompt) do
    {:ok, conv} = Conversations.create(c.project.id)

    {:ok, run} =
      Conversations.create_run(%{
        conversation_id: conv.id,
        kind: "chat",
        prompt: prompt,
        status: "running",
        started_at: DateTime.utc_now()
      })

    {:ok, lead} =
      Conversations.insert_node(%{
        run_id: run.id,
        kind: "agent",
        role: "lead",
        name: "lead",
        status: "running",
        started_at: DateTime.utc_now()
      })

    {conv, run, lead}
  end

  defp run_body(backend, conv, run_id),
    do: Enum.find(workspace(backend, scope(conv))["runs"], &(&1["id"] == run_id))

  describe "C5 retry status" do
    test "a run whose llm op is retrying is :retrying with the op's detail", c do
      {conv, run, lead} = running_chat(c, "Say hi")

      {:ok, op} =
        Conversations.insert_node(%{
          run_id: run.id,
          kind: "op",
          op_type: "llm",
          parent_id: lead.id,
          name: "llm",
          title: "thinking",
          status: "retrying",
          detail: "retrying 2/5 · HTTP 500",
          started_at: DateTime.utc_now()
        })

      backend = start_backend(c, conv)
      body = run_body(backend, conv, run.id)
      assert body["state"] == "retrying"
      assert body["retry_detail"] == "retrying 2/5 · HTTP 500"

      {:ok, decoded} = SwarmCodeCLI.UI.DataSource.DTO.RunSummary.decode(body)
      assert {decoded.state, decoded.retry_detail} == {:retrying, "retrying 2/5 · HTTP 500"}

      Repo.update_all(from(n in Node, where: n.id == ^op.id), set: [status: "running"])
      body = run_body(backend, conv, run.id)
      assert body["state"] == "running"
      assert body["retry_detail"] == nil
    end
  end
end
