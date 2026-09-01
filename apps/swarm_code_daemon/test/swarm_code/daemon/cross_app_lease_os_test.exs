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
end
