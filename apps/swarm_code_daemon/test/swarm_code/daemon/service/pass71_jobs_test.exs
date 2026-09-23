defmodule SwarmCode.Daemon.Service.Pass71JobsTest do
  @moduledoc """
  pass71 S2: the persisted service's slow reads (the `@path` file index, feature
  queries, uncached diffs) run as supervised jobs. A blocked job never stalls
  another request; a newer `@path` query replaces an older one; a conversation
  switch, a timeout and the service's own stop cancel jobs and settle callers.
  """
  use ExUnit.Case, async: false
  alias SwarmCode.Daemon.Service.PersistedBackend, as: Backend
  alias SwarmCode.Domain.{Cache, Conversations, Projects, Repo}
  alias SwarmCode.Domain.Checkpoints.Checkpoint
  alias SwarmCode.Protocol.{Scope, ServiceRequest}

  setup_all do
    path = Path.join(System.tmp_dir!(), "pass71-jobs-#{System.unique_integer([:positive])}")
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
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/swarm.ex"), "x")
    {:ok, project} = Projects.create(%{name: "Jobs", root_path: root})
    {:ok, conv} = Conversations.create(project.id)
    sup = start_supervised!(Task.Supervisor)
    test = self()

    # A walk that tells the test it started, then waits to be released.
    blocking_walk = fn root ->
      send(test, {:walking, self()})

      receive do
        :release -> [Path.relative_to(Path.join(root, "lib/swarm.ex"), root)]
      end
    end

    blocking_diff = fn conversation, id ->
      send(test, {:diffing, self()})

      receive do
        {:release, text} -> {:ok, conversation <> id, %{text: text}}
      end
    end

    %{
      project: project,
      conv: conv,
      root: root,
      sup: sup,
      scope: %Scope{kind: :conversation, id: conv.id, generation: 1},
      start: fn work ->
        start_supervised!(
          {Backend,
           mode: :persisted,
           repo: Repo,
           project_root: root,
           project_id: project.id,
           conversation_id: conv.id,
           source_epoch: Ecto.UUID.generate(),
           task_supervisor: sup,
           work: work}
        )
      end,
      blocking_walk: blocking_walk,
      blocking_diff: blocking_diff
    }
  end

  test "a blocked @path walk stalls no other request and answers once released", c do
    backend = c.start.(%{file_index: c.blocking_walk})
    files = async_call(backend, c.scope, files_request("swarm"))
    assert_receive {:walking, walker}, 2_000

    # The service still answers while the walk is blocked.
    {elapsed, reply} = :timer.tc(fn -> call(backend, c.scope, workspace_request()) end)
    assert {:ok, %{"response_kind" => "workspace_snapshot"}} = reply
    assert elapsed < 1_000_000

    send(walker, :release)

    assert {:ok, %{"response_kind" => "library_snapshot", "value" => page}} =
             Task.await(files, 5_000)

    assert [%{"title" => "lib/swarm.ex"}] = page["items"]

    # The walk is kept: the next query answers without walking again.
    assert {:ok, %{"value" => %{"items" => [_]}}} =
             call(backend, c.scope, files_request("sw"))

    refute_received {:walking, _}
  end

  test "a newer @path query replaces the one still walking", c do
    backend = c.start.(%{file_index: c.blocking_walk})
    first = async_call(backend, c.scope, files_request("s"))
    assert_receive {:walking, old_walker}, 2_000
    ref = Process.monitor(old_walker)

    second = async_call(backend, c.scope, files_request("sw"))
    assert {:error, %{"code" => "stale_revision"}} = Task.await(first, 5_000)
    assert_receive {:DOWN, ^ref, :process, _, _}, 2_000

    assert_receive {:walking, walker}, 2_000
    send(walker, :release)
    assert {:ok, %{"response_kind" => "library_snapshot"}} = Task.await(second, 5_000)
  end

  test "an uncached diff is computed by a job and then paged from the cache", c do
    backend = c.start.(%{diff: c.blocking_diff})
    {run, op} = finished_edit!(c)
    change = checkpoint!(c, run, op)
    ref = change.id <> ":diff"

    detail = async_call(backend, c.scope, detail_request(ref, 0))
    assert_receive {:diffing, differ}, 2_000

    assert {:ok, %{"response_kind" => "workspace_snapshot"}} =
             call(backend, c.scope, workspace_request())

    send(differ, {:release, "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n"})

    assert {:ok, %{"value" => %{"state" => "idle", "text" => "--- a/x" <> _}}} =
             Task.await(detail, 5_000)

    # The second window comes from the cache: no new job.
    assert {:ok, %{"value" => %{"state" => "idle", "text" => "+++ b/x" <> _}}} =
             call(backend, c.scope, detail_request(ref, 8))

    refute_received {:diffing, _}
  end

  test "a diff larger than the cache is refused whole, not truncated", c do
    backend = c.start.(%{diff: c.blocking_diff})
    {run, op} = finished_edit!(c)
    change = checkpoint!(c, run, op)

    detail = async_call(backend, c.scope, detail_request(change.id <> ":diff", 0))
    assert_receive {:diffing, differ}, 2_000
    send(differ, {:release, String.duplicate("+", 4_000_001)})

    assert {:ok, %{"value" => %{"state" => "error", "error" => %{"code" => "capacity_exceeded"}}}} =
             Task.await(detail, 5_000)
  end

  test "a finished run's change facts come from a job that stalls nothing", c do
    test = self()

    blocking_facts = fn conversation, id ->
      send(test, {:facts, self()})

      receive do
        :release -> SwarmCode.Domain.FeatureCatalog.change_diff(conversation, id)
      end
    end

    backend = c.start.(%{change_diff: blocking_facts})
    {run, op} = finished_edit!(c)
    change = checkpoint!(c, run, op)
    send(backend, :refresh_projection)
    assert_receive {:facts, worker}, 2_000

    {elapsed, reply} = :timer.tc(fn -> call(backend, c.scope, workspace_request()) end)
    assert elapsed < 1_000_000
    assert {:ok, %{"value" => %{"changes" => [%{"diff_ref" => nil}]}}} = reply

    send(worker, :release)
    assert eventually_diff_ref(backend, c.scope, 200) == change.id <> ":diff"
  end

  test "switching the conversation cancels its running jobs", c do
    backend = c.start.(%{file_index: c.blocking_walk})
    files = async_call(backend, c.scope, files_request("swarm"))
    assert_receive {:walking, walker}, 2_000
    ref = Process.monitor(walker)

    {:ok, other} = Conversations.create(c.project.id)

    assert {:ok, %{"value" => %{"status" => "accepted"}}} =
             call(backend, c.scope, %ServiceRequest{
               operation: :conversation_open,
               timeout_ms: 5_000,
               params: %{"conversation_id" => other.id}
             })

    assert {:error, %{"code" => "not_allowed"}} = Task.await(files, 5_000)
    assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
  end

  test "a job past its request's deadline is killed and its caller settled", c do
    backend = c.start.(%{file_index: c.blocking_walk})

    files =
      async_call(backend, c.scope, %{files_request("swarm") | timeout_ms: 150})

    assert_receive {:walking, walker}, 2_000
    ref = Process.monitor(walker)
    assert {:error, %{"code" => "source_unavailable"}} = Task.await(files, 5_000)
    assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
    assert %{jobs: jobs} = :sys.get_state(backend)
    assert jobs == %{}
  end

  test "stopping the service kills its jobs", c do
    backend = c.start.(%{file_index: c.blocking_walk})
    _files = async_call(backend, c.scope, files_request("swarm"), catch_exit: true)
    assert_receive {:walking, walker}, 2_000
    ref = Process.monitor(walker)

    :ok = stop_supervised(Backend)
    assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
  end

  defp eventually_diff_ref(backend, scope, tries) do
    {:ok, %{"value" => %{"changes" => [change]}}} = call(backend, scope, workspace_request())

    cond do
      change["diff_ref"] != nil ->
        change["diff_ref"]["id"]

      tries > 0 ->
        receive do
        after
          10 -> eventually_diff_ref(backend, scope, tries - 1)
        end

      true ->
        flunk("the change never got its facts")
    end
  end

  defp finished_edit!(c) do
    {:ok, run} =
      Conversations.create_run(%{
        conversation_id: c.conv.id,
        kind: "chat",
        prompt: "Change",
        status: "done",
        started_at: DateTime.utc_now()
      })

    {:ok, op} =
      Conversations.insert_node(%{
        run_id: run.id,
        kind: "op",
        op_type: "edit_file",
        name: "edit_file",
        status: "done"
      })

    {run, op}
  end

  defp checkpoint!(c, run, op) do
    %Checkpoint{conversation_id: c.conv.id, run_id: run.id, node_id: op.id}
    |> Checkpoint.changeset(%{
      path: Path.join(c.root, "lib/swarm.ex"),
      previous_content: "a\n",
      restorable: true,
      inserted_at: DateTime.utc_now()
    })
    |> Checkpoint.validate()
    |> Repo.insert!()
  end

  defp files_request(query),
    do: %ServiceRequest{
      operation: :feature_query,
      timeout_ms: 5_000,
      params: %{
        "feature" => "files",
        "id" => query,
        "cursor" => nil,
        "page_size" => 20,
        "byte_limit" => 262_144
      }
    }

  defp workspace_request,
    do: %ServiceRequest{
      operation: :query,
      timeout_ms: 5_000,
      params: %{
        "slot" => "workspace",
        "cursor" => nil,
        "direction" => "before",
        "page_size" => 50,
        "byte_limit" => 1_048_576
      }
    }

  defp detail_request(ref, offset),
    do: %ServiceRequest{
      operation: :detail,
      timeout_ms: 5_000,
      params: %{"detail_ref" => ref, "offset" => offset, "bytes" => 8}
    }

  defp async_call(backend, scope, request, opts \\ []) do
    Task.async(fn ->
      try do
        call(backend, scope, request)
      catch
        :exit, reason -> if opts[:catch_exit], do: {:exit, reason}, else: exit(reason)
      end
    end)
  end

  defp call(backend, scope, request),
    do:
      GenServer.call(
        backend,
        {:service_request, "r-#{System.unique_integer([:positive])}", scope, request},
        10_000
      )
end
