defmodule SwarmCodeCLI.Demo.TerminalTest do
  use ExUnit.Case, async: false

  test "runtime binding timeout before native Ready is a failed demo and restores the application fence" do
    native = Path.expand("../../support/terminal_wire_stalled.sh", __DIR__)

    source = """
    import ExUnit.Assertions
    alias SwarmCodeCLI.Demo.{ApplicationFence, Terminal}
    alias SwarmCodeCLI.UI.{Capabilities, Size}
    native = #{inspect(native)}
    test = self()
    # The isolated VM owns every port using this exact fixture. Capture only its
    # OS pid so the deliberately unresponsive test process is also cleaned up.
    {watcher, watcher_monitor} = spawn_monitor(fn ->
      find = fn find, attempts ->
        port = Enum.find(Port.list(), fn port ->
          Port.info(port, :name) == {:name, String.to_charlist(native)}
        end)
        cond do
          port != nil ->
            {:os_pid, pid} = Port.info(port, :os_pid)
            send(test, {:native_pid, pid})
          attempts == 0 -> raise "stalled fixture did not start"
          true -> Process.sleep(10); find.(find, attempts - 1)
        end
      end
      find.(find, 200)
    end)
    try do
      {result, audit} = ApplicationFence.run(fn ->
        caps = %Capabilities{size: %Size{columns: 80, rows: 24}}
        flags = %{alternate?: false, focus?: true, paste?: true}
        Terminal.run(caps, flags, native)
      end, timeout: :infinity)
      assert result == {:error, :terminal_failed}
      assert audit.before.started_applications == audit.after.started_applications
      assert audit.after.demo_children == 0
      assert audit.during.closure_started ==
        ~w(compiler crypto elixir inets jason kernel logger stdlib swarm_code_cli swarm_code_core)
    after
      receive do
        {:native_pid, pid} ->
          System.cmd("/bin/kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)
      after
        3000 -> raise "stalled fixture process was not tracked"
      end
      receive do
        {:DOWN, ^watcher_monitor, :process, ^watcher, :normal} -> :ok
      after
        1000 -> raise "fixture watcher did not terminate"
      end
    end
    """

    allowed =
      ~w(compiler crypto elixir inets jason kernel logger stdlib swarm_code_cli swarm_code_core ex_unit)

    paths =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.filter(&(Path.basename(&1) == "ebin"))
      |> Enum.filter(fn path ->
        directory = path |> Path.dirname() |> Path.basename()
        Enum.any?(allowed, &(directory == &1 or String.starts_with?(directory, &1 <> "-")))
      end)
      |> Enum.flat_map(&["-pa", &1])

    {output, status} =
      System.cmd(
        System.find_executable("elixir"),
        ["--erl", "-noinput"] ++ paths ++ ["-e", source],
        stderr_to_stdout: true,
        env: [{"SWARM_CODE_DEMO_AUDIT_FD", nil}]
      )

    assert status == 0, output
  end
end
