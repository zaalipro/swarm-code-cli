defmodule SwarmCode.Daemon.Service.Pass71ProjectionTest do
  @moduledoc """
  pass71 S6 (C9): a streaming tick (`{:nodes_patch, …}` and the totals
  `{:run_updated, …}` of the same flush) refetches only the rows it names and
  reprojects from the last projection's inputs. Golden equivalence: the state
  it reaches is the one a full reload of the same database reaches. A tick
  whose rows changed more than a tick can carry falls back to a full reload.
  """
  use ExUnit.Case, async: false
  alias SwarmCode.Daemon.Service.PersistedBackend, as: Backend
  alias SwarmCode.Domain.{Cache, Conversations, Projects, Repo}

  setup_all do
    path = Path.join(System.tmp_dir!(), "pass71-projection-#{System.unique_integer([:positive])}")
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
       pool_size: 2,
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

  setup c do
    Cache.clear()
    root = Path.join(c.path, "project-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    {:ok, project} = Projects.create(%{name: "Ticks", root_path: root})
    {:ok, conv} = Conversations.create(project.id)

    {:ok, run} =
      Conversations.create_run(%{
        conversation_id: conv.id,
        kind: "swarm",
        prompt: "Build the thing",
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

    {:ok, worker} =
      Conversations.insert_node(%{
        run_id: run.id,
        kind: "agent",
        role: "worker",
        name: "worker-a",
        parent_id: lead.id,
        status: "running",
        progress: 10,
        started_at: DateTime.utc_now()
      })

    {:ok, op} =
      Conversations.insert_node(%{
        run_id: run.id,
        kind: "op",
        op_type: "run_command",
        parent_id: worker.id,
        name: "run_command",
        title: "mix test",
        status: "running",
        detail: "compiling",
        started_at: DateTime.utc_now()
      })

    backend =
      start_supervised!(
        {Backend,
         mode: :persisted,
         repo: Repo,
         project_root: root,
         project_id: project.id,
         conversation_id: conv.id,
         source_epoch: Ecto.UUID.generate()}
      )

    full!(backend)
    %{backend: backend, run: run, lead: lead, worker: worker, op: op}
  end

  test "a streaming tick reaches the state a full reload reaches", c do
    # What one RunServer flush writes: the op's detail, the worker's progress
    # and tokens, and the run's totals.
    {:ok, op} = Conversations.update_node(c.op, %{detail: "running 12 tests"})

    {:ok, worker} =
      Conversations.update_node(c.worker, %{progress: 40, tokens_in: 1_200, tokens_out: 80})

    {:ok, run} = Conversations.update_run_row(c.run, %{tokens_in: 1_200, tokens_out: 80})

    before = :sys.get_state(c.backend)

    send(c.backend, {:nodes_patch, run.id, [{op.id, %{detail: op.detail}}]})
    send(c.backend, {:nodes_patch, run.id, [{worker.id, %{progress: 40, tokens_in: 1_200}}]})
    send(c.backend, {:run_updated, run})
    incremental = settled!(c.backend)

    assert incremental.projections.partial == before.projections.partial + 1
    assert incremental.projections.full == before.projections.full

    projected = incremental.runs[run.id]
    assert {projected.tokens_in, projected.tokens_out} == {1_200, 80}
    assert Enum.find(projected.records, &(&1.id == op.id)).text == "running 12 tests"

    full = full!(c.backend)
    assert full.projections.full == incremental.projections.full + 1
    assert_equivalent(incremental, full)
  end

  test "a tick for a row that changed more than a tick carries reloads everything", c do
    # A finish arrives as a full upsert; a patch naming the row after it
    # (the row now has a result) is not trusted to be a tick.
    {:ok, op} = Conversations.update_node(c.op, %{detail: "done", result: "12 tests, 0 failures"})
    before = :sys.get_state(c.backend)

    send(c.backend, {:nodes_patch, c.run.id, [{op.id, %{detail: "done"}}]})
    incremental = settled!(c.backend)

    assert incremental.projections.full == before.projections.full + 1
    assert incremental.projections.partial == before.projections.partial
    assert_equivalent(incremental, full!(c.backend))
  end

  test "a run update that is not a totals tick reloads everything", c do
    {:ok, run} = Conversations.update_run_row(c.run, %{status: "done"})
    before = :sys.get_state(c.backend)

    send(c.backend, {:run_updated, run})
    incremental = settled!(c.backend)

    assert incremental.projections.full == before.projections.full + 1
    assert incremental.projections.partial == before.projections.partial
    assert_equivalent(incremental, full!(c.backend))
  end

  test "ticks and a structural event coalesced together reload everything", c do
    {:ok, op} = Conversations.update_node(c.op, %{detail: "running 3 tests"})
    before = :sys.get_state(c.backend)

    send(c.backend, {:nodes_patch, c.run.id, [{op.id, %{detail: op.detail}}]})
    send(c.backend, {:nodes_upsert, c.run.id, []})
    incremental = settled!(c.backend)

    assert incremental.projections.full == before.projections.full + 1
    assert incremental.projections.partial == before.projections.partial
  end

  # Everything a reload derives from the database and publishes.
  defp assert_equivalent(incremental, full) do
    for key <- [:runs, :order, :revision, :metadata, :changes, :verdicts, :inputs] do
      assert Map.fetch!(incremental, key) == Map.fetch!(full, key), "#{key} differs"
    end
  end

  # The armed refresh ran (it fires 20 ms after the first event).
  defp settled!(backend, tries \\ 200) do
    state = :sys.get_state(backend)

    cond do
      not state.refresh_pending ->
        state

      tries > 0 ->
        receive do
        after
          5 -> settled!(backend, tries - 1)
        end

      true ->
        flunk("the refresh never ran")
    end
  end

  # A refresh nobody armed is a full reload.
  defp full!(backend) do
    settled!(backend)
    send(backend, :refresh_projection)
    :sys.get_state(backend)
  end
end
