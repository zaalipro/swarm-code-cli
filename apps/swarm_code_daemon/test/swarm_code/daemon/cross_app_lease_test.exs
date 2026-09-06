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
      paths: SwarmCode.Daemon.Test.LeaseFixture.paths(dir),
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
      app_version: "0.1.0-dev"
    ]

    %{dir: dir, opts: opts}
  end

  test "owner records reject path and mode seams outside the typed lease input", %{opts: opts} do
    semantic =
      opts
      |> Keyword.take([:identity, :database_fingerprint, :schema_contract, :app_version])
      |> Keyword.put(:socket_path, opts[:paths].socket)

    assert %OwnerRecord{} = OwnerRecord.new(semantic)

    for key <- [:mode, :home, :env, :database_path, :paths] do
      assert_raise ArgumentError, fn ->
        OwnerRecord.new(Keyword.put(semantic, key, :untrusted))
      end
    end
  end

  test "one owner holds an exclusive rollback-journal lease", %{dir: dir, opts: opts} do
    assert {:ok, owner} = CrossAppLease.start_link(opts)
    assert :ok = CrossAppLease.assert_held(owner)
    assert permissions(opts[:paths].lease) == 0o600
    assert permissions(opts[:paths].owner_record) == 0o600
    assert temp_files(dir, ".instance_lease.db.tmp.") == []
    assert temp_files(dir, ".instance_owner.json.tmp.") == []

    record = CrossAppLease.owner(owner)
    persisted = opts[:paths].owner_record |> File.read!() |> Jason.decode!()

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
    assert persisted["socket_path"] == opts[:paths].socket
    assert {:ok, nonce} = Base.url_decode64(persisted["lease_nonce"], padding: false)
    assert byte_size(nonce) == 32
    assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(persisted["acquired_at"])
    refute Map.has_key?(persisted, "ipc_nonce")

    contender_opts = Keyword.put(opts, :identity, %{opts[:identity] | pid: 124})
    contender = Task.async(fn -> CrossAppLease.start_link(contender_opts) end)

    assert {:error,
            %StartupError{
              code: :data_lease_held,
              retryable: true,
              action: "Stop the owning runtime; never delete or force-unlock the lease."
            }} = Task.await(contender, 1_000)

    GenServer.stop(owner)
    refute File.exists?(opts[:paths].owner_record)
    assert query_scalar(opts[:paths].lease, "PRAGMA journal_mode") == "delete"
    assert {:ok, next_owner} = CrossAppLease.start_link(opts)
    GenServer.stop(next_owner)
  end

  test "native resources belong to the retained owner and copies grant no operations", %{
    opts: opts
  } do
    assert {:ok, owner} = CrossAppLease.start_link(opts)
    state = :sys.get_state(owner)
    assert {:error, :directory_wrong_owner} = Exqlite.GuardedLease.assert_held(state.lease)
    assert {:error, :directory_wrong_owner} = Exqlite.GuardedLease.close(state.lease)
    assert {:error, :directory_wrong_owner} = Exqlite.DirectoryScope.close(state.scope)
    assert :ok = CrossAppLease.assert_held(owner)
    GenServer.stop(owner)
    assert :closed = Exqlite.GuardedLease.status(state.lease)
    assert :closed = Exqlite.DirectoryScope.status(state.scope)
  end

  test "OTP status diagnostics do not expose retained native resource terms", %{opts: opts} do
    assert {:ok, owner} = CrossAppLease.start_link(opts)
    state = :sys.get_state(owner)
    status = inspect(:sys.get_status(owner), limit: :infinity)
    refute status =~ inspect(state.scope)
    refute status =~ inspect(state.lease)
    GenServer.stop(owner)
  end

  test "closed lease inputs reject legacy paths, backend selection and forged derivations", %{
    opts: opts
  } do
    for extra <- [
          [lease_path: opts[:paths].lease],
          [ipc_nonce: "secret"],
          [backend: :legacy],
          [paths: opts[:paths]],
          [startup_reply: {self(), make_ref()}]
        ] do
      assert {:error, %StartupError{code: :lease_failed}} =
               CrossAppLease.start_link(opts ++ extra)
    end

    forged = %{opts[:paths] | lease: Path.join(opts[:paths].data, "alternate.db")}

    assert {:error, %StartupError{code: :lease_failed}} =
             CrossAppLease.start_link(Keyword.put(opts, :paths, forged))

    refute File.exists?(forged.lease)
  end

  test "native SQLite transaction excludes an independent SQLite process until drain", %{
    opts: opts
  } do
    assert {:ok, owner} = CrossAppLease.start_link(opts)

    script =
      "import sqlite3,sys; c=sqlite3.connect(sys.argv[1],timeout=0); c.execute('BEGIN EXCLUSIVE'); c.close()"

    python = System.find_executable("python3") || raise "python3 required"

    {output, status} =
      System.cmd(python, ["-c", script, opts[:paths].lease], stderr_to_stdout: true)

    assert status != 0
    assert output =~ "database is locked"
    GenServer.stop(owner)

    assert {"", 0} =
             System.cmd(python, ["-c", script, opts[:paths].lease], stderr_to_stdout: true)
  end

  test "native acquire hook runs in owner, redacts failures and drains directory exclusion", %{
    opts: opts
  } do
    test_process = self()

    hook = fn :before_native_acquire ->
      send(test_process, {:native_hook_owner, self()})
      raise "secret-path-do-not-report"
    end

    assert {:error, %StartupError{code: :lease_failed} = error} =
             CrossAppLease.start_link(Keyword.put(opts, :test_open_hook, hook))

    refute error.message =~ "secret-path-do-not-report"
    assert_receive {:native_hook_owner, hook_owner}
    refute hook_owner == self()
    assert {:ok, successor} = CrossAppLease.start_link(opts)
    GenServer.stop(successor)
  end

  test "an existing WAL lease is refused without changing its bytes or mode", %{opts: opts} do
    create_lease_with_journal_mode!(opts[:paths].lease, "WAL")
    assert query_scalar(opts[:paths].lease, "PRAGMA journal_mode") == "wal"

    before = File.read!(opts[:paths].lease)
    assert {:error, %StartupError{code: :lease_failed}} = CrossAppLease.start_link(opts)
    assert File.read!(opts[:paths].lease) == before
    assert query_scalar(opts[:paths].lease, "PRAGMA journal_mode") == "wal"
  end

  test "wrong permissions on an existing lease fail closed without chmod", %{opts: opts} do
    File.write!(opts[:paths].lease, "do not open")
    File.chmod!(opts[:paths].lease, 0o644)
    before = file_identity(opts[:paths].lease)

    assert {:error, %StartupError{code: :lease_failed}} = CrossAppLease.start_link(opts)
    assert file_identity(opts[:paths].lease) == before
    assert File.read!(opts[:paths].lease) == "do not open"
  end

  test "special permission bits on an existing lease fail closed without chmod", %{
    dir: dir,
    opts: opts
  } do
    for mode <- [0o4600, 0o2600, 0o1600] do
      data = Path.join(dir, "mode-#{Integer.to_string(mode, 8)}")
      File.mkdir!(data)
      File.chmod!(data, 0o700)
      paths = SwarmCode.Daemon.Test.LeaseFixture.paths(data)
      lease_path = paths.lease
      mode_opts = Keyword.put(opts, :paths, paths)
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
    File.ln_s!(target, opts[:paths].lease)

    assert {:error, %StartupError{code: :lease_failed}} = CrossAppLease.start_link(opts)
    assert File.lstat!(opts[:paths].lease).type == :symlink
    assert File.read_link!(opts[:paths].lease) == target
    assert file_identity(target) == target_before
    assert File.read!(target) == "target contents"
  end

  test "a nonregular lease fails closed unchanged", %{opts: opts} do
    File.mkdir!(opts[:paths].lease)
    File.chmod!(opts[:paths].lease, 0o700)
    before = file_identity(opts[:paths].lease)

    assert {:error, %StartupError{code: :lease_failed}} = CrossAppLease.start_link(opts)
    assert file_identity(opts[:paths].lease) == before
    assert File.lstat!(opts[:paths].lease).type == :directory
  end

  test "a lease with the wrong owner fails closed unchanged", %{opts: opts} do
    File.write!(opts[:paths].lease, "do not open")
    File.chmod!(opts[:paths].lease, 0o600)
    before = file_identity(opts[:paths].lease)
    wrong_identity = %{opts[:identity] | uid: opts[:identity].uid + 1}

    assert {:error, %StartupError{code: :lease_failed}} =
             CrossAppLease.start_link(Keyword.put(opts, :identity, wrong_identity))

    assert file_identity(opts[:paths].lease) == before
    assert File.read!(opts[:paths].lease) == "do not open"
  end

  test "an owner publish failure rolls back and closes the connection and only its temp", %{
    dir: dir,
    opts: opts
  } do
    File.mkdir!(opts[:paths].owner_record)
    sentinel = Path.join(dir, ".instance_owner.json.tmp.keep")
    File.write!(sentinel, "not ours")

    assert {:error, %StartupError{code: :lease_failed}} = CrossAppLease.start_link(opts)
    assert temp_files(dir, ".instance_owner.json.tmp.") == [sentinel]
    assert File.read!(sentinel) == "not ours"

    if File.dir?(opts[:paths].owner_record), do: File.rmdir!(opts[:paths].owner_record)
    assert {:ok, next_owner} = CrossAppLease.start_link(opts)
    GenServer.stop(next_owner)
  end

  test "a fatal post-publication owner error removes its own record before releasing", %{
    opts: opts
  } do
    sync_directory = fn _directory -> {:error, :injected_directory_sync_failure} end

    failed_opts =
      Keyword.put(opts, :owner_atomic_replace_opts, sync_directory: sync_directory)

    assert {:error, %StartupError{code: :lease_failed}} = CrossAppLease.start_link(failed_opts)
    refute File.exists?(opts[:paths].owner_record)

    if File.dir?(opts[:paths].owner_record), do: File.rmdir!(opts[:paths].owner_record)
    assert {:ok, next_owner} = CrossAppLease.start_link(opts)
    GenServer.stop(next_owner)
  end

  test "graceful shutdown removes an owner record only when its nonce still matches", %{
    opts: opts
  } do
    assert {:ok, owner} = CrossAppLease.start_link(opts)
    replacement = %{"lease_nonce" => "another-owner", "product" => "desktop"}
    replacement_json = [Jason.encode_to_iodata!(replacement), "\n"]
    assert :ok = AtomicReplace.write(opts[:paths].owner_record, replacement_json, mode: 0o600)

    GenServer.stop(owner)

    assert Jason.decode!(File.read!(opts[:paths].owner_record)) == replacement
  end

  test "graceful shutdown leaves an oversized replacement owner record untouched", %{opts: opts} do
    assert {:ok, owner} = CrossAppLease.start_link(opts)
    replacement = String.duplicate("x", 32 * 1_024 + 1)
    File.write!(opts[:paths].owner_record, replacement)
    File.chmod!(opts[:paths].owner_record, 0o600)

    GenServer.stop(owner)

    assert File.read!(opts[:paths].owner_record) == replacement
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
    refute File.exists?(opts[:paths].owner_record)

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
    # Monitor signals are asynchronous. The call from this same sender is a
    # barrier proving the owner received the monitor before its caller exits.
    # Without it, shutdown can overtake monitor delivery and report :noproc.
    assert :ok = CrossAppLease.assert_held(owner)
    send(caller, :stop_caller)

    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :shutdown}
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :shutdown}

    assert {:ok, successor} = await_successor(opts, System.monotonic_time(:millisecond) + 2_000)
    GenServer.stop(successor)
  end

  # Native DOWN queues revocation; fresh acquisition observes actual release.
  defp await_successor(opts, deadline) do
    case CrossAppLease.start_link(opts) do
      {:error, %StartupError{code: :data_lease_held}} = held ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          await_successor(opts, deadline)
        else
          held
        end

      result ->
        result
    end
  end

  defp private_tmp! do
    dir =
      Path.join(
        SwarmCode.Daemon.Test.LeaseFixture.build_root(),
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
        SwarmCode.Daemon.Test.LeaseFixture.build_root(),
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

    hook = fn :before_native_acquire, ^path ->
      File.rename!(path, parked)
      File.ln_s!(replacement, path)
      :ok
    end

    opts = [
      paths: SwarmCode.Daemon.Test.LeaseFixture.paths(dir),
      identity: %ProcessIdentity{uid: uid, pid: 1, process_start_id: "final", boot_id: "final"},
      database_fingerprint: "fingerprint",
      schema_contract: %{
        epoch: 0,
        newest_migration: 1,
        manifest_sha256: String.duplicate("a", 64)
      },
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
        SwarmCode.Daemon.Test.LeaseFixture.build_root(),
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
      paths: SwarmCode.Daemon.Test.LeaseFixture.paths(dir),
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
      app_version: "0.1.0-dev"
    ]

    assert {:ok, owner} = CrossAppLease.start_link(opts)
    monitor = Process.monitor(owner)
    File.rename!(path, path <> ".parked")
    File.ln_s!(replacement, path)

    assert {:error, %{code: :lease_failed}} = CrossAppLease.assert_held(owner)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
    assert File.read!(replacement) == "replacement"
  end
end

defmodule SwarmCode.Daemon.PhysicalBootPathsTest do
  use ExUnit.Case, async: false
  alias SwarmCode.Daemon.Platform.PhysicalBootPaths

  test "only the supported macOS var alias is translated" do
    if :os.type() == {:unix, :darwin} do
      assert {:ok, "/private/var"} = PhysicalBootPaths.resolve("/var", :macos)
      assert {:error, _} = PhysicalBootPaths.resolve("/tmp", :macos)
      assert {:error, _} = PhysicalBootPaths.resolve("/var", :linux)
    end
  end

  test "arbitrary symlinks and native path limits refuse before admission" do
    base = SwarmCode.Daemon.Test.LeaseFixture.build_root()
    link = Path.join(base, "native-link-#{System.unique_integer([:positive])}")
    File.ln_s!(base, link)
    on_exit(fn -> File.rm!(link) end)
    assert {:error, _} = PhysicalBootPaths.resolve(link, :macos)
    assert {:error, _} = PhysicalBootPaths.resolve("/" <> String.duplicate("x", 256), :macos)
    assert {:error, _} = PhysicalBootPaths.resolve("/" <> String.duplicate("x", 4096), :macos)
    assert {:error, _} = PhysicalBootPaths.resolve(base <> "/../_build", :macos)
  end
end
