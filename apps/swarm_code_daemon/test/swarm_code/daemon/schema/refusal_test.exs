defmodule SwarmCode.Daemon.Schema.RefusalTest do
  # cli020 A4 (tui-code-1): a database a newer desktop migrated names the CLI
  # version, so the person knows which build they are running; C-FEAT-9: the
  # action is the one command that replaces it.
  use ExUnit.Case, async: true

  alias SwarmCode.Daemon.Schema.Refusal
  alias SwarmCode.Daemon.StartupError

  test "the database-ahead refusal names this CLI's version and keeps its code" do
    error = Refusal.database_ahead()
    vsn = Application.spec(:swarm_code_daemon, :vsn) |> to_string()

    assert vsn == "0.2.2"
    assert error.code == :schema_incompatible
    refute error.retryable
    assert error.message =~ "newer ncode app"

    assert error.action ==
             "Run: ncode update (then run ncode again). This ncode is " <>
               vsn <> "; the database was not changed."

    assert error.action =~ "0.2.2"
  end

  # cli020 fix S4
  test "the mode refusal names the file, the one command and keeps the code" do
    error = Refusal.database_mode("/data/swarm_code.db")

    assert error.code == :schema_incompatible
    refute error.retryable
    assert error.message =~ "permissions"
    assert error.action =~ "chmod 600 /data/swarm_code.db"
    assert error.action =~ "nothing was changed"

    # A path with a space (~/Library/Application Support/...) is quoted so the
    # command can be pasted.
    spaced =
      Refusal.database_mode("/Users/me/Library/Application Support/SwarmCode/swarm_code.db")

    assert spaced.action =~
             "chmod 600 '/Users/me/Library/Application Support/SwarmCode/swarm_code.db' "

    quoted = Refusal.database_mode("/tmp/it's.db")
    assert quoted.action =~ "chmod 600 '/tmp/it'\\''s.db' "
    # The sentence is the same for every path, the path travels in the action.
    assert Refusal.database_mode("/other/swarm_code.db").message == error.message
  end

  test "only the mode refusal carries the typed cause, for any path" do
    assert Refusal.database_mode("/data/swarm_code.db").cause == :database_mode
    assert Refusal.database_mode("/other/swarm_code.db").cause == :database_mode

    for other <- [
          Refusal.database_ahead(),
          Refusal.not_a_database(),
          Refusal.damaged(),
          Refusal.desktop_upgrade_required()
        ] do
      assert other.cause == nil
    end
  end

  test "a cause outside the closed set is refused, and there is no sentence test" do
    assert StartupError.causes() == [:database_mode]

    assert_raise FunctionClauseError, fn ->
      StartupError.new(:schema_incompatible, false, "m", "a", :invented)
    end

    assert StartupError.new(:schema_incompatible, false, "m", "a").cause == nil
    refute function_exported?(Refusal, :database_mode?, 1)
  end
end
