defmodule SwarmCode.Daemon.ShutdownTest do
  # pass70 B6 (desktop Quit parity): quitting a saved session stops what its
  # runs left behind, including a command that yielded and kept running.
  use ExUnit.Case, async: false

  alias SwarmCode.Daemon.Shutdown
  alias SwarmCode.Domain.Repo
  alias SwarmCode.Domain.Tools.BackgroundProcs

  setup do
    path = SchemaFixture.database!(:current, SwarmCode.Daemon.Test.LeaseFixture.build_root())
    start_supervised!({Repo, database: path, domain_fixture: true, pool_size: 1, log: false})
    :ok
  end

  test "quit reaps a yielded sleep 600" do
    {out, 0} = System.cmd("/bin/sh", ["-c", "/bin/sleep 600 >/dev/null 2>&1 & echo $!"])
    os_pid = out |> String.trim() |> String.to_integer()

    on_exit(fn ->
      System.cmd("/bin/kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end)

    assert alive?(os_pid)
    run_id = "shutdown-test-#{System.unique_integer([:positive])}"
    BackgroundProcs.put(run_id, [os_pid], "sleep 600")

    assert %{reaped: reaped} = Shutdown.run(teardown: false, flush_ms: 0)
    assert reaped >= 1
    assert await_dead(os_pid, 100)
    assert BackgroundProcs.list(run_id) == []
  end

  # pass71 S4: the exit summary lists what the quit stopped, so the result
  # names each live run (label, else prompt) and not only their count.
  test "quit reports every run it stopped, with its title and kind" do
    alias SwarmCode.Domain.{Conversations, Projects}
    root = Path.join(System.tmp_dir!(), "shutdown-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, project} = Projects.create(%{name: "Quit", root_path: root})
    {:ok, conv} = Conversations.create(project.id)

    runs =
      for {kind, prompt, label} <- [
            {"chat", "Fix the login test\nand more", nil},
            {"swarm", "ignored prompt", "Research caching"}
          ] do
        {:ok, run} =
          Conversations.create_run(%{
            conversation_id: conv.id,
            kind: kind,
            prompt: prompt,
            label: label,
            status: "running",
            started_at: DateTime.utc_now()
          })

        server = fake_run_server(run.id, {conv.id, kind})
        {run, server}
      end

    assert %{stopped: 2, stopped_runs: stopped} = Shutdown.run(teardown: false, flush_ms: 0)

    assert Enum.sort(Enum.map(stopped, &{&1.kind, &1.title})) == [
             {"chat", "Fix the login test\nand more"},
             {"swarm", "Research caching"}
           ]

    for {run, server} <- runs do
      assert Enum.any?(stopped, &(&1.id == run.id))
      assert_receive {:stopped, ^server}
    end
  end

  # Stands in for a RunServer: registered like one, it answers `:stop`.
  defp fake_run_server(run_id, value) do
    test = self()
    parent = self()

    pid =
      spawn_link(fn ->
        {:ok, _} = Registry.register(SwarmCode.Domain.Registry, {:run, run_id}, value)
        send(parent, {:registered, self()})

        receive do
          {:"$gen_call", from, :stop} ->
            GenServer.reply(from, :ok)
            send(test, {:stopped, self()})
        end
      end)

    assert_receive {:registered, ^pid}
    pid
  end

  defp alive?(os_pid) do
    match?(
      {_, 0},
      System.cmd("/bin/kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)
    )
  end

  # The kill is asynchronous at the OS level; wait for the pid to go away
  # (the orphaned sleep is reaped by init once it dies).
  defp await_dead(_os_pid, 0), do: false

  defp await_dead(os_pid, attempts) do
    if alive?(os_pid) do
      receive do
      after
        20 -> await_dead(os_pid, attempts - 1)
      end
    else
      true
    end
  end
end
