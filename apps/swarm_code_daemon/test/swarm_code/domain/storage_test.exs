defmodule SwarmCode.Domain.StorageTest do
  @moduledoc """
  First coverage of `SwarmCode.Domain.Storage`'s execution paths (mission
  `complete-inflight-storage-gates`).

  Fixture databases only: every test starts its own `Repo` on a temp-dir file
  with `domain_fixture: true` and runs all migrations there. The canonical
  database path is never referenced.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias SwarmCode.Domain.Conversations.{Node, Run}
  alias SwarmCode.Domain.Workflows.JournalEntry
  alias SwarmCode.Domain.Workflows.Run, as: WorkflowRun
  alias SwarmCode.Domain.{Conversations, Projects, Repo, Storage}

  setup do
    path =
      Path.join(System.tmp_dir!(), "swarm-storage-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    File.chmod!(path, 0o700)
    prior = Application.get_env(:swarm_code_daemon, :domain_config_dir)
    Application.put_env(:swarm_code_daemon, :domain_config_dir, Path.join(path, "config"))

    start_supervised!(
      {Repo,
       database: Path.join(path, "storage.db"),
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

    on_exit(fn ->
      Application.delete_env(:swarm_code_daemon, :storage_transaction_seam)

      if prior,
        do: Application.put_env(:swarm_code_daemon, :domain_config_dir, prior),
        else: Application.delete_env(:swarm_code_daemon, :domain_config_dir)

      File.rm_rf!(path)
    end)

    :ok = Storage.subscribe()
    %{path: path}
  end

  test "a clean sweep emits the plain storage_done event with no errors" do
    {:ok, project} = Projects.create(%{name: "Fixture", root_path: fixture_root()})
    {:ok, conversation} = Conversations.create(project.id)
    assert conversation.id != nil

    plan = Storage.plan(%{journal_days: 30}, Storage.sessions())
    assert %{count: 0} = Storage.run_sync(plan, &send(self(), &1))

    assert_received {:storage_done, result}
    assert result.count == 0
    assert result.errors == []
    assert is_integer(result.bytes_freed)
  end

  test "batch_delete broadcasts storage_failed and preserves partial progress on transaction error" do
    journal_ids = seed_journal_fixture!()
    assert length(journal_ids) > 1

    test = self()

    Application.put_env(:swarm_code_daemon, :storage_transaction_seam, fn
      {:journal_delete, _ids, _calls} ->
        send(test, :journal_delete_attempted)
        {:error, :injected_transaction_failure}

      _ ->
        :ok
    end)

    plan = Storage.plan(%{journal_days: 30}, Storage.sessions())
    assert plan.total_count == length(journal_ids)

    log =
      capture_log(fn ->
        assert %{count: 0} = Storage.run_sync(plan, &send(self(), &1))
      end)

    assert log =~ "storage batch delete failed"
    assert_received :journal_delete_attempted

    assert_received {:storage_failed,
                     %{step: :journal_delete, reason: :injected_transaction_failure}}

    # No rows were deleted: the failed batch is not recorded as progress, and
    # the sweep returns instead of raising.
    assert Repo.aggregate(JournalEntry, :count) == length(journal_ids)
  end

  test "prune_payloads broadcasts storage_failed when its transaction fails" do
    run_id = seed_prune_fixture!()

    Application.put_env(:swarm_code_daemon, :storage_transaction_seam, fn
      {:prune_payloads, _ids, _calls} -> {:error, :injected_transaction_failure}
      _ -> :ok
    end)

    plan = Storage.plan(%{prune_days: 30}, Storage.sessions())
    assert plan.total_count == 1

    log =
      capture_log(fn ->
        assert %{count: 0} = Storage.run_sync(plan, &send(self(), &1))
      end)

    assert log =~ "storage prune payloads failed"
    assert_received {:storage_failed, %{step: :prune_payloads}}

    # The run is untouched: payloads still present, pruned flag still false.
    node = Repo.one!(from(n in Node, where: n.run_id == ^run_id, select: n))
    assert node.result != nil
    refute Repo.get!(Run, run_id).pruned
  end

  test "a partial failure emits done-with-errors instead of a clean storage_done" do
    journal_ids = seed_journal_fixture!()

    Application.put_env(:swarm_code_daemon, :storage_transaction_seam, fn
      {:journal_delete, _ids, _calls} -> {:error, :injected_transaction_failure}
      _ -> :ok
    end)

    plan = Storage.plan(%{journal_days: 30}, Storage.sessions())

    capture_log(fn ->
      Storage.run_sync(plan, &send(self(), &1))
    end)

    assert_received {:storage_failed, _}
    assert_received {:storage_done, result}
    assert result.count == 0
    assert [%{step: :journal_delete, reason: :injected_transaction_failure}] = result.errors
    assert Repo.aggregate(JournalEntry, :count) == length(journal_ids)
  end

  test "run/1 rescue route broadcasts storage_failed before reraising" do
    plan =
      Storage.plan(%{}, Storage.sessions())
      |> Map.put(:__raise__, %RuntimeError{message: "storage boom"})

    assert {:ok, pid} = Storage.run(plan)
    ref = Process.monitor(pid)

    assert_receive {:storage_failed, %RuntimeError{message: "storage boom"}}
    assert_receive {:DOWN, ^ref, :process, ^pid, {%RuntimeError{message: "storage boom"}, _}}
  end

  test "earlier successful batches stay deleted when a later batch fails" do
    journal_ids = seed_journal_fixture!(count: 3)

    test = self()

    Application.put_env(:swarm_code_daemon, :storage_transaction_seam, fn
      {:journal_delete, _ids, 0} ->
        :ok

      {:journal_delete, _ids, _calls} = step ->
        send(test, :second_batch_attempted)
        assert elem(step, 0) == :journal_delete
        {:error, :injected_transaction_failure}

      _ ->
        :ok
    end)

    plan =
      Storage.plan(%{journal_days: 30}, Storage.sessions())
      |> Map.put(:__batch_size__, 2)

    assert plan.total_count == 3

    log =
      capture_log(fn ->
        assert %{count: 2} = Storage.run_sync(plan, &send(self(), &1))
      end)

    assert log =~ "storage batch delete failed"
    assert_received :second_batch_attempted
    assert_received {:storage_done, %{count: 2, errors: [_]}}
    # The first batch's two rows are gone; the failed batch's row survives.
    assert Repo.aggregate(JournalEntry, :count) == 1
    assert Repo.all(from(j in JournalEntry, select: j.id)) -- journal_ids == []
  end

  defp fixture_root do
    root =
      Path.join(System.tmp_dir!(), "swarm-storage-project-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    root
  end

  defp old_timestamp(days_ago) do
    DateTime.utc_now()
    |> DateTime.add(-days_ago * 86_400, :second)
    |> DateTime.truncate(:microsecond)
  end

  # Seeds `count` journal rows old enough to prune, each joined to a finished
  # run and a workflow run row so `prunable_journals/3` resolves them. Returns
  # the journal row ids.
  defp seed_journal_fixture!(opts \\ []) do
    count = Keyword.get(opts, :count, 2)
    {:ok, project} = Projects.create(%{name: "Journals", root_path: fixture_root()})
    {:ok, conversation} = Conversations.create(project.id)
    finished = old_timestamp(60)

    for seq <- 1..count do
      {:ok, run} =
        Conversations.create_run(%{
          conversation_id: conversation.id,
          kind: "workflow",
          status: "done",
          started_at: finished,
          finished_at: finished
        })

      Repo.insert!(%WorkflowRun{
        run_id: run.id,
        conversation_id: conversation.id,
        display_name: "fixture",
        source: "fixture",
        budget: 1,
        max_live: 1
      })

      %JournalEntry{}
      |> JournalEntry.changeset(%{
        run_id: run.id,
        seq: seq,
        slot: 0,
        fingerprint: seq,
        kind: "call",
        result: "exhaust-#{seq}",
        inserted_at: finished
      })
      |> Repo.insert!()
      |> Map.fetch!(:id)
    end
  end

  # Seeds one finished swarm run with a payload node old enough to prune.
  # Returns the run id.
  defp seed_prune_fixture! do
    {:ok, project} = Projects.create(%{name: "Prune", root_path: fixture_root()})
    {:ok, conversation} = Conversations.create(project.id)
    finished = old_timestamp(60)

    {:ok, run} =
      Conversations.create_run(%{
        conversation_id: conversation.id,
        kind: "swarm",
        status: "done",
        started_at: finished,
        finished_at: finished
      })

    {:ok, _node} =
      Conversations.insert_node(%{
        run_id: run.id,
        kind: "op",
        op_type: "run_command",
        status: "done",
        result: String.duplicate("x", 1024)
      })

    run.id
  end
end
