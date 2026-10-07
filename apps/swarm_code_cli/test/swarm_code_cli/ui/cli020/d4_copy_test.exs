defmodule SwarmCodeCLI.UI.Cli020.D4CopyTest do
  @moduledoc """
  cli020 D4 (tui-code-6): select mode's copy really copies on macOS through
  pbcopy, and says honestly what OSC 52 did elsewhere.
  """
  use ExUnit.Case, async: false

  alias SwarmCodeCLI.Test.Cli020Runtime, as: R
  alias SwarmCodeCLI.UI.SessionRuntime

  defp notice(runtime), do: SessionRuntime.snapshot(runtime).notice

  defp until_notice(runtime, attempts \\ 100)
  defp until_notice(runtime, 0), do: notice(runtime)

  defp until_notice(runtime, n) do
    case notice(runtime) do
      {:command_feedback, _} = notice -> notice
      _ -> until_notice(runtime, n - 1)
    end
  end

  defp runner(test, status) do
    fn exe, args, ms ->
      [_, _, _, file] = args
      send(test, {:ran, exe, args, ms, File.read!(file)})
      {:ok, status, ""}
    end
  end

  test "macOS outside SSH copies through pbcopy and says Copied" do
    runtime =
      R.start(os_type: {:unix, :darwin}, env: %{}, command_runner: runner(self(), 0))

    R.effect(runtime, {:copy, "one\ntwo"})
    assert_receive {:ran, "/bin/sh", ["-c", script, "ncode-copy", file], 5_000, "one\ntwo"}
    assert script =~ "/usr/bin/pbcopy"
    assert until_notice(runtime) == {:command_feedback, "Copied 2 lines."}
    refute File.exists?(file)
    refute_received {:terminal_copy, _, _, _}
  end

  test "a failing pbcopy falls back to OSC 52 and says it was sent" do
    runtime =
      R.start(os_type: {:unix, :darwin}, env: %{}, command_runner: runner(self(), 1))

    R.effect(runtime, {:copy, "one\ntwo"})
    assert_receive {:terminal_copy, 1, token, "one\ntwo"}
    send(runtime, {:terminal_copy_result, token, :ok})

    assert until_notice(runtime) ==
             {:command_feedback,
              "Sent 2 lines to the terminal clipboard; if nothing arrived, your terminal does not allow OSC 52."}
  end

  test "over SSH the copy goes straight to OSC 52" do
    runtime =
      R.start(
        os_type: {:unix, :darwin},
        env: %{"SSH_CONNECTION" => "10.0.0.1 1 10.0.0.2 22"},
        command_runner: runner(self(), 0)
      )

    R.effect(runtime, {:copy, "x"})
    assert_receive {:terminal_copy, 1, _token, "x"}
    refute_received {:ran, _, _, _, _}
  end

  test "over 64 KiB on the OSC path is refused with its reason" do
    runtime = R.start(os_type: {:unix, :linux}, env: %{})
    R.effect(runtime, {:copy, String.duplicate("a", 70_000)})

    assert until_notice(runtime) ==
             {:command_feedback, "Not copied: the terminal clipboard takes at most 64 KiB."}

    refute_received {:terminal_copy, _, _, _}
  end

  test "a terminal that never answers says it cannot take a copy from ncode" do
    runtime = R.start(os_type: {:unix, :linux}, env: %{})
    R.effect(runtime, {:copy, "x"})
    assert_receive {:terminal_copy, 1, token, "x"}
    send(runtime, {:copy_timeout, token})

    assert until_notice(runtime) ==
             {:command_feedback, "This terminal cannot take a copy from ncode."}
  end
end
