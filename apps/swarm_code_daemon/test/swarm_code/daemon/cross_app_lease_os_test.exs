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

  test "a delayed startup reply is cancelled and fully reaped before timeout returns" do
    dir = private_tmp!()
    canonical = Path.join(dir, "swarm_code.db")
    test_process = self()
    lifecycle_ref = make_ref()

    watcher =
      start_supervised!(
        {Task, fn -> lifecycle_watcher(test_process, lifecycle_ref) end},
        id: {:startup_lifecycle_watcher, lifecycle_ref}
      )

    assert_raise RuntimeError, "timed out starting lease probe", fn ->
      OSProcess.start_lease_probe!(dir,
        timeout: 100,
        startup_barrier: {watcher, lifecycle_ref}
      )
    end

    assert_receive {^lifecycle_ref, {:opened, os_pid}}
    assert_receive {^lifecycle_ref, {:external_exit, status}}
    assert is_integer(os_pid) and os_pid > 0
    assert status != 0
    assert_receive {^lifecycle_ref, {:port_down, :normal}}
    assert_receive {^lifecycle_ref, {:owner_down, :normal}}
    refute File.exists?(canonical)
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
        lifecycle_observer: {self(), lifecycle_ref},
        owner_exit_barrier: {self(), exit_barrier_ref}
      )

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

  defp lifecycle_watcher(test_process, lifecycle_ref) do
    receive do
      {^lifecycle_ref, {:opened, owner, port, os_pid}} ->
        owner_monitor = Process.monitor(owner)
        port_monitor = Port.monitor(port)
        send(test_process, {lifecycle_ref, {:opened, os_pid}})

        watch_lifecycle(
          test_process,
          lifecycle_ref,
          owner,
          owner_monitor,
          port,
          port_monitor,
          false
        )
    end
  end

  defp watch_lifecycle(
         test_process,
         lifecycle_ref,
         owner,
         owner_monitor,
         port,
         port_monitor,
         owner_down?
       ) do
    receive do
      {^lifecycle_ref, {:external_exit, ^port, status}} ->
        send(test_process, {lifecycle_ref, {:external_exit, status}})

        watch_lifecycle(
          test_process,
          lifecycle_ref,
          owner,
          owner_monitor,
          port,
          port_monitor,
          owner_down?
        )

      {:DOWN, ^port_monitor, :port, ^port, reason} ->
        send(test_process, {lifecycle_ref, {:port_down, reason}})

        if owner_down? do
          :ok
        else
          watch_lifecycle(
            test_process,
            lifecycle_ref,
            owner,
            owner_monitor,
            port,
            port_monitor,
            owner_down?
          )
        end

      {:DOWN, ^owner_monitor, :process, ^owner, reason} ->
        send(test_process, {lifecycle_ref, {:owner_down, reason}})

        watch_lifecycle(
          test_process,
          lifecycle_ref,
          owner,
          owner_monitor,
          port,
          port_monitor,
          true
        )
    end
  end
end
