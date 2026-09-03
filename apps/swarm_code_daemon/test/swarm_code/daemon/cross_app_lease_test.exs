defmodule SwarmCode.Daemon.CrossAppLeaseTest do
  use ExUnit.Case, async: false

  import Bitwise

  alias Exqlite.Sqlite3
  alias SwarmCode.Daemon.CrossAppLease
  alias SwarmCode.Daemon.CrossAppLease.OwnerRecord
  alias SwarmCode.Daemon.Files.AtomicReplace
  alias SwarmCode.Daemon.Platform.ProcessIdentity
  alias SwarmCode.Daemon.StartupError

  @owner_keys ~w(
    acquired_at
    app_version
    boot_id
    database_fingerprint
    lease_nonce
    manifest_sha256
    newest_migration
    pid
    process_start_id
    product
    protocol_version
    schema_epoch
    socket_path
  )

  setup do
    dir = private_tmp!()

    opts = [
      lease_path: Path.join(dir, "instance_lease.db"),
      owner_path: Path.join(dir, "instance_owner.json"),
      identity: %ProcessIdentity{
        uid: File.lstat!(dir).uid,
        pid: 123,
        process_start_id: "test:123",
        boot_id: "test-boot"
      },
      database_fingerprint: "sha256:test-db",
      schema_contract: %{
        epoch: 0,
        newest_migration: 20_260_926_000_000,
        manifest_sha256: "408afb8e6eb422c8df50fe65536a08f853475c162d584db45b4af708274fd1d0"
      },
      socket_path: Path.join(dir, "daemon.sock"),
      app_version: "0.1.0-dev",
      ipc_nonce: "must-not-be-persisted"
    ]

    %{dir: dir, opts: opts}
  end

  test "owner records reject path and mode seams outside the typed lease input", %{opts: opts} do
    for key <- [:mode, :home, :env, :database_path] do
      assert_raise ArgumentError, fn -> OwnerRecord.new(Keyword.put(opts, key, :untrusted)) end
    end
  end

  test "one owner holds an exclusive rollback-journal lease", %{dir: dir, opts: opts} do
    assert {:ok, owner} = CrossAppLease.start_link(opts)
    assert :ok = CrossAppLease.assert_held(owner)
    assert permissions(opts[:lease_path]) == 0o600
    assert permissions(opts[:owner_path]) == 0o600
    assert temp_files(dir, ".instance_lease.db.tmp.") == []
    assert temp_files(dir, ".instance_owner.json.tmp.") == []

    record = CrossAppLease.owner(owner)
    persisted = opts[:owner_path] |> File.read!() |> Jason.decode!()

    assert Enum.sort(Map.keys(persisted)) == @owner_keys
    assert persisted == owner_map(record)
    assert persisted["protocol_version"] == 1
    assert persisted["product"] == "cli-daemon"
    assert persisted["app_version"] == opts[:app_version]
    assert persisted["pid"] == opts[:identity].pid
    assert persisted["process_start_id"] == opts[:identity].process_start_id
    assert persisted["boot_id"] == opts[:identity].boot_id
    assert persisted["database_fingerprint"] == opts[:database_fingerprint]
    assert persisted["schema_epoch"] == opts[:schema_contract].epoch
    assert persisted["newest_migration"] == opts[:schema_contract].newest_migration
    assert persisted["manifest_sha256"] == opts[:schema_contract].manifest_sha256
    assert persisted["socket_path"] == opts[:socket_path]
    assert {:ok, nonce} = Base.url_decode64(persisted["lease_nonce"], padding: false)
    assert byte_size(nonce) == 32
    assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(persisted["acquired_at"])
    refute Map.has_key?(persisted, "ipc_nonce")
    refute File.read!(opts[:owner_path]) =~ opts[:ipc_nonce]

    contender_opts = Keyword.put(opts, :identity, %{opts[:identity] | pid: 124})
    contender = Task.async(fn -> CrossAppLease.start_link(contender_opts) end)

    assert {:error,
            %StartupError{
              code: :data_lease_held,
              retryable: true,
              action: "Stop the owning runtime; never delete or force-unlock the lease."
            }} = Task.await(contender, 1_000)

    GenServer.stop(owner)
    refute File.exists?(opts[:owner_path])
    assert query_scalar(opts[:lease_path], "PRAGMA journal_mode") == "delete"
    assert {:ok, next_owner} = CrossAppLease.start_link(opts)
    GenServer.stop(next_owner)
  end

  test "an existing WAL lease is changed to verified rollback-journal mode", %{opts: opts} do
    create_lease_with_journal_mode!(opts[:lease_path], "WAL")
    assert query_scalar(opts[:lease_path], "PRAGMA journal_mode") == "wal"

    assert {:ok, owner} = CrossAppLease.start_link(opts)
    GenServer.stop(owner)

    assert query_scalar(opts[:lease_path], "PRAGMA journal_mode") == "delete"
  end

  test "wrong permissions on an existing lease fail closed without chmod", %{opts: opts} do
    File.write!(opts[:lease_path], "do not open")
    File.chmod!(opts[:lease_path], 0o644)
    before = file_identity(opts[:lease_path])

    assert {:error, %StartupError{code: :lease_failed}} = CrossAppLease.start_link(opts)
    assert file_identity(opts[:lease_path]) == before
    assert File.read!(opts[:lease_path]) == "do not open"
  end

  test "special permission bits on an existing lease fail closed without chmod", %{
    dir: dir,
    opts: opts
  } do
    for mode <- [0o4600, 0o2600, 0o1600] do
      lease_path = Path.join(dir, "instance_lease-#{Integer.to_string(mode, 8)}.db")
      mode_opts = Keyword.put(opts, :lease_path, lease_path)
      File.write!(lease_path, "do not open")
      chmod_special!(lease_path, mode)
      before = file_identity(lease_path)

      assert {:error, %StartupError{code: :lease_failed}} = CrossAppLease.start_link(mode_opts)
      assert file_identity(lease_path) == before
      assert File.read!(lease_path) == "do not open"
    end
  end

  test "a symlink lease fails closed without changing its target", %{dir: dir, opts: opts} do
    target = Path.join(dir, "lease-target")
    File.write!(target, "target contents")
    File.chmod!(target, 0o644)
    target_before = file_identity(target)
    File.ln_s!(target, opts[:lease_path])

    assert {:error, %StartupError{code: :lease_failed}} = CrossAppLease.start_link(opts)
    assert File.lstat!(opts[:lease_path]).type == :symlink
    assert File.read_link!(opts[:lease_path]) == target
    assert file_identity(target) == target_before
    assert File.read!(target) == "target contents"
  end

  test "a nonregular lease fails closed unchanged", %{opts: opts} do
    File.mkdir!(opts[:lease_path])
    File.chmod!(opts[:lease_path], 0o700)
    before = file_identity(opts[:lease_path])

    assert {:error, %StartupError{code: :lease_failed}} = CrossAppLease.start_link(opts)
    assert file_identity(opts[:lease_path]) == before
    assert File.lstat!(opts[:lease_path]).type == :directory
  end

  test "a lease with the wrong owner fails closed unchanged", %{opts: opts} do
    File.write!(opts[:lease_path], "do not open")
    File.chmod!(opts[:lease_path], 0o600)
    before = file_identity(opts[:lease_path])
    wrong_identity = %{opts[:identity] | uid: opts[:identity].uid + 1}

    assert {:error, %StartupError{code: :lease_failed}} =
             CrossAppLease.start_link(Keyword.put(opts, :identity, wrong_identity))

    assert file_identity(opts[:lease_path]) == before
    assert File.read!(opts[:lease_path]) == "do not open"
  end

  test "an owner publish failure rolls back and closes the connection and only its temp", %{
    dir: dir,
    opts: opts
  } do
    File.mkdir!(opts[:owner_path])
    sentinel = Path.join(dir, ".instance_owner.json.tmp.keep")
    File.write!(sentinel, "not ours")

    assert {:error, %StartupError{code: :lease_failed}} = CrossAppLease.start_link(opts)
    assert temp_files(dir, ".instance_owner.json.tmp.") == [sentinel]
    assert File.read!(sentinel) == "not ours"

    next_opts = Keyword.put(opts, :owner_path, Path.join(dir, "next-owner.json"))
    assert {:ok, next_owner} = CrossAppLease.start_link(next_opts)
    GenServer.stop(next_owner)
  end

  test "a fatal post-publication owner error removes its own record before releasing", %{
    dir: dir,
    opts: opts
  } do
    sync_directory = fn _directory -> {:error, :injected_directory_sync_failure} end

    failed_opts =
      Keyword.put(opts, :owner_atomic_replace_opts, sync_directory: sync_directory)

    assert {:error, %StartupError{code: :lease_failed}} = CrossAppLease.start_link(failed_opts)
    refute File.exists?(opts[:owner_path])

    next_opts = Keyword.put(opts, :owner_path, Path.join(dir, "next-owner.json"))
    assert {:ok, next_owner} = CrossAppLease.start_link(next_opts)
    GenServer.stop(next_owner)
  end

  test "graceful shutdown removes an owner record only when its nonce still matches", %{
    opts: opts
  } do
    assert {:ok, owner} = CrossAppLease.start_link(opts)
    replacement = %{"lease_nonce" => "another-owner", "product" => "desktop"}
    replacement_json = [Jason.encode_to_iodata!(replacement), "\n"]
    assert :ok = AtomicReplace.write(opts[:owner_path], replacement_json, mode: 0o600)

    GenServer.stop(owner)

    assert Jason.decode!(File.read!(opts[:owner_path])) == replacement
  end

  test "graceful shutdown leaves an oversized replacement owner record untouched", %{opts: opts} do
    assert {:ok, owner} = CrossAppLease.start_link(opts)
    replacement = String.duplicate("x", 32 * 1_024 + 1)
    File.write!(opts[:owner_path], replacement)
    File.chmod!(opts[:owner_path], 0o600)

    GenServer.stop(owner)

    assert File.read!(opts[:owner_path]) == replacement
  end

  test "owner cleanup completes while the old SQLite lease still excludes a successor", %{
    opts: opts
  } do
    test = self()

    cleanup_barrier = fn ->
      send(test, {:owner_record_cleaned, self()})

      receive do
        :continue_shutdown -> :ok
      end
    end

    assert {:ok, owner} =
             CrossAppLease.start_link(Keyword.put(opts, :cleanup_barrier, cleanup_barrier))

    stopper = Task.async(fn -> GenServer.stop(owner) end)
    assert_receive {:owner_record_cleaned, ^owner}
    refute File.exists?(opts[:owner_path])

    assert {:error, %StartupError{code: :data_lease_held}} = CrossAppLease.start_link(opts)

    send(owner, :continue_shutdown)
    assert :ok = Task.await(stopper)

    assert {:ok, successor} = CrossAppLease.start_link(opts)
    GenServer.stop(successor)
  end

  test "the lease owner cannot outlive its linked caller", %{opts: opts} do
    test = self()

    caller =
      spawn(fn ->
        {:ok, owner} = CrossAppLease.start_link(opts)
        send(test, {:linked_owner, self(), owner})

        receive do
          :stop_caller -> exit(:shutdown)
        end
      end)

    assert_receive {:linked_owner, ^caller, owner}
    assert caller in (Process.info(owner, :links) |> elem(1))
    caller_monitor = Process.monitor(caller)
    owner_monitor = Process.monitor(owner)
    send(caller, :stop_caller)

    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :shutdown}
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :shutdown}

    assert {:ok, successor} = CrossAppLease.start_link(opts)
    GenServer.stop(successor)
  end

  defp private_tmp! do
    dir =
      Path.join(
        System.tmp_dir!(),
        "swarm-code-cross-app-lease-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp owner_map(record) do
    record
    |> Map.from_struct()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp query_scalar(path, sql) do
    {:ok, conn} = Sqlite3.open(path, mode: :readonly)

    try do
      {:ok, statement} = Sqlite3.prepare(conn, sql)

      try do
        assert {:row, [value]} = Sqlite3.step(conn, statement)
        value
      after
        :ok = Sqlite3.release(conn, statement)
      end
    after
      :ok = Sqlite3.close(conn)
    end
  end

  defp create_lease_with_journal_mode!(path, mode) do
    {:ok, conn} = Sqlite3.open(path)

    try do
      {:ok, statement} = Sqlite3.prepare(conn, "PRAGMA journal_mode=#{mode}")

      try do
        assert {:row, [_mode]} = Sqlite3.step(conn, statement)
      after
        :ok = Sqlite3.release(conn, statement)
      end
    after
      :ok = Sqlite3.close(conn)
    end

    File.chmod!(path, 0o600)
  end

  defp file_identity(path) do
    stat = File.lstat!(path)
    {stat.type, stat.inode, stat.uid, band(stat.mode, 0o7777)}
  end

  defp permissions(path), do: band(File.lstat!(path).mode, 0o7777)

  defp chmod_special!(path, mode) do
    assert {"", 0} = System.cmd("/bin/chmod", [Integer.to_string(mode, 8), path])
  end

  defp temp_files(dir, prefix) do
    dir
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.map(&Path.join(dir, &1))
    |> Enum.sort()
  end
end

# Final foundation safety regressions.
defmodule SwarmCode.Daemon.CrossAppLeaseFinalFixTest do
  use ExUnit.Case, async: false

  alias SwarmCode.Daemon.CrossAppLease
  alias SwarmCode.Daemon.Platform.ProcessIdentity

  test "rejects a lease pathname substitution between validation and sqlite open" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "swarm-code-final-lease-race-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    on_exit(fn -> File.rm_rf!(dir) end)

    path = Path.join(dir, "instance_lease.db")
    parked = Path.join(dir, "parked.db")
    replacement = Path.join(dir, "replacement.db")
    File.write!(path, <<>>)
    File.chmod!(path, 0o600)
    File.write!(replacement, "replacement")
    File.chmod!(replacement, 0o600)
    uid = File.lstat!(dir).uid

    hook = fn :before_sqlite_open, ^path ->
      File.rename!(path, parked)
      File.ln_s!(replacement, path)
      :ok
    end

    opts = [
      lease_path: path,
      owner_path: Path.join(dir, "instance_owner.json"),
      identity: %ProcessIdentity{uid: uid, pid: 1, process_start_id: "final", boot_id: "final"},
      database_fingerprint: "fingerprint",
      schema_contract: %{
        epoch: 0,
        newest_migration: 1,
        manifest_sha256: String.duplicate("a", 64)
      },
      socket_path: Path.join(dir, "daemon.sock"),
      app_version: "0.1.0-dev",
      test_open_hook: hook
    ]

    assert {:error, %{code: :lease_failed}} = CrossAppLease.start_link(opts)
    assert File.read!(parked) == <<>>
    assert File.read_link!(path) == replacement
  end

  test "a lease owner detects canonical pathname replacement before handoff" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "swarm-code-final-lease-handoff-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    on_exit(fn -> File.rm_rf!(dir) end)

    uid = File.lstat!(dir).uid
    path = Path.join(dir, "instance_lease.db")
    replacement = Path.join(dir, "replacement.db")
    File.write!(replacement, "replacement")
    File.chmod!(replacement, 0o600)

    opts = [
      lease_path: path,
      owner_path: Path.join(dir, "instance_owner.json"),
      identity: %ProcessIdentity{
        uid: uid,
        pid: 1,
        process_start_id: "handoff",
        boot_id: "handoff"
      },
      database_fingerprint: "fingerprint",
      schema_contract: %{
        epoch: 0,
        newest_migration: 1,
        manifest_sha256: String.duplicate("a", 64)
      },
      socket_path: Path.join(dir, "daemon.sock"),
      app_version: "0.1.0-dev"
    ]

    assert {:ok, owner} = CrossAppLease.start_link(opts)
    monitor = Process.monitor(owner)
    File.rename!(path, path <> ".parked")
    File.ln_s!(replacement, path)

    assert {:error, :lease_identity_changed} = CrossAppLease.assert_held(owner)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
    assert File.read!(replacement) == "replacement"
  end
end
