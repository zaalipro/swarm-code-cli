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

  # cli020 A2: the desktop's boot additions at 4c7c577 (spec 74
  # EFFICIENCY-23 / ARCHITECTURE-6): the unfinished-node repair runs with the
  # attachment prune, and the isolation sweep runs under the cleanup
  # supervisor a quit waits for.
  test "boot repairs unfinished nodes before the attachment prune", _c do
    parent = self()

    result =
      Boot.run(
        quiet() ++
          [
            repair_unfinished_nodes: fn ->
              send(parent, :repaired)
              {:ok, 0}
            end,
            prune_attachments: fn ->
              send(parent, :pruned)
              {:ok, 0}
            end
          ]
      )

    assert result.failed == []
    {:messages, messages} = Process.info(self(), :messages)
    assert Enum.filter(messages, &(&1 in [:repaired, :pruned])) == [:repaired, :pruned]
  end

  test "the delayed isolation sweep runs under the cleanup supervisor", _c do
    parent = self()

    Boot.run(
      [
        isolation_cleanup: true,
        isolation_delay_ms: 0,
        sweep_isolation: fn -> send(parent, {:swept, Process.get(:"$ancestors")}) end
      ] ++ quiet()
    )

    assert_receive {:swept, ancestors}, 5_000
    assert Process.whereis(SwarmCode.Domain.Engine.CleanupSupervisor) in ancestors
  end

  test "the domain runtime starts the desktop 0.2.0 children in the desktop's order", _c do
    {:ok, {_flags, specs}} = SwarmCode.Domain.Runtime.init([])
    ids = Enum.map(specs, & &1.id)

    for id <- [
          SwarmCode.Domain.Tools.BackgroundProcs.Supervisor,
          SwarmCode.Domain.LLM.Finch,
          SwarmCode.Domain.LLM.Speed,
          SwarmCode.Domain.Engine.ResearchContext,
          SwarmCode.Domain.Engine.CleanupSupervisor
        ] do
      assert id in ids, "#{inspect(id)} is not a child"
    end

    at = &Enum.find_index(ids, fn id -> id == &1 end)

    assert at.(SwarmCode.Domain.Tools.BackgroundProcs.Supervisor) <
             at.(SwarmCode.Domain.LLM.Finch)

    assert at.(SwarmCode.Domain.LLM.Finch) < at.(SwarmCode.Domain.LLM.ProviderCaps)
    assert at.(SwarmCode.Domain.Cache) < at.(SwarmCode.Domain.LLM.Speed)
    assert at.(SwarmCode.Domain.LLM.Speed) < at.(SwarmCode.Domain.Engine.ResearchContext)
    assert at.(SwarmCode.Domain.Engine.ResearchContext) < at.(SwarmCode.Domain.Engine.Questions)

    assert at.(SwarmCode.Domain.Tools.BackgroundProcs) <
             at.(SwarmCode.Domain.Engine.CleanupSupervisor)

    # ARCHITECTURE-13: the runs start last, so they stop first.
    assert List.last(ids) == SwarmCode.Domain.Engine.RunSupervisor
    assert at.(SwarmCode.Domain.LSP.Supervisor) < at.(SwarmCode.Domain.Engine.RunSupervisor)

    running = SwarmCode.Domain.Runtime |> Supervisor.which_children() |> Enum.map(&elem(&1, 0))
    assert Enum.sort(running) == Enum.sort(ids)
  end

  defp quiet, do: [start_mcp: fn -> :ok end, isolation_cleanup: false]
end
