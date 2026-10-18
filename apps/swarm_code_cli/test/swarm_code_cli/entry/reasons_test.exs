defmodule SwarmCodeCLI.Release.ReasonsTest do
  @moduledoc """
  pass76 cli-reason-codes: `-p --json` and the stream-json summary name why a
  refusal or failure happened with a stable snake_case `reason`. The word comes
  from the `StartupError` code (or a session failure's atom), never from the
  sentence; exit codes and sentences are unchanged.
  """
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  import ExUnit.CaptureLog, only: [with_log: 1]

  alias SwarmCode.Daemon.Schema.Refusal
  alias SwarmCode.Daemon.StartupError
  alias SwarmCodeCLI.Release
  alias SwarmCodeCLI.Release.{Headless, PersistedSession, Reasons}

  @readme Path.expand("../../../../../README.md", __DIR__)

  setup do
    home = Path.join(System.tmp_dir!(), "reasons-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)
    # Where the lease owner record would be read: an empty folder, not the user's.
    %{boot: [platform: :linux, mode: :production, home: home, env: %{}]}
  end

  # The failure `PersistedSession` makes of a startup refusal (it logs one line).
  defp startup(error, boot) do
    {failure, _log} = with_log(fn -> PersistedSession.startup_failure_for(error, boot) end)
    failure
  end

  # `ncode -p` in `mode` whose saved session is refused with `failure`.
  defp refuse(mode, failure) do
    {stdout, stderr} =
      with_io(:stderr, fn ->
        capture_io(fn ->
          assert Headless.run(mode,
                   project_root: System.tmp_dir!(),
                   conversation: "new",
                   with_saved_session: fn _options, _fun -> {:error, failure} end
                 ) == failure.status
        end)
      end)

    {stdout, stderr}
  end

  # {the reason word, the failure} for the refusals the contract names.
  defp refusals(boot) do
    [
      {"data_lease_held",
       startup(StartupError.new(:data_lease_held, false, "held", "wait"), boot)},
      {"desktop_open", startup(StartupError.new(:desktop_active, false, "open", "quit"), boot)},
      {"schema_incompatible", startup(Refusal.database_ahead(), boot)},
      {"database_mode", startup(Refusal.database_mode("/data/swarm_code.db"), boot)},
      {"no_provider", PersistedSession.session_failure_for(:provider_required)},
      {"startup_failed",
       startup(StartupError.new(:foundation_gate_failed, false, "m", "a"), boot)}
    ]
  end

  describe "the words" do
    test "are unique snake_case strings in sorted order" do
      words = Reasons.all()

      assert words == words |> Enum.uniq() |> Enum.sort()
      assert Enum.all?(words, &Regex.match?(~r/\A[a-z]+(_[a-z]+)*\z/, &1))
    end

    test "include the ones the contract names" do
      for word <- ~w(data_lease_held desktop_open untrusted_approval no_provider
                     schema_incompatible database_mode startup_failed run_failed
                     max_turns max_budget denied paused_workflow) do
        assert word in Reasons.all()
      end
    end

    test "get/1 raises on a key the table does not list" do
      assert Reasons.get(:max_turns) == "max_turns"
      assert_raise KeyError, fn -> Reasons.get(:not_a_reason) end
    end

    test "the README lists exactly these words" do
      [_, table] =
        Regex.run(~r/<!-- reasons:start -->(.*)<!-- reasons:end -->/s, File.read!(@readme))

      documented =
        ~r/^\| `([a-z_]+)` \|/m |> Regex.scan(table, capture: :all_but_first) |> List.flatten()

      assert Enum.sort(documented) == Reasons.all()
    end
  end

  describe "a startup refusal" do
    test "the held lease is data_lease_held", %{boot: boot} do
      error = StartupError.new(:data_lease_held, false, "held", "wait")
      failure = startup(error, boot)

      assert failure.status == 3
      assert failure.code == :data_lease_held
      assert failure.message == "Another ncode is already using your conversations."
      assert Reasons.for_failure(failure) == "data_lease_held"
    end

    test "the desktop being open is desktop_open", %{boot: boot} do
      failure = startup(StartupError.new(:desktop_active, false, "open", "quit"), boot)

      assert failure.status == 3

      assert failure.message ==
               "The ncode app is open, and only one of them can use your conversations at a time."

      assert Reasons.for_failure(failure) == "desktop_open"
    end

    test "every schema refusal but the mode one is schema_incompatible", %{boot: boot} do
      for error <- [
            Refusal.database_ahead(),
            Refusal.desktop_upgrade_required(),
            Refusal.not_a_database(),
            Refusal.damaged(),
            StartupError.new(:schema_incompatible, false, "Schema contract mismatch.", "")
          ] do
        failure = startup(error, boot)
        assert failure.status == 3
        assert Reasons.for_failure(failure) == "schema_incompatible", error.message
      end
    end

    test "the mode refusal is database_mode, whatever the path", %{boot: boot} do
      for path <- ["/data/swarm_code.db", "/Users/me/Library/Application Support/x.db"] do
        failure = startup(Refusal.database_mode(path), boot)
        assert failure.status == 3
        assert failure.message == "Your conversations database file has the wrong permissions."
        assert Reasons.for_failure(failure) == "database_mode"
      end
    end

    test "the unsafe data folder codes share data_folder_unsafe", %{boot: boot} do
      for code <- [:private_directory_failed, :path_resolution_failed, :lease_failed] do
        failure = startup(StartupError.new(code, false, "m", "a"), boot)
        assert Reasons.for_failure(failure) == "data_folder_unsafe", inspect(code)
      end
    end

    test "the other known codes have their own word", %{boot: boot} do
      for {code, word} <- [
            macos_platform_helper_unavailable: "desktop_check_failed",
            backup_failed: "backup_failed",
            backup_unverified: "backup_failed"
          ] do
        failure = startup(StartupError.new(code, true, "m", "a"), boot)
        assert Reasons.for_failure(failure) == word, inspect(code)
      end
    end

    test "a code nobody mapped is startup_failed, and so is a bare exit 3", %{boot: boot} do
      failure = startup(StartupError.new(:foundation_gate_failed, false, "m", "a"), boot)

      assert failure.status == 3
      assert Reasons.for_failure(failure) == "startup_failed"
      assert Reasons.for_failure(%{status: 3, message: "x", action: ""}) == "startup_failed"
    end

    test "storage that did not open says migration_failed or database_unavailable", %{
      boot: boot
    } do
      for reason <- [:migration_failed, :migration_timeout] do
        assert Reasons.for_failure(startup(reason, boot)) == "migration_failed"
      end

      for reason <- [:eio, {:exit, :boom}, :timeout] do
        failure = startup(reason, boot)
        assert failure.status == 3
        assert Reasons.for_failure(failure) == "database_unavailable"
      end
    end
  end

  describe "a session that could not be prepared" do
    test "maps the exit 3 refusals" do
      for {reason, word} <- [
            provider_required: "no_provider",
            endpoint_required: "no_endpoint",
            model_required: "no_model"
          ] do
        failure = PersistedSession.session_failure_for(reason)
        assert failure.status == 3
        assert Reasons.for_failure(failure) == word
      end
    end

    test "maps the exit 2 usage errors" do
      for {reason, word} <- [
            unknown_model: "unknown_model",
            conversation_not_found: "conversation_not_found",
            invalid_project: "invalid_project"
          ] do
        failure = PersistedSession.session_failure_for(reason)
        assert failure.status == 2
        assert Reasons.for_failure(failure) == word
      end

      assert Reasons.for_failure(%{status: 2, reason: :conversation_ambiguous}) ==
               "conversation_ambiguous"
    end

    test "anything else is startup_failed, or usage for exit 2" do
      {failure, _log} =
        with_log(fn -> PersistedSession.session_failure_for(:something_new) end)

      assert failure.status == 1
      assert Reasons.for_failure(failure) == "startup_failed"
      assert Reasons.for_failure(%{status: 2, message: "bad flag.", action: ""}) == "usage"
    end
  end

  describe "input never makes a word or an atom" do
    test "an unlisted code or reason falls back, listed ones still win" do
      name = "never_an_atom_#{System.unique_integer([:positive])}"

      assert Reasons.for_failure(%{code: name, status: 3}) == "startup_failed"
      assert Reasons.for_failure(%{reason: name, code: name, status: 2}) == "usage"
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end

      assert Reasons.for_failure(%{code: :nope, reason: :nope, status: 3}) == "startup_failed"
      assert Reasons.for_failure(%{code: :data_lease_held, reason: :nope}) == "data_lease_held"
      assert Reasons.for_failure(nil) == "startup_failed"
      assert Reasons.for_failure("data_lease_held") == "startup_failed"
    end
  end

  describe "the json object of a refusal" do
    test "carries the reason beside the unchanged sentence and exit code", %{boot: boot} do
      for {word, failure} <- refusals(boot) do
        {stdout, stderr} = refuse({:prompt, "hi", :json}, failure)

        # Named-device captures of concurrent tests share output: contain, not equal.
        assert stderr =~ "ncode: " <> failure.message, word

        assert %{
                 "state" => "not_started",
                 "reason" => ^word,
                 "error" => error,
                 "exit_code" => 3
               } = Jason.decode!(stdout)

        assert error == failure.message
      end
    end

    test "ends the stream-json stream with the same reason", %{boot: boot} do
      for {word, failure} <- refusals(boot) do
        {stdout, _stderr} = refuse({:prompt, "hi", :stream_json}, failure)

        assert %{"type" => "summary", "reason" => ^word, "exit_code" => 3} =
                 Jason.decode!(stdout)
      end
    end

    test "text mode still prints no object", %{boot: boot} do
      for {_word, failure} <- refusals(boot) do
        {stdout, stderr} = refuse({:prompt, "hi", :text}, failure)
        assert stdout == ""
        assert stderr =~ "ncode: " <> failure.message
      end
    end

    test "a crash is unexpected_error with exit 1" do
      {stdout, stderr} =
        with_io(:stderr, fn ->
          capture_io(fn ->
            assert Headless.run({:prompt, "hi", :json},
                     project_root: System.tmp_dir!(),
                     conversation: "new",
                     with_saved_session: fn _options, _fun -> raise "boom" end
                   ) == 1
          end)
        end)

      assert stderr =~ "ncode: ncode stopped unexpectedly (RuntimeError)."

      assert %{"reason" => "unexpected_error", "exit_code" => 1, "state" => "not_started"} =
               Jason.decode!(stdout)
    end

    test "a bare failure without a word is usage for 2 and startup_failed otherwise" do
      for {code, word} <- [{2, "usage"}, {3, "startup_failed"}, {1, "startup_failed"}] do
        out = capture_io(fn -> assert Headless.json_failure(:json, "no", code) == code end)
        assert %{"reason" => ^word, "exit_code" => ^code} = Jason.decode!(out)
      end
    end

    test "a usage error found in the release is usage" do
      {stdout, stderr} =
        with_io(:stderr, fn ->
          capture_io("", fn -> assert Release.run(["-p", "-", "--json"]) == 2 end)
        end)

      assert stderr =~ "ncode: the prompt on stdin is empty."

      assert %{"reason" => "usage", "error" => "the prompt on stdin is empty.", "exit_code" => 2} =
               Jason.decode!(stdout)
    end
  end
end
