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

  describe "C10 background commands" do
    alias SwarmCode.Domain.Tools.BackgroundProcs

    defp backgrounded(c, os_pid) do
      unless Process.whereis(BackgroundProcs), do: start_supervised!(BackgroundProcs)
      {conv, run, lead} = running_chat(c, "Start the server")

      {:ok, op} =
        Conversations.insert_node(%{
          run_id: run.id,
          kind: "op",
          op_type: "run_command",
          parent_id: lead.id,
          name: "run_command",
          title: "npm run dev",
          status: "done",
          detail: "running in the background (#{os_pid})",
          started_at: DateTime.utc_now(),
          finished_at: DateTime.utc_now()
        })

      {conv, run, op}
    end

    defp tool_state(backend, conv, op_id) do
      item =
        Enum.find(workspace(backend, scope(conv))["transcript"]["items"], &(&1["id"] == op_id))

      {:ok, tool} = SwarmCodeCLI.UI.DataSource.DTO.ToolCall.decode(item["tool"])
      tool.background_state
    end

    test "still running, then its exit, which outlives the book's row", c do
      {conv, run, op} = backgrounded(c, 434_343)
      [key] = BackgroundProcs.put(run.id, [434_343], "npm run dev", nil, conv.id)
      on_exit(fn -> BackgroundProcs.delete(key) end)
      backend = start_backend(c, conv)
      assert tool_state(backend, conv, op.id) == "still running"

      :ets.update_element(BackgroundProcs, key, {5, 0})
      assert tool_state(backend, conv, op.id) == "exit 0"

      BackgroundProcs.delete(key)
      assert tool_state(backend, conv, op.id) == "exit 0"
    end

    test "an exit the shell never reported", c do
      {conv, run, op} = backgrounded(c, 434_344)
      [key] = BackgroundProcs.put(run.id, [434_344], "npm run dev", nil, conv.id)
      on_exit(fn -> BackgroundProcs.delete(key) end)
      :ets.update_element(BackgroundProcs, key, {5, :unknown})
      backend = start_backend(c, conv)
      assert tool_state(backend, conv, op.id) == "ended (exit not recorded)"
    end

    test "at init a process the book no longer has ended unrecorded", c do
      {conv, _run, op} = backgrounded(c, 434_345)
      backend = start_backend(c, conv)
      assert tool_state(backend, conv, op.id) == "ended (exit not recorded)"
    end

    test "a command that was not backgrounded has no state", c do
      {conv, run, lead} = running_chat(c, "List files")

      {:ok, op} =
        Conversations.insert_node(%{
          run_id: run.id,
          kind: "op",
          op_type: "run_command",
          parent_id: lead.id,
          name: "run_command",
          title: "ls",
          status: "done",
          detail: "exit code 0",
          started_at: DateTime.utc_now(),
          finished_at: DateTime.utc_now()
        })

      backend = start_backend(c, conv)
      assert tool_state(backend, conv, op.id) == nil
    end
  end

  describe "C17 effort levels and the validator" do
    test "the workspace carries the levels the dispatcher accepts and the validator model", c do
      {:ok, conv} = Conversations.create(c.project.id)
      {conv, _provider, _} = provider!(c, conv, fn _ -> {:text, "ok"} end)
      {:ok, conv} = Conversations.update(conv, %{effort: "high", validator_model: nil})
      backend = start_backend(c, conv)
      body = workspace(backend, scope(conv))

      levels = SwarmCode.Daemon.Service.CommandDispatcher.efforts(conv, :chat)
      assert levels != [] and body["effort_levels"] == levels

      assert body["swarm_effort_levels"] ==
               SwarmCode.Daemon.Service.CommandDispatcher.efforts(conv, :swarm)

      assert body["effort"] == "high"
      # No validator of its own: the main model checks the work.
      assert body["validator_model"] == "fixture"

      {:ok, meta} =
        SwarmCodeCLI.UI.DataSource.DTO.WorkspaceMetadata.decode(
          Map.take(
            body,
            ~w(conversation_id mode chat_model swarm_model effort swarm_effort effort_levels swarm_effort_levels validator_model)
          )
        )

      assert meta.effort_levels == levels
    end
  end

  describe "C19 resume rows" do
    test "each conversation row carries its newest prompt's first line", c do
      root = c.root <> "-resume"
      File.mkdir_p!(root)
      {:ok, project} = SwarmCode.Domain.Projects.create(%{name: "Resume", root_path: root})
      {:ok, a} = Conversations.create(project.id)
      {:ok, b} = Conversations.create(project.id)

      for {conv, text} <- [{a, "old prompt"}, {a, "Fix the login bug\nwith details"}, {b, "x"}] do
        {:ok, _} =
          Conversations.create_message(%{conversation_id: conv.id, role: "user", content: text})
      end

      {:ok, superseded} =
        Conversations.create_message(%{conversation_id: b.id, role: "user", content: "gone"})

      Repo.update_all(
        from(m in SwarmCode.Domain.Conversations.Message, where: m.id == ^superseded.id),
        set: [superseded_at: DateTime.utc_now()]
      )

      {:ok, empty} = Conversations.create(project.id)

      assert {:ok, rows, false} =
               SwarmCode.Daemon.Service.PersistedProjection.conversations(project.id, nil, 50)

      by_id = Map.new(rows, &{&1.id, &1})
      assert by_id[a.id].last_prompt == "Fix the login bug"
      assert by_id[b.id].last_prompt == "x"
      assert by_id[empty.id].last_prompt == nil
    end

    test "the client's row decodes it (and defaults it for an older service)" do
      base = %{
        "id" => "33333333-3333-4333-8333-333333333333",
        "title" => "t",
        "created_at" => 1,
        "updated_at" => 2,
        "run_count" => 0,
        "live" => false,
        "waiting" => 0,
        "unread" => false,
        "current" => false
      }

      {:ok, row} =
        SwarmCodeCLI.UI.DataSource.DTO.ConversationSummary.decode(
          Map.put(base, "last_prompt", "Fix it")
        )

      assert row.last_prompt == "Fix it"
      {:ok, old} = SwarmCodeCLI.UI.DataSource.DTO.ConversationSummary.decode(base)
      assert old.last_prompt == nil
    end
  end
end
