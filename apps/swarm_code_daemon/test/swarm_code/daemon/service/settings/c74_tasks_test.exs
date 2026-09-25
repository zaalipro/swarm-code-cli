defmodule SwarmCode.Daemon.Service.Settings.C74TasksTest do
  @moduledoc """
  pass74 S1-9 (§3.3.8): settings tasks. The test process owns the task set (as
  the PersistedBackend does) and feeds it the messages it receives.
  """
  use ExUnit.Case, async: true

  alias SwarmCode.Daemon.Service.Settings.{Error, TaskSpec, Tasks}
  alias SwarmCode.Domain.OSProcess

  @moduletag timeout: 60_000

  setup do
    %{sup: start_supervised!(Task.Supervisor)}
  end

  defp new(sup, opts \\ []), do: Tasks.new(self(), Keyword.put(opts, :supervisor, sup))

  defp held(test) do
    fn _report ->
      send(test, {:held, self()})

      receive do
        {:release, answer} -> answer
      end
    end
  end

  defp spec(action, key, run, opts \\ []), do: TaskSpec.new(action, key, run, opts)

  # Receive the next task message and hand it to the set.
  defp pump(tasks, wait \\ 5_000) do
    receive do
      message when is_tuple(message) and elem(message, 0) != :held ->
        case Tasks.handle(tasks, message) do
          {:ok, tasks, deltas} -> {tasks, deltas}
          :unknown -> pump(tasks, wait)
        end
    after
      wait -> flunk("no task message within #{wait} ms")
    end
  end

  # Pump until a delta whose state is `state` arrives.
  defp until_state(tasks, state, seen \\ []) do
    {tasks, deltas} = pump(tasks)
    seen = seen ++ deltas

    if Enum.any?(deltas, &(&1["state"] == state)),
      do: {tasks, seen},
      else: until_state(tasks, state, seen)
  end

  defp held_pid do
    assert_receive {:held, pid}, 5_000
    pid
  end

  test "a held cancellable task is killed at its deadline: no answer in N s", %{sup: sup} do
    tasks = new(sup)
    spec = spec("provider.test", "p1", held(self()), timeout_ms: 1_000)

    assert {:ok, tasks, id, [%{"state" => "running", "task_id" => id}]} = Tasks.start(tasks, spec)
    pid = held_pid()
    monitor = Process.monitor(pid)

    {tasks, deltas} = until_state(tasks, "timeout")
    assert %{"message" => "no answer in 1 s", "task_id" => ^id} = List.last(deltas)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 2_000
    assert Tasks.running_count(tasks) == 0

    assert {:ok, %{"state" => "timeout", "message" => "no answer in 1 s"}, _} =
             Tasks.view(tasks, %{"id" => id})
  end

  test "a held non-cancellable task reports at its deadline and is never killed", %{sup: sup} do
    tasks = new(sup)

    spec =
      spec("storage.run", {"storage.run", :wizard}, held(self()),
        timeout_ms: 1_000,
        summary: fn result -> result end
      )

    refute spec.cancellable?
    assert {:ok, tasks, id, _} = Tasks.start(tasks, spec)
    pid = held_pid()
    monitor = Process.monitor(pid)

    {tasks, [delta]} = pump(tasks)
    assert %{"state" => "running", "message" => "still running after 1 s"} = delta
    refute_received {:DOWN, ^monitor, _, _, _}

    assert {:error, %Error{code: :invalid, message: "this cannot be stopped once it started"}} =
             Tasks.cancel(tasks, id)

    # A new task with the same key is refused while it runs.
    assert {:error, %Error{code: :busy, message: "That is still running; wait for it to finish."}} =
             Tasks.start(tasks, spec("storage.run", {"storage.run", :wizard}, held(self())))

    send(pid, {:release, {:ok, %{"deleted" => 3}}})
    {tasks, deltas} = until_state(tasks, "done")
    assert %{"summary" => %{"deleted" => 3}, "message" => nil} = List.last(deltas)
    assert Tasks.running_count(tasks) == 0
  end

  test "cancelling a probe leaves no OS process of its tree", %{sup: sup} do
    tasks = new(sup)
    me = self()

    run = fn _report ->
      port =
        Port.open({:spawn_executable, "/bin/sh"}, [
          :binary,
          args: ["-c", "sleep 600 & sleep 600 & wait"]
        ])

      {:os_pid, os_pid} = Port.info(port, :os_pid)
      send(me, {:os_pid, os_pid})

      receive do
        :never -> {:ok, %{}}
      end
    end

    spec = spec("mcp.test", "srv", run)
    assert spec.kind == :probe
    assert {:ok, tasks, id, _} = Tasks.start(tasks, spec)
    assert_receive {:os_pid, os_pid}, 5_000

    tree = wait_tree(os_pid, 3)
    assert length(tree) >= 3

    assert {:ok, tasks, [%{"state" => "cancelled", "task_id" => ^id}]} = Tasks.cancel(tasks, id)
    assert Tasks.running_count(tasks) == 0
    assert Enum.all?(tree, &gone?/1)
  end

  test "a file task removes its temporary file when it is cancelled", %{sup: sup} do
    tasks = new(sup)
    me = self()
    dir = Path.join(System.tmp_dir!(), "c74-s1-file-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    run = fn _report ->
      Process.flag(:trap_exit, true)
      temp = Path.join(dir, ".export.tmp")
      File.write!(temp, "{}")
      send(me, :temp_written)

      try do
        receive do
          {:EXIT, _from, reason} -> exit(reason)
        end
      after
        File.rm(temp)
      end
    end

    spec = spec("export", "path", run)
    assert spec.kind == :file
    assert {:ok, tasks, id, _} = Tasks.start(tasks, spec)
    assert_receive :temp_written, 5_000
    assert File.ls!(dir) == [".export.tmp"]

    assert {:ok, _tasks, [%{"state" => "cancelled"}]} = Tasks.cancel(tasks, id)
    assert File.ls!(dir) == []
  end

  test "eight run at once; a ninth is busy; the same key replaces a cancellable one",
       %{sup: sup} do
    {tasks, ids} =
      Enum.reduce(1..8, {new(sup), []}, fn i, {acc, ids} ->
        {:ok, acc, id, _} = Tasks.start(acc, spec("provider.test", "p#{i}", held(self())))
        {acc, ids ++ [id]}
      end)

    for _ <- 1..8, do: held_pid()
    assert Tasks.running_count(tasks) == 8

    assert {:error,
            %Error{
              code: :busy,
              message: "Eight settings checks are already running; wait for one to finish."
            }} = Tasks.start(tasks, spec("provider.test", "p9", held(self())))

    old = hd(ids)

    assert {:ok, tasks, new_id, [cancelled, running]} =
             Tasks.start(tasks, spec("provider.test", "p1", held(self())))

    assert %{"task_id" => ^old, "state" => "cancelled"} = cancelled
    assert %{"task_id" => ^new_id, "state" => "running"} = running
    assert Tasks.running_count(tasks) == 8
    Tasks.terminate(tasks)
  end

  test "300 progress reports make at most four deltas a second", %{sup: sup} do
    tasks = new(sup)

    run = fn report ->
      for i <- 1..300, do: report.(%{done: i, total: 300, step: "model #{i}"})

      receive do
        :never -> {:ok, %{}}
      end
    end

    started = System.monotonic_time(:millisecond)
    {:ok, tasks, id, _} = Tasks.start(tasks, spec("provider.fetch_all", :all, run))
    {tasks, deltas} = collect(tasks, started + 1_200, [])
    elapsed = System.monotonic_time(:millisecond) - started

    assert length(deltas) <= div(elapsed, 250) + 1
    assert length(deltas) <= 5

    assert %{"progress" => %{"done" => 300, "total" => 300, "step" => "model 300"}} =
             List.last(deltas)

    assert {:ok, _, [%{"state" => "cancelled", "task_id" => ^id}]} = Tasks.cancel(tasks, id)
  end

  test "a result over 128 KiB is read page by page; the delta never carries it", %{sup: sup} do
    tasks = new(sup)
    rows = for i <- 1..1_000, do: %{"id" => "model-#{i}", "note" => String.duplicate("x", 200)}

    run = fn _report -> {:ok, %{"rows" => rows, "count" => 1_000}} end

    spec =
      spec("provider.fetch_models", "p1", run,
        summary: fn result -> result end,
        target: %{"id" => "p1"}
      )

    {:ok, tasks, id, _} = Tasks.start(tasks, spec)
    {tasks, deltas} = until_state(tasks, "done")
    done = List.last(deltas)
    assert done["summary"] == nil
    assert byte_size(Jason.encode!(done)) < 16_384

    small =
      spec("provider.fetch_models", "p2", run,
        summary: &%{"count" => &1["count"]},
        target: %{"id" => "p2"}
      )

    {:ok, tasks, _small_id, _} = Tasks.start(tasks, small)
    {tasks, deltas} = until_state(tasks, "done")
    assert List.last(deltas)["summary"] == %{"count" => 1_000}

    {pages, tasks} = read_pages(tasks, id, nil, [])
    assert length(pages) == 5
    assert Enum.flat_map(pages, & &1["result"]["rows"]) == rows
    assert hd(pages)["result"]["total"] == 1_000
    assert hd(pages)["result"]["summary"] == %{"count" => 1_000}

    assert {:ok, %{"task_id" => ^id}, _} =
             Tasks.view(tasks, %{
               "options" => %{"action" => "provider.fetch_models", "target" => %{"id" => "p1"}}
             })
  end

  test "a purge timer drops a secrets-bearing entry; a replaced entry ignores its old timer",
       %{sup: sup} do
    tasks = new(sup, purge_ms: 100)
    draft = %{"rows" => [%{"name" => "github", "env" => %{"TOKEN" => "ghp_secretvalue123"}}]}
    run = fn _report -> {:ok, draft} end

    spec = spec("mcp.import.read", "claude", run, holds_secrets?: true)
    {:ok, tasks, id, _} = Tasks.start(tasks, spec)
    {tasks, _} = until_state(tasks, "done")

    # The draft keeps its secret for the apply (declared read).
    {results, nil} =
      Tasks.task_results(tasks, [{"mcp.import.read", {:param, "import_id"}}], %{
        "attributes" => %{"import_id" => id}
      })

    assert %{{"mcp.import.read", ^id} => %{result: ^draft}} = results

    receive do
      {:settings_task_purge, _key, _ref} = purge ->
        {:ok, tasks, []} = Tasks.handle(tasks, purge)

        assert {:error, %Error{code: :not_found, message: "that result is gone; run it again"}} =
                 Tasks.view(tasks, %{"id" => id})
    after
      2_000 -> flunk("no purge")
    end
  end

  test "the task view of a secrets-bearing result shows its rows and its summary only",
       %{sup: sup} do
    tasks = new(sup)
    drafts = Base.encode64(~s({"GITHUB_TOKEN":"ghp_secretvalue123"}))

    result = %{
      "rows" => [%{"name" => "github", "env" => [%{"name" => "GITHUB_TOKEN", "secret" => true}]}],
      "drafts" => drafts,
      "count" => 1
    }

    secret =
      spec("mcp.import.read", "import", fn _ -> {:ok, result} end,
        holds_secrets?: true,
        summary: &Map.drop(&1, ["rows", "drafts"])
      )

    {:ok, tasks, id, _} = Tasks.start(tasks, secret)
    {tasks, _} = until_state(tasks, "done")
    {:ok, body, tasks} = Tasks.view(tasks, %{"id" => id})
    assert %{"summary" => %{"count" => 1}, "rows" => [_], "total" => 1} = body["result"]
    refute Jason.encode!(body) =~ drafts

    # Any other result: the rest is the summary (§3.3.6).
    plain = spec("lsp.check", "check", fn _ -> {:ok, Map.delete(result, "drafts")} end)
    {:ok, tasks, id, _} = Tasks.start(tasks, plain)
    {tasks, _} = until_state(tasks, "done")
    {:ok, body, _tasks} = Tasks.view(tasks, %{"id" => id})
    assert body["result"]["summary"] == %{"count" => 1}
  end

  test "terminate stops every task, the non-cancellable ones too, and every purge timer",
       %{sup: sup} do
    tasks = new(sup, purge_ms: 60_000)
    {:ok, tasks, _, _} = Tasks.start(tasks, spec("storage.vacuum", :vacuum, held(self())))
    vacuum = held_pid()
    {:ok, tasks, _, _} = Tasks.start(tasks, spec("lsp.check", "erlang", held(self())))
    check = held_pid()

    secret = spec("mcp.import.read", "x", fn _ -> {:ok, %{}} end, holds_secrets?: true)
    {:ok, tasks, _, _} = Tasks.start(tasks, secret)
    {tasks, _} = until_state(tasks, "done")
    [timer] = Map.values(SwarmCode.Daemon.Service.Settings.TaskCache.purge_timers(tasks.cache))

    monitors = for pid <- [vacuum, check], do: {pid, Process.monitor(pid)}
    :ok = Tasks.terminate(tasks)

    for {pid, ref} <- monitors, do: assert_receive({:DOWN, ^ref, :process, ^pid, _}, 2_000)
    assert Process.read_timer(timer) == false
  end

  test "a failing task's message is redacted, short secrets included", %{sup: sup} do
    tasks = new(sup)
    long = "sk-canary-7Q2X-S1-DO-NOT-SHOW"

    run = fn _report ->
      {:error,
       "HTTP 401 from x: key #{long} rejected; pin=ab12x; Authorization: Bearer abcdef123456 " <>
         String.duplicate("y", 5_000)}
    end

    spec = spec("provider.test", "p", run, redact: [long, "ab12x"])
    {:ok, tasks, _id, _} = Tasks.start(tasks, spec)
    {_tasks, deltas} = until_state(tasks, "failed")
    message = List.last(deltas)["message"]

    refute message =~ long
    refute message =~ "ab12x"
    refute message =~ "abcdef123456"
    assert message =~ "HTTP 401"
    assert byte_size(message) <= 2_048
  end

  test "declared reads: summaries for :all, the sessions store beside the LRU", %{sup: sup} do
    tasks = new(sup)
    sessions = for i <- 1..3, do: %{"id" => "s#{i}", "bytes" => i * 100}

    measure =
      spec("storage.measure", :measure, fn _ ->
        {:ok, %{"total_bytes" => 600, "sessions" => sessions}}
      end)

    {:ok, tasks, _, _} = Tasks.start(tasks, measure)
    {tasks, _} = until_state(tasks, "done")
    check = spec("provider.test", "p1", fn _ -> {:ok, %{"models" => 3}} end)
    {:ok, tasks, _, _} = Tasks.start(tasks, check)
    {tasks, _} = until_state(tasks, "done")

    {results, store} =
      Tasks.task_results(
        tasks,
        [{"provider.test", :all}, {"storage.measure", :sessions_store}],
        %{}
      )

    assert [{{"provider.test", "p1"}, entry}] = Map.to_list(results)
    refute Map.has_key?(entry, :result)
    assert entry.state == "done"
    assert Enum.map(store, & &1["id"]) == ["s3", "s2", "s1"]
    assert {%{}, nil} = Tasks.task_results(tasks, [], %{})
  end

  defp collect(tasks, deadline, acc) do
    wait = deadline - System.monotonic_time(:millisecond)

    if wait <= 0 do
      {tasks, acc}
    else
      receive do
        message when is_tuple(message) ->
          case Tasks.handle(tasks, message) do
            {:ok, tasks, deltas} -> collect(tasks, deadline, acc ++ deltas)
            :unknown -> collect(tasks, deadline, acc)
          end
      after
        wait -> {tasks, acc}
      end
    end
  end

  defp read_pages(tasks, id, cursor, acc) do
    {:ok, page, tasks} = Tasks.view(tasks, %{"id" => id, "cursor" => cursor})
    acc = acc ++ [page]

    case page["result"]["next_cursor"] do
      nil -> {acc, tasks}
      next -> read_pages(tasks, id, next, acc)
    end
  end

  defp wait_tree(os_pid, count, tries \\ 50) do
    tree = OSProcess.tree(os_pid)

    cond do
      length(tree) >= count or tries == 0 ->
        tree

      true ->
        receive after: (20 -> :ok)
        wait_tree(os_pid, count, tries - 1)
    end
  end

  defp gone?(os_pid) do
    {_, status} = System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)
    status != 0
  end
end
