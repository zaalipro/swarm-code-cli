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

  test "SWARM_ASCII=1 selects the ASCII glyph tier (pass70 Q12)" do
    assert PersistedSession.ascii?(%{"SWARM_ASCII" => "1"})
    refute PersistedSession.ascii?(%{"SWARM_ASCII" => "0"})
    refute PersistedSession.ascii?(%{"LANG" => "en_US.UTF-8"})
  end

  test "a stray or damaged database file is said as such (pass70 Q13)" do
    alias SwarmCode.Daemon.Schema.Refusal

    for refusal <- [Refusal.not_a_database(), Refusal.damaged()] do
      assert PersistedSession.schema_words(refusal) == {refusal.message, refusal.action}
      refute refusal.message =~ "does not know"
    end

    unknown = %{Refusal.damaged() | message: "Schema contract mismatch."}
    {general, _} = PersistedSession.schema_words(unknown)
    assert general =~ "does not know"
  end

  # pass71 S4 (R1): the exit summary names every run the quit stopped.
  test "the exit summary lists each stopped run under the count" do
    text =
      PersistedSession.stopped_lines([
        %{id: "a", kind: "chat", title: "Fix the login test\nsecond line"},
        %{id: "b", kind: "swarm", title: "Research caching"},
        %{id: "c", kind: nil, title: nil}
      ])

    pad = String.duplicate(" ", 16)

    assert text ==
             "3 live runs\n" <>
               pad <>
               "· Fix the login test\n" <>
               pad <> "· Research caching · swarm\n" <> pad <> "· Untitled run"

    assert PersistedSession.stopped_lines([%{id: "a", kind: "chat", title: "One"}]) ==
             "1 live run\n" <> pad <> "· One"
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

  # pass71 F18 (review R20): the exit summary's resume hint names the
  # conversation it closed.
  test "the resume hint names the conversation" do
    id = "3e4a58b5-0000-4000-8000-000000000001"
    here = System.get_env("PWD")
    assert PersistedSession.resume_command(here, id) == "swarmcode --resume " <> id
    assert PersistedSession.resume_command("/p/x y", id) == "swarmcode '/p/x y' --resume " <> id
    assert PersistedSession.resume_command("/p/x", nil) == "swarmcode /p/x --continue"
    assert PersistedSession.resume_command(here, "not-an-id") == "swarmcode --continue"
  end

  # pass71 F19 (review R17): an unknown --model says which model it was.
  test "an unknown model is named" do
    assert PersistedSession.unknown_model_words("gpt-9-turbo") ==
             ~s(No provider offers the model "gpt-9-turbo".)

    assert PersistedSession.unknown_model_words(nil) ==
             "No provider offers the model given with --model."
  end
end
