defmodule SwarmCode.Daemon.Platform.PathsTest do
  use ExUnit.Case, async: true

  alias SwarmCode.Daemon.Platform.Paths

  test "macOS shares the desktop database and ignores DATABASE_PATH in production" do
    home = "/Users/alice"

    assert {:ok, paths} =
             Paths.resolve(
               platform: :macos,
               mode: :production,
               home: home,
               env: %{
                 "DATABASE_PATH" => "/tmp/attacker.db",
                 "TMPDIR" => "/private/tmp/alice"
               }
             )

    assert paths.database ==
             "/Users/alice/Library/Application Support/SwarmCode/swarm_code.db"

    assert paths.lease ==
             "/Users/alice/Library/Application Support/SwarmCode/instance_lease.db"

    assert paths.owner_record ==
             "/Users/alice/Library/Application Support/SwarmCode/instance_owner.json"

    assert paths.config == "/Users/alice/Library/Application Support/SwarmCode"
    assert paths.runtime == "/private/tmp/alice/swarm-code"
  end

  test "Linux follows absolute XDG roots and has a private state fallback for runtime" do
    assert {:ok, paths} =
             Paths.resolve(
               platform: :linux,
               mode: :production,
               home: "/home/alice",
               env: %{"XDG_DATA_HOME" => "/data", "XDG_STATE_HOME" => "/state"}
             )

    assert paths.database == "/data/swarm-code/swarm_code.db"
    assert paths.config == "/home/alice/.config/swarm-code"
    assert paths.state == "/state/swarm-code"
    assert paths.runtime == "/state/swarm-code/run"
    assert paths.socket == "/state/swarm-code/run/daemon.sock"
  end

  test "relative XDG roots and alternate database paths fail closed" do
    assert {:error, :relative_xdg_path} =
             Paths.resolve(
               platform: :linux,
               mode: :production,
               home: "/home/a",
               env: %{"XDG_DATA_HOME" => "relative/data"}
             )

    assert {:error, :relative_database_path} =
             Paths.resolve(
               platform: :linux,
               mode: :recovery,
               home: "/home/a",
               env: %{},
               database_path: "relative.db"
             )
  end

  test "an alternate database is explicit and non-production only" do
    assert {:error, :alternate_database_forbidden} =
             Paths.resolve(
               platform: :linux,
               mode: :production,
               home: "/home/a",
               env: %{},
               database_path: "/tmp/a.db"
             )

    assert {:ok, paths} =
             Paths.resolve(
               platform: :linux,
               mode: :recovery,
               home: "/home/a",
               env: %{},
               database_path: "/tmp/a.db"
             )

    assert paths.database == "/tmp/a.db"
    assert paths.lease == "/tmp/instance_lease.db"
  end
end
