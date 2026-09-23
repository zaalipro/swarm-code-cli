defmodule SwarmCode.Daemon.BootTest do
  # pass70 B6 (desktop Bootstrap parity): a saved session starts by settling
  # what the previous runtime left behind, before its first snapshot.
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias SwarmCode.Daemon.Boot
  alias SwarmCode.Daemon.Service.SessionSelection
  alias SwarmCode.Domain.{Cache, Conversations, Repo}

  setup do
    path = SchemaFixture.database!(:current, SwarmCode.Daemon.Test.LeaseFixture.build_root())
    start_supervised!({Repo, database: path, domain_fixture: true, pool_size: 1, log: false})
    Cache.clear()
    on_exit(&Cache.clear/0)

    root = Path.join(Path.dirname(path), "project")
    File.mkdir!(root)
    {:ok, session} = SessionSelection.open(root)
    %{session: session}
  end

  test "boot marks a run the previous runtime left running as interrupted", c do
    now = DateTime.utc_now()

    {:ok, run} =
      Conversations.insert_run_row(%{
        conversation_id: c.session.conversation.id,
        kind: "chat",
        status: "running",
        prompt: "left running",
        started_at: now
      })

    {:ok, node} =
      Conversations.insert_node(%{
        run_id: run.id,
        kind: "agent",
        role: "lead",
        name: "lead",
        status: "running",
        started_at: now
      })

    assert %{failed: []} = Boot.run(quiet() ++ [sleep: fn _ -> :ok end])

    run = Repo.get!(Conversations.Run, run.id)
    assert run.status == "stopped"
    assert run.interrupted
    assert run.finished_at

    node = Repo.get!(Conversations.Node, node.id)
    assert node.status == "stopped"
    assert node.detail == "interrupted by restart"
    assert node.finished_at
  end

  test "a failing step is retried, then logged, and never stops the others", _c do
    parent = self()

    result =
      Boot.run(
        quiet() ++
          [
            sleep: &send(parent, {:slept, &1}),
            reconcile_scheduled: fn -> {:error, :busy} end,
            prune_attachments: fn -> raise "disk gone" end
          ]
      )

    assert result.failed == [:reconcile_scheduled, :prune_attachments]
    assert_received {:slept, 100}
    assert_received {:slept, 250}
    assert_received {:slept, 500}
  end

  defp quiet, do: [start_mcp: fn -> :ok end, isolation_cleanup: false]
end
