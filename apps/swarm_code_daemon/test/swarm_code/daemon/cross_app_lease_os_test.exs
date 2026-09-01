defmodule SwarmCode.Daemon.CrossAppLeaseOSTest do
  use ExUnit.Case, async: false

  alias SwarmCode.Daemon.Test.OSProcess

  test "two fresh OS processes race; exactly one owns and SIGKILL releases" do
    dir = private_tmp!()
    canonical = Path.join(dir, "swarm_code.db")
    one = start_probe!(dir)
    two = start_probe!(dir)
    pid_one = OSProcess.await_ready!(one)
    pid_two = OSProcess.await_ready!(two)

    Port.command(one, "GO\n")
    Port.command(two, "GO\n")

    results = [{one, OSProcess.await_result!(one)}, {two, OSProcess.await_result!(two)}]
    assert Enum.sort(Enum.map(results, &elem(&1, 1))) == [:acquired, :held]
    refute File.exists?(canonical), "winner and loser must perform zero canonical DB opens"

    {loser, :held} = Enum.find(results, &(elem(&1, 1) == :held))
    assert 0 = OSProcess.await_exit!(loser)

    {winner, :acquired} = Enum.find(results, &(elem(&1, 1) == :acquired))
    winner_os_pid = if winner == one, do: pid_one, else: pid_two
    kill_exact!(winner_os_pid)
    assert OSProcess.await_exit!(winner) != 0
    assert File.exists?(Path.join(dir, "instance_owner.json"))

    next = start_probe!(dir)
    OSProcess.await_ready!(next)
    Port.command(next, "GO\n")
    assert :acquired = OSProcess.await_result!(next)
    Port.command(next, "STOP\n")
    assert 0 = OSProcess.await_exit!(next)

    refute File.exists?(canonical), "replacement must perform zero canonical DB opens"
  end

  test "graceful STOP removes the owner record before a fresh process acquires" do
    dir = private_tmp!()
    canonical = Path.join(dir, "swarm_code.db")
    owner_path = Path.join(dir, "instance_owner.json")
    owner = start_probe!(dir)

    OSProcess.await_ready!(owner)
    Port.command(owner, "GO\n")
    assert :acquired = OSProcess.await_result!(owner)
    assert File.exists?(owner_path)

    Port.command(owner, "STOP\n")
    assert 0 = OSProcess.await_exit!(owner)
    refute File.exists?(owner_path)

    next = start_probe!(dir)
    OSProcess.await_ready!(next)
    Port.command(next, "GO\n")
    assert :acquired = OSProcess.await_result!(next)
    Port.command(next, "STOP\n")
    assert 0 = OSProcess.await_exit!(next)

    refute File.exists?(owner_path)
    refute File.exists?(canonical), "graceful owners must perform zero canonical DB opens"
  end

  test "a stale SIGKILL owner diagnostic neither grants nor blocks ownership" do
    dir = private_tmp!()
    canonical = Path.join(dir, "swarm_code.db")
    owner_path = Path.join(dir, "instance_owner.json")
    killed = start_probe!(dir)
    killed_pid = OSProcess.await_ready!(killed)

    Port.command(killed, "GO\n")
    assert :acquired = OSProcess.await_result!(killed)
    stale_bytes = File.read!(owner_path)
    assert %{"pid" => ^killed_pid} = Jason.decode!(stale_bytes)

    kill_exact!(killed_pid)
    assert OSProcess.await_exit!(killed) != 0
    assert File.read!(owner_path) == stale_bytes

    fresh = start_probe!(dir)
    fresh_pid = OSProcess.await_ready!(fresh)
    assert File.read!(owner_path) == stale_bytes
    Port.command(fresh, "GO\n")
    assert :acquired = OSProcess.await_result!(fresh)
    assert %{"pid" => ^fresh_pid} = owner_path |> File.read!() |> Jason.decode!()

    held = start_probe!(dir)
    OSProcess.await_ready!(held)
    Port.command(held, "GO\n")
    assert :held = OSProcess.await_result!(held)
    assert 0 = OSProcess.await_exit!(held)

    Port.command(fresh, "STOP\n")
    assert 0 = OSProcess.await_exit!(fresh)
    refute File.exists?(owner_path)
    refute File.exists?(canonical), "stale-record probes must perform zero canonical DB opens"
  end

  test "a blocked port open is cancelled before it can create a later process or lease" do
    dir = private_tmp!()
    canonical = Path.join(dir, "swarm_code.db")
    lease_path = Path.join(dir, "instance_lease.db")
    owner_path = Path.join(dir, "instance_owner.json")
    test_process = self()
    lifecycle_ref = make_ref()

    watcher =
      start_supervised!(
        {Task, fn -> open_lifecycle_watcher(test_process, lifecycle_ref) end},
        id: {:open_lifecycle_watcher, lifecycle_ref}
      )

    port_opener = fn _name, _options ->
      send(watcher, {lifecycle_ref, {:opener_blocked, self()}})

      receive do
        {^lifecycle_ref, :open} -> raise "cancelled opener resumed unexpectedly"
      end
    end

    assert_raise RuntimeError, "timed out starting lease probe", fn ->
      OSProcess.start_lease_probe!(dir,
        timeout: 100,
        lifecycle_observer: {watcher, lifecycle_ref},
        port_opener: port_opener
      )
    end

    assert_receive {^lifecycle_ref, {:owner_started, owner}}
    assert_receive {^lifecycle_ref, {:opener_blocked, opener}}
    assert_receive {^lifecycle_ref, {:opener_down, ^opener, :killed}}
    assert_receive {^lifecycle_ref, {:owner_down, :normal}}
    refute_received {^lifecycle_ref, {:opened, _owner, _port, _os_pid}}
    refute_received {^lifecycle_ref, {:external_exit, _port, _status}}
    refute File.exists?(lease_path)
    refute File.exists?(owner_path)
    refute File.exists?(canonical)
    refute owner == opener

    real_dir = private_tmp!()
    real_ref = make_ref()

    real_watcher =
      start_supervised!(
        {Task, fn -> open_lifecycle_watcher(test_process, real_ref) end},
        id: {:real_open_lifecycle_watcher, real_ref}
      )

    real_port_opener = fn _name, _options ->
      Port.open(
        {:spawn_executable, "/bin/sh"},
        [
          :binary,
          :exit_status,
          {:line, 4096},
          args: ["-c", "printf 'READY %s\\n' \"$$\"; exec /bin/cat"]
        ]
      )
    end

    assert_raise RuntimeError, "timed out starting lease probe", fn ->
      OSProcess.start_lease_probe!(real_dir,
        timeout: 1_000,
        activation_barrier: {real_watcher, real_ref},
        lifecycle_observer: {real_watcher, real_ref},
        port_opener: real_port_opener
      )
    end

    assert_receive {^real_ref, {:owner_started, real_owner}}

    assert_receive {^real_ref,
                    {:candidate_opened, ^real_owner, real_opener, real_port, real_os_pid}}

    assert_receive {^real_port, {:data, {:eol, "READY " <> ready_pid}}}
    assert Integer.to_string(real_os_pid) == ready_pid
    assert_receive {^real_ref, {:external_exit, ^real_port, real_status}}
    assert real_status != 0
    assert_receive {^real_ref, {:port_down, ^real_port, :normal}}
    assert_receive {^real_ref, {:opener_down, ^real_opener, :normal}}
    assert_receive {^real_ref, {:owner_down, :normal}}
    refute_received {^real_ref, {:activated, _owner, _opener, _port, _pid}}
    refute File.exists?(Path.join(real_dir, "instance_lease.db"))
    refute File.exists?(Path.join(real_dir, "instance_owner.json"))
    refute File.exists?(Path.join(real_dir, "swarm_code.db"))
  end

  test "a probe that never emits READY is closed and fully reaped by the protocol timeout" do
    dir = private_tmp!()
    canonical = Path.join(dir, "swarm_code.db")
    lifecycle_ref = make_ref()
    exit_barrier_ref = make_ref()
    await_ref = make_ref()
    test_process = self()

    port =
      OSProcess.start_lease_probe!(dir,
        timeout: 100,
        probe_mode: :never_ready,
        lifecycle_observer: {self(), lifecycle_ref},
        owner_exit_barrier: {self(), exit_barrier_ref}
      )

    assert_receive {^lifecycle_ref, {:opened, owner, ^port, os_pid}}
    owner_monitor = Process.monitor(owner)
    port_monitor = Port.monitor(port)

    start_supervised!(
      {Task,
       fn ->
         result =
           try do
             OSProcess.await_ready!(port)
           rescue
             error in RuntimeError -> {:raised, error.message}
           end

         send(test_process, {await_ref, result})
       end},
      id: {:never_ready_awaiter, await_ref}
    )

    assert_receive {^lifecycle_ref, {:external_exit, ^port, status}}, 1_000
    assert is_integer(os_pid) and os_pid > 0
    assert status != 0
    assert_receive {^exit_barrier_ref, {:owner_exit_blocked, ^owner}}
    refute_receive {^await_ref, _result}, 50
    send(owner, {exit_barrier_ref, :continue})
    assert_receive {^await_ref, {:raised, "timed out awaiting lease probe ready"}}
    assert_receive {:DOWN, ^port_monitor, :port, ^port, :normal}
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}
    refute File.exists?(canonical)
  end

  test "normal finalization waits for the port owner to exit after its acknowledgement" do
    dir = private_tmp!()
    lifecycle_ref = make_ref()
    exit_barrier_ref = make_ref()
    await_ref = make_ref()
    test_process = self()

    port =
      OSProcess.start_lease_probe!(dir,
        activate_after_first_event: true,
        lifecycle_observer: {self(), lifecycle_ref},
        owner_exit_barrier: {self(), exit_barrier_ref}
      )

    assert_receive {^lifecycle_ref, {:candidate_opened, owner, _opener, ^port, _os_pid}}
    assert_receive {^lifecycle_ref, {:activated, ^owner, _opener, ^port, _os_pid}}
    assert_receive {^lifecycle_ref, {:opened, owner, ^port, _os_pid}}
    owner_monitor = Process.monitor(owner)
    OSProcess.await_ready!(port)
    Port.command(port, "GO\n")
    assert :acquired = OSProcess.await_result!(port)
    Port.command(port, "STOP\n")
    assert_receive {^lifecycle_ref, {:external_exit, ^port, 0}}, 1_000
    assert_receive {^port, {:exit_status, 0}} = exit_message, 1_000

    awaiter =
      start_supervised!(
        {Task,
         fn ->
           status = OSProcess.await_exit!(port)
           send(test_process, {await_ref, status})
         end},
        id: {:normal_exit_awaiter, await_ref}
      )

    send(awaiter, exit_message)

    assert_receive {^exit_barrier_ref, {:owner_exit_blocked, ^owner}}
    refute_receive {^await_ref, _status}, 50
    send(owner, {exit_barrier_ref, :continue})
    assert_receive {^await_ref, 0}
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}
  end

  defp start_probe!(dir) do
    port = OSProcess.start_lease_probe!(dir)
    on_exit({OSProcess, port}, fn -> OSProcess.close_and_reap!(port) end)
    port
  end

  defp private_tmp! do
    dir =
      Path.join(
        System.tmp_dir!(),
        "swarm-code-cross-app-lease-os-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp kill_exact!(os_pid) do
    assert {"", 0} =
             System.cmd(
               "/bin/kill",
               ["-KILL", Integer.to_string(os_pid)],
               stderr_to_stdout: true
             )
  end

  defp open_lifecycle_watcher(test_process, lifecycle_ref) do
    open_lifecycle_watcher(test_process, lifecycle_ref, %{})
  end

  defp open_lifecycle_watcher(test_process, lifecycle_ref, monitors) do
    receive do
      {^lifecycle_ref, {:owner_started, owner} = event} ->
        monitor = Process.monitor(owner)
        send(test_process, {lifecycle_ref, event})
        open_lifecycle_watcher(test_process, lifecycle_ref, Map.put(monitors, monitor, :owner))

      {^lifecycle_ref, {:opener_blocked, opener} = event} ->
        monitor = Process.monitor(opener)
        send(test_process, {lifecycle_ref, event})

        open_lifecycle_watcher(
          test_process,
          lifecycle_ref,
          Map.put(monitors, monitor, {:opener, opener})
        )

      {^lifecycle_ref, {:candidate_opened, _owner, opener, port, _os_pid} = event} ->
        opener_monitor = Process.monitor(opener)
        port_monitor = Port.monitor(port)
        send(test_process, {lifecycle_ref, event})

        monitors =
          monitors
          |> Map.put(opener_monitor, {:opener, opener})
          |> Map.put(port_monitor, {:port, port})

        open_lifecycle_watcher(test_process, lifecycle_ref, monitors)

      {^lifecycle_ref, event} ->
        send(test_process, {lifecycle_ref, event})
        open_lifecycle_watcher(test_process, lifecycle_ref, monitors)

      {:DOWN, monitor, type, _process, reason} when type in [:process, :port] ->
        kind = Map.fetch!(monitors, monitor)

        event =
          case kind do
            :owner -> {:owner_down, reason}
            {:opener, opener} -> {:opener_down, opener, reason}
            {:port, port} -> {:port_down, port, reason}
          end

        send(test_process, {lifecycle_ref, event})
        open_lifecycle_watcher(test_process, lifecycle_ref, Map.delete(monitors, monitor))
    end
  end
end
