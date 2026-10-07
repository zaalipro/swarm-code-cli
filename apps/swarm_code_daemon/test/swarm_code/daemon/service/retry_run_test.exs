defmodule SwarmCode.Daemon.Service.RetryRunTest do
  @moduledoc """
  cli020 C6 (ux-live-4): `run.retry` retries a failed or stopped run as the
  desktop's ↻ Retry does: the user message that launched it goes out again
  through dispatch; a stale revision is refused.
  """
  use ExUnit.Case, async: false
  import SwarmCode.Test.C020Backend
  alias SwarmCode.Domain.{Conversations, Engine}

  setup_all do
    setup_world("retry")
  end

  defp failed_turn(c, prompt) do
    {:ok, conv} = Conversations.create(c.project.id)
    on_exit(fn -> Engine.stop_all(conv.id) end)
    {conv, _, _} = provider!(c, conv, fn _ -> {:text, "Second time lucky."} end)

    {:ok, run} =
      Conversations.create_run(%{
        conversation_id: conv.id,
        kind: "chat",
        prompt: prompt,
        status: "failed",
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now()
      })

    {:ok, _} =
      Conversations.create_message(%{
        conversation_id: conv.id,
        role: "user",
        content: prompt,
        run_id: run.id
      })

    {conv, run}
  end

  defp retry(backend, conv, run_id, revision),
    do:
      command(backend, "retry", scope(conv), :run_retry, %{
        "run_id" => run_id,
        "revision" => revision
      })

  test "a failed chat run retries into a new run with the same prompt", c do
    {conv, run} = failed_turn(c, "Explain the build")
    backend = start_backend(c, conv)
    body = Enum.find(workspace(backend, scope(conv))["runs"], &(&1["id"] == run.id))
    assert body["state"] == "failed"

    assert {:ok, %{"value" => %{"status" => "accepted", "identifiers" => [new_run]}}} =
             retry(backend, conv, run.id, body["revision"])

    assert new_run != run.id
    assert Conversations.get_run(new_run).prompt == "Explain the build"
  end

  test "a stale revision is refused", c do
    {conv, run} = failed_turn(c, "Stale one")
    backend = start_backend(c, conv)
    body = Enum.find(workspace(backend, scope(conv))["runs"], &(&1["id"] == run.id))

    assert {:ok, %{"value" => %{"status" => "rejected", "reason" => %{"code" => "stale"}}}} =
             retry(backend, conv, run.id, body["revision"] + 1)

    assert length(Conversations.list_runs(conv.id)) == 1
  end
end
