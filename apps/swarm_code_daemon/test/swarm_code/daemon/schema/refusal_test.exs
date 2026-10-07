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
end
