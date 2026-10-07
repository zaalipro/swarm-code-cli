defmodule SwarmCodeCLI.UI.Cli020.D3RuntimeTest do
  @moduledoc """
  cli020 D3: how the session runtime sends the needs-you signal by
  `terminal.notify` (bell, OSC 9, the OS notification centre) and the title.
  """
  use ExUnit.Case, async: false

  alias SwarmCodeCLI.Test.Cli020Runtime, as: R
  alias SwarmCodeCLI.UI.{SafeText, SessionRuntime}

  defp safe(words) do
    {:ok, text} = SafeText.external(words, SafeText.Limits.content())
    text
  end

  defp signal(runtime) do
    R.effect(runtime, {:bell, :needs_you})
    R.effect(runtime, {:notify_os, safe("ncode: demo needs you (approval)")})
  end

  test "auto on ghostty sends OSC 9 with the words, and no bell" do
    runtime = R.start(term_program: "ghostty")
    signal(runtime)
    assert_receive {:terminal_notify, :notification, "ncode: demo needs you (approval)"}
    refute_received {:terminal_notify, :bell, _}
  end

  test "auto on another terminal rings the bell" do
    runtime = R.start(term_program: "Apple_Terminal")
    signal(runtime)
    assert_receive {:terminal_notify, :bell, ""}
    refute_received {:terminal_notify, :notification, _}
  end

  test "os runs osascript in an owned task with the words as its argument" do
    test = self()

    runner = fn exe, args, ms ->
      send(test, {:ran, exe, args, ms})
      {:ok, 0, ""}
    end

    runtime =
      R.start(init: [notify: :os], os_type: {:unix, :darwin}, command_runner: runner)

    signal(runtime)
    assert_receive {:ran, "/usr/bin/osascript", args, 5_000}
    assert List.last(args) == "ncode: demo needs you (approval)"
    assert ~s[display notification (item 1 of argv) with title "ncode"] in args
    refute_received {:terminal_notify, :bell, _}
    refute_received {:terminal_notify, :notification, _}
    assert :sys.get_state(runtime).jobs == %{}
  end

  test "os off macOS falls back to the bell" do
    runtime = R.start(init: [notify: :os], os_type: {:unix, :linux})
    signal(runtime)
    assert_receive {:terminal_notify, :bell, ""}
  end

  test "off sends neither the bell nor the words" do
    runtime = R.start(init: [notify: :off])
    signal(runtime)
    refute_received {:terminal_notify, :bell, _}
    refute_received {:terminal_notify, :notification, _}
  end

  test "a stuck notifier is killed at its deadline" do
    runner = fn _exe, _args, _ms -> Process.sleep(:infinity) end
    runtime = R.start(init: [notify: :os], os_type: {:unix, :darwin}, command_runner: runner)
    state = signal(runtime)
    [{ref, %{task: task}}] = Map.to_list(state.jobs)
    monitor = Process.monitor(task.pid)
    send(runtime, {:job_timeout, ref})
    assert_receive {:DOWN, ^monitor, :process, _, _}
    assert :sys.get_state(runtime).jobs == %{}
    assert SessionRuntime.status(runtime).phase == :running
  end

  test "the title goes to the terminal as it is" do
    runtime = R.start()
    R.effect(runtime, {:terminal_title, safe("ncode · demo · working")})
    assert_receive {:terminal_notify, :title, "ncode · demo · working"}
  end
end
