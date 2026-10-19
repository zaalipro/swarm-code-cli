defmodule SwarmCode.Daemon.Service.HeadlessPauseReasonTest do
  @moduledoc """
  A workflow run parked as `paused` carries the reason it was parked in the
  run summary's `error`, so `ncode -p` can say why it stopped waiting. A
  workflow that is not paused, and a paused run with no recorded reason, keep
  `error` as it was.
  """
  use ExUnit.Case, async: false

  alias SwarmCode.Domain.{Conversations, Repo}
  alias SwarmCode.Domain.Workflows.Run, as: WorkflowRun
  alias SwarmCode.Test.C020Backend, as: Fixture

  setup do
    world = Fixture.setup_world("pause-reason")
    {:ok, conversation} = Conversations.create(world.project.id)
    backend = Fixture.start_backend(world, conversation)
    %{conversation: conversation, backend: backend}
  end

  defp workflow!(conversation, status, message) do
    {:ok, run} =
      Conversations.create_run(%{
        conversation_id: conversation.id,
        kind: "workflow",
        prompt: "ship",
        status: status,
        started_at: DateTime.utc_now()
      })

    %WorkflowRun{}
    |> WorkflowRun.changeset(%{
      run_id: run.id,
      conversation_id: conversation.id,
      display_name: "Ship",
      source: "meta = %{}",
      budget: 8,
      max_live: 2,
      pause_kind: if(message, do: "infrastructure"),
      pause_message: message
    })
    |> Repo.insert!()

    run
  end

  defp summary(c, run) do
    c.backend
    |> Fixture.workspace(Fixture.scope(c.conversation))
    |> Map.fetch!("runs")
    |> Enum.find(&(&1["id"] == run.id))
  end

  test "a paused workflow's summary says why it was parked", c do
    run = workflow!(c.conversation, "paused", "The model provider has been unreachable.")

    assert %{"state" => "paused", "error" => "The model provider has been unreachable."} =
             summary(c, run)
  end

  test "a paused workflow with no recorded reason, and a running one, have no error", c do
    paused = workflow!(c.conversation, "paused", nil)
    running = workflow!(c.conversation, "running", "left over from an earlier pause")

    assert %{"state" => "paused", "error" => nil} = summary(c, paused)
    assert %{"error" => nil} = summary(c, running)
  end
end
