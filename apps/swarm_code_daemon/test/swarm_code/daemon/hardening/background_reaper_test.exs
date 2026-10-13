defmodule SwarmCode.Daemon.Hardening.BackgroundReaperTest do
  # Requirement 12: an asynchronous kill stays owned (and joinable by the
  # quit) after its visible row is gone, and a late completion never touches a
  # replacement row.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SwarmCode.Daemon.Shutdown
  alias SwarmCode.Domain.Repo
  alias SwarmCode.Domain.Tools.BackgroundProcs

  setup do
    path = SchemaFixture.database!(:current, SwarmCode.Daemon.Test.LeaseFixture.build_root())
    start_supervised!({Repo, database: path, domain_fixture: true, pool_size: 1, log: false})
    :ok
  end

  @tag :capture_log
  test "a TERM-ignoring tree is dead and the book empty before a normal shutdown returns" do
    {port, parent, child} = start_term_ignoring_tree()
    run_id = run_id()
    [key] = BackgroundProcs.put(run_id, [parent], "fixture command")

    assert :ok = BackgroundProcs.kill_async(run_id, parent)
    # The visible row is gone at once, the reaper is not.
    assert BackgroundProcs.list(run_id) == []
    assert map_size(reapers()) == 1

    assert %{reaped: 0} = Shutdown.run(teardown: false, flush_ms: 0)

    refute alive?(parent)
    refute alive?(child)
    assert reapers() == %{}
    assert BackgroundProcs.await_reapers(0) == :ok
    refute :ets.member(BackgroundProcs, key)
    assert_receive {^port, {:exit_status, _status}}, 5_000
  end

  test "reaped still counts visible survivor rows, not reaper tasks" do
    janitor = fake_janitor()
    run_id = run_id()
    BackgroundProcs.put(run_id, [fake_pid()], "held", janitor)
    [%{os_pid: held}] = BackgroundProcs.list(run_id)
    :ok = BackgroundProcs.kill_async(run_id, held)

    {:ok, other} = sleeper()
    BackgroundProcs.put(run_id, [other], "visible")
    on_exit(fn -> kill(other) end)

    release_later(janitor)
    assert %{reaped: 1} = Shutdown.run(teardown: false, flush_ms: 0)
    assert reapers() == %{}
  end

  test "a second request for the same exact row reuses the owned reaper" do
    janitor = fake_janitor()
    run_id = run_id()
    os_pid = fake_pid()
    BackgroundProcs.put(run_id, [os_pid], "held", janitor)

    :ok = BackgroundProcs.kill_async(run_id, os_pid)
    assert_receive {:stop_requested, ^janitor}
    :ok = BackgroundProcs.kill_async(run_id, os_pid)
    assert map_size(reapers()) == 1

    send(janitor, :release)
    assert BackgroundProcs.await_reapers(5_000) == :ok
    assert reapers() == %{}
  end

  test "kill after kill_async waits for the one reaper already running" do
    janitor = fake_janitor()
    run_id = run_id()
    os_pid = fake_pid()
    BackgroundProcs.put(run_id, [os_pid], "held", janitor)

    :ok = BackgroundProcs.kill_async(run_id, os_pid)
    assert_receive {:stop_requested, ^janitor}
    assert BackgroundProcs.list(run_id) == []

    killer = Task.async(fn -> BackgroundProcs.kill(run_id, os_pid) end)
    assert Task.yield(killer, 100) == nil
    assert map_size(reapers()) == 1
    refute second_stop?(janitor)

    send(janitor, :release)
    assert Task.await(killer, 5_000) == :ok
    assert BackgroundProcs.await_reapers(5_000) == :ok
    assert reapers() == %{}
    refute_receive {:stop_requested, ^janitor}, 50
  end

  test "kill_async during a synchronous kill reuses its handle" do
    janitor = fake_janitor()
    run_id = run_id()
    os_pid = fake_pid()
    BackgroundProcs.put(run_id, [os_pid], "held", janitor)

    killer = Task.async(fn -> BackgroundProcs.kill(run_id, os_pid) end)
    assert_receive {:stop_requested, ^janitor}, 5_000
    assert BackgroundProcs.list(run_id) == []

    assert :ok = BackgroundProcs.kill_async(run_id, os_pid)
    assert map_size(reapers()) == 1
    refute second_stop?(janitor)
    assert Task.yield(killer, 50) == nil

    send(janitor, :release)
    assert Task.await(killer, 5_000) == :ok
    assert BackgroundProcs.await_reapers(5_000) == :ok
    assert reapers() == %{}
    refute_receive {:stop_requested, ^janitor}, 50
  end

  test "kill leaves a replacement row alone when a reaper of the old row finishes" do
    old = fake_janitor()
    run_id = run_id()
    os_pid = fake_pid()
    BackgroundProcs.put(run_id, [os_pid], "old", old)
    killer = Task.async(fn -> BackgroundProcs.kill(run_id, os_pid) end)
    assert_receive {:stop_requested, ^old}, 5_000

    Process.sleep(2)
    [key] = BackgroundProcs.put(run_id, [os_pid], "replacement", fake_janitor())

    send(old, :release)
    assert Task.await(killer, 5_000) == :ok
    assert [%{command: "replacement"}] = BackgroundProcs.list(run_id)
    BackgroundProcs.delete(key)
  end

  test "deadlines at and around now never crash the server or its book" do
    janitor = fake_janitor()
    run_id = run_id()
    os_pid = fake_pid()
    BackgroundProcs.put(run_id, [os_pid], "held", janitor)
    :ok = BackgroundProcs.kill_async(run_id, os_pid)
    assert_receive {:stop_requested, ^janitor}
    server = Process.whereis(BackgroundProcs)

    for offset <- -50..50 do
      deadline = System.monotonic_time(:millisecond) + offset
      assert GenServer.call(BackgroundProcs, {:await, deadline}, 5_000) == {:error, :timeout}
    end

    assert Process.whereis(BackgroundProcs) == server
    assert map_size(reapers()) == 1

    send(janitor, :release)
    assert BackgroundProcs.await_reapers(5_000) == :ok
  end

  test "a late completion neither deletes nor signals a replacement row" do
    old = fake_janitor()
    run_id = run_id()
    os_pid = fake_pid()
    BackgroundProcs.put(run_id, [os_pid], "old", old)
    :ok = BackgroundProcs.kill_async(run_id, os_pid)
    assert_receive {:stop_requested, ^old}

    replacement = fake_janitor()
    Process.sleep(2)
    [key] = BackgroundProcs.put(run_id, [os_pid], "replacement", replacement)
    assert [%{command: "replacement"}] = BackgroundProcs.list(run_id)

    send(old, :release)
    assert BackgroundProcs.await_reapers(5_000) == :ok

    assert [%{command: "replacement"}] = BackgroundProcs.list(run_id)
    refute_receive {:stop_requested, ^replacement}, 50
    BackgroundProcs.delete(key)
  end

  test "a crashed reaper task is dropped from the book and releases waiters" do
    janitor = fake_janitor()
    run_id = run_id()
    os_pid = fake_pid()
    BackgroundProcs.put(run_id, [os_pid], "held", janitor)
    :ok = BackgroundProcs.kill_async(run_id, os_pid)
    assert_receive {:stop_requested, ^janitor}

    [%{pid: task}] = Map.values(reapers())
    waiter = Task.async(fn -> BackgroundProcs.await_reapers(5_000) end)
    Process.sleep(20)
    Process.exit(task, :kill)

    assert Task.await(waiter, 5_000) == :ok
    assert reapers() == %{}
  end

  test "a join timeout reports it, keeps the reaper owned and does not block the server" do
    janitor = fake_janitor()
    run_id = run_id()
    os_pid = fake_pid()
    BackgroundProcs.put(run_id, [os_pid], "held", janitor)
    :ok = BackgroundProcs.kill_async(run_id, os_pid)
    assert_receive {:stop_requested, ^janitor}

    assert BackgroundProcs.await_reapers(0) == {:error, :timeout}

    waiter = Task.async(fn -> BackgroundProcs.await_reapers(60) end)
    # The server answers other calls while a waiter is parked.
    assert map_size(reapers()) == 1
    assert Task.await(waiter, 5_000) == {:error, :timeout}
    assert map_size(reapers()) == 1

    send(janitor, :release)
    assert BackgroundProcs.await_reapers(5_000) == :ok
  end

  test "shutdown logs the sanitized timeout once and leaves the reaper running" do
    janitor = fake_janitor()
    run_id = run_id()
    os_pid = fake_pid()
    BackgroundProcs.put(run_id, [os_pid], "secret-command --token=abc123", janitor)
    :ok = BackgroundProcs.kill_async(run_id, os_pid)
    assert_receive {:stop_requested, ^janitor}

    log =
      capture_log(fn ->
        assert %{reaped: 0} = Shutdown.run(teardown: false, flush_ms: 0, cleanup_ms: 50)
      end)

    assert log =~ "background reapers did not finish before shutdown deadline"
    refute log =~ "secret-command"
    refute log =~ "abc123"
    refute log =~ Integer.to_string(os_pid)
    assert map_size(reapers()) == 1

    send(janitor, :release)
    assert BackgroundProcs.await_reapers(5_000) == :ok
  end

  # -- fixtures -------------------------------------------------------------

  defp run_id, do: "reaper-test-#{System.unique_integer([:positive])}"

  defp reapers, do: :sys.get_state(BackgroundProcs).reapers

  # A janitor that answers `:stop` with no targets, but only once released.
  defp fake_janitor do
    test = self()

    pid =
      spawn(fn ->
        receive do
          {:stop, _os_pid, from, ref} ->
            send(test, {:stop_requested, self()})

            receive do
              :release -> send(from, {ref, []})
            end
        end
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp second_stop?(janitor) do
    {:messages, messages} = Process.info(janitor, :messages)
    Enum.any?(messages, &match?({:stop, _, _, _}, &1))
  end

  # A row's pid that is never signalled: the fake janitor answers no targets.
  defp fake_pid, do: 4_000_000 + System.unique_integer([:positive])

  defp release_later(janitor) do
    spawn(fn ->
      receive do
      after
        50 -> send(janitor, :release)
      end
    end)
  end

  defp sleeper do
    {out, 0} = System.cmd("/bin/sh", ["-c", "/bin/sleep 600 >/dev/null 2>&1 & echo $!"])
    {:ok, out |> String.trim() |> String.to_integer()}
  end

  defp kill(os_pid),
    do: System.cmd("/bin/kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)

  # A shell and one descendant, both with TERM ignored (the ignore survives
  # the exec into sleep). Ready once both have printed their pid.
  defp start_term_ignoring_tree do
    script = """
    trap '' TERM
    /bin/sh -c 'trap "" TERM; echo child:$$; exec /bin/sleep 600' &
    echo parent:$$
    wait
    """

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-c", script]
      ])

    {parent, child} = await_pids(port, %{})

    on_exit(fn ->
      for pid <- [parent, child], alive?(pid), do: kill(pid)
    end)

    assert alive?(parent) and alive?(child)
    {port, parent, child}
  end

  defp await_pids(_port, %{parent: parent, child: child}), do: {parent, child}

  defp await_pids(port, acc) do
    receive do
      {^port, {:data, data}} ->
        acc =
          Regex.scan(~r/(parent|child):(\d+)/, data)
          |> Enum.reduce(acc, fn [_, who, pid], acc ->
            Map.put(acc, String.to_existing_atom(who), String.to_integer(pid))
          end)

        await_pids(port, acc)
    after
      5_000 -> flunk("fixture tree did not become ready")
    end
  end

  defp alive?(os_pid) do
    match?(
      {_, 0},
      System.cmd("/bin/kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)
    )
  end
end
