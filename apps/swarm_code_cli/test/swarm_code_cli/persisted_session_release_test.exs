defmodule SwarmCodeCLI.Release.PersistedSessionTest do
  # pass70 B3: failures are one human sentence plus an action and an exit
  # status, never a stack trace, never "SAVED DEV SESSION".
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias SwarmCodeCLI.Release.PersistedSession

  test "without a terminal the session refuses with a usage status and one sentence" do
    output = capture_io(:stderr, fn -> assert PersistedSession.run() == 2 end)
    assert output =~ ~r/^swarmcode: /
    refute output =~ "**"
    refute output =~ "SAVED DEV SESSION"
    refute output =~ "RuntimeError"
    assert length(String.split(String.trim(output), "\n")) <= 3
  end

  test "a failure prints the sentence and the action and returns its status" do
    failure = %{status: 3, message: "The SwarmCode app is open.", action: "Quit it."}
    output = capture_io(:stderr, fn -> assert PersistedSession.report(failure) == 3 end)
    [first, second | _] = String.split(output, "\n")
    assert first == "swarmcode: The SwarmCode app is open."
    assert second == "  Quit it."
  end

  test "a sentence that names swarmcode is not prefixed twice" do
    failure = %{status: 3, message: "swarmcode could not start.", action: "Reinstall swarmcode."}
    output = capture_io(:stderr, fn -> assert PersistedSession.report(failure) == 3 end)
    assert hd(String.split(output, "\n")) == "swarmcode: could not start."
  end

  test "the private log lives in the platform's state directory" do
    path = PersistedSession.log_path()
    assert Path.basename(path) == "cli.log"

    if match?({:unix, :darwin}, :os.type()),
      do:
        assert(
          path == Path.join([System.user_home!(), "Library", "Logs", "SwarmCode", "cli.log"])
        )
  end

  test "the test runner entry refuses outside MIX_ENV=test only" do
    # In the test build the guard passes and the terminal check answers.
    output = capture_io(:stderr, fn -> assert PersistedSession.run_for_test([]) == 2 end)
    assert output =~ "swarmcode: "
  end

  test "an unknown release mode is a usage error, never a module lookup" do
    output = capture_io(:stderr, fn -> assert PersistedSession.run_entry("Elixir.File") == 2 end)
    assert output =~ ~s(swarmcode: this build has no "Elixir.File" mode.)
  end
end
