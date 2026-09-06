# Standalone actual-production proof. Root compiles production first, then runs:
# SWARM_LEASE_PRODUCTION_ROOT=/absolute/cli/_build/prod elixir this_file.exs
# No Mix task, test-build helper, application startup or user database is used.
production_root = System.fetch_env!("SWARM_LEASE_PRODUCTION_ROOT") |> Path.expand()
Code.prepend_paths(Path.wildcard(Path.join(production_root, "lib/*/ebin")))

for application <- [:crypto, :jason, :exqlite] do
  {:ok, _started} = Application.ensure_all_started(application)
end

ExUnit.start()

defmodule SwarmCode.Daemon.CrossAppLeaseProductionProof do
  use ExUnit.Case, async: false

  alias Exqlite.{DirectoryScope, GuardedLease}
  alias SwarmCode.Daemon.CrossAppLease
  alias SwarmCode.Daemon.Platform.{PathSet, ProcessIdentity}
  alias SwarmCode.Daemon.StartupError

  setup do
    build = System.fetch_env!("SWARM_LEASE_PRODUCTION_ROOT") |> Path.expand()
    assert Path.basename(build) == "prod"
    assert Path.basename(Path.dirname(build)) == "_build"

    for module <- [CrossAppLease, PathSet, ProcessIdentity, DirectoryScope, GuardedLease] do
      assert {:module, ^module} = Code.ensure_loaded(module)
      assert String.starts_with?(List.to_string(:code.which(module)), build <> "/lib/")
    end

    refute Code.ensure_loaded?(SwarmCode.Daemon.Test.LeaseFixture)

    directory =
      Path.join(
        build,
        "native-lease-production-#{System.unique_integer([:positive, :monotonic])}"
      )

    data = Path.join(directory, "data")
    runtime = Path.join(directory, "runtime")

    for path <- [directory, data, runtime] do
      File.mkdir!(path)
      File.chmod!(path, 0o700)
    end

    on_exit(fn -> File.rm_rf!(directory) end)

    platform =
      case :os.type() do
        {:unix, :darwin} -> :macos
        {:unix, :linux} -> :linux
      end

    paths = %PathSet{
      platform: platform,
      data: data,
      config: data,
      state: data,
      cache: data,
      runtime: runtime,
      database: Path.join(data, "swarm_code.db"),
      lease: Path.join(data, "instance_lease.db"),
      owner_record: Path.join(data, "instance_owner.json"),
      socket: Path.join(runtime, "daemon.sock"),
      socket_metadata: Path.join(runtime, "daemon.json"),
      backups: Path.join(data, "backups")
    }

    opts = [
      paths: paths,
      identity: %ProcessIdentity{
        uid: File.lstat!(data).uid,
        pid: String.to_integer(System.pid()),
        process_start_id: "production-lease-proof",
        boot_id: "production-lease-proof"
      },
      database_fingerprint: "production-lease-proof",
      schema_contract: SwarmCode.Daemon.FoundationGate.schema_contract(),
      app_version: "0.1.0-dev"
    ]

    %{opts: opts, paths: paths}
  end

  test "actual production owner holds, redacts, closes and admits a successor", %{
    opts: opts,
    paths: paths
  } do
    assert {:ok, owner} = CrossAppLease.start_link(opts)
    state = :sys.get_state(owner)

    try do
      assert :ok = CrossAppLease.assert_held(owner)
      assert {:error, :directory_wrong_owner} = GuardedLease.assert_held(state.lease)
      assert {:error, :directory_wrong_owner} = DirectoryScope.close(state.scope)
      status = inspect(:sys.get_status(owner), limit: :infinity)
      refute status =~ inspect(state.scope)
      refute status =~ inspect(state.lease)
      assert File.exists?(paths.lease)
      assert File.exists?(paths.owner_record)
      refute File.exists?(paths.database)
      refute Process.whereis(SwarmCode.Repo)
    after
      GenServer.stop(owner)
    end

    assert :closed = GuardedLease.status(state.lease)
    assert :closed = DirectoryScope.status(state.scope)
    assert File.exists?(paths.lease)
    refute File.exists?(paths.owner_record)
    assert {:ok, successor} = CrossAppLease.start_link(opts)
    GenServer.stop(successor)
    refute File.exists?(paths.database)
  end

  test "production refuses every test seam and legacy option before creating files", %{
    opts: opts,
    paths: paths
  } do
    assert {:module, Exqlite.Sqlite3NIF} = Code.ensure_loaded(Exqlite.Sqlite3NIF)
    refute function_exported?(Exqlite.Sqlite3NIF, :lease_test_close_fault, 2)
    refute function_exported?(Exqlite.Sqlite3NIF, :lease_test_close_hits, 1)

    for extra <- [
          [cleanup_barrier: fn -> raise "must not run" end],
          [test_open_hook: fn _phase -> raise "must not run" end],
          [owner_atomic_replace_opts: []],
          [lease_path: paths.lease],
          [owner_path: paths.owner_record],
          [backend: :legacy],
          [ipc_nonce: "must-not-be-persisted"],
          [startup_reply: {self(), make_ref()}]
        ] do
      assert {:error, %StartupError{code: :lease_failed, retryable: false}} =
               CrossAppLease.start_link(opts ++ extra)

      refute File.exists?(paths.lease)
      refute File.exists?(paths.owner_record)
      refute File.exists?(paths.database)
    end
  end
end
