defmodule SwarmCode.Daemon.Schema.RefusalTest do
  # cli020 A4 (tui-code-1): a database a newer desktop migrated names the CLI
  # version to replace, so the person knows which build they are running.
  use ExUnit.Case, async: true

  alias SwarmCode.Daemon.Schema.Refusal

  test "the database-ahead refusal names this CLI's version and keeps its code" do
    error = Refusal.database_ahead()
    vsn = Application.spec(:swarm_code_daemon, :vsn) |> to_string()

    assert vsn == "0.2.0"
    assert error.code == :schema_incompatible
    refute error.retryable
    assert error.message =~ "newer ncode app"

    assert error.action ==
             "Install the ncode CLI that matches your ncode app (ncode --version shows this one: " <>
               vsn <> "); the database was not changed."

    assert error.action =~ "0.2.0"
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
    # The sentence is the same for every path: the launcher recognises it by
    # its message, the path travels in the action.
    assert Refusal.database_mode("/other/swarm_code.db").message == error.message
  end
end
