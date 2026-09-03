# Foundation Residual Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close every Critical and Important foundation-safety finding by binding SQLite to admitted descriptors, handing a live one-use database capability to a real Ecto Repo, and making filesystem mutation and cleanup descriptor-relative, durable, supervised, and observable.

**Architecture:** A vendored Exqlite 0.39.0 fork is the only native library and owns both the POSIX filesystem resources and the guarded SQLite VFS, so a pinned descriptor can be used by the same privately bundled SQLite image. `FoundationBootstrapSupervisor` owns every capability before private paths are opened; a bounded hash-chained cleanup ledger, directory anchors, and guardians are live before any temporary namespace mutation. A supervised `DatabaseBindingOwner` carries the lease and exact main/WAL/SHM admission from read-only probe through one-shot `ReadyCapability` consumption and every initial or replacement Repo connection.

**Tech Stack:** Erlang/OTP 28.4.2, Elixir 1.18.4-otp-28, Ecto SQL 3.14.0, ecto_sqlite3 0.24.1, vendored Exqlite `0.39.0-swarm.1` from upstream `v0.39.0` commit `266b34e46b20e1c48f497cb4fb338919c793efee`, bundled SQLite 3.53.3, C/POSIX NIFs, ExUnit, target-native Mix releases.

**Spec:** `docs/superpowers/specs/2026-09-03-foundation-residual-hardening-design.md`

## Global Constraints

- Work only in `/Users/zaali/dev/swarm-code-cli-worktrees/foundation-residual-hardening` except Task 21's explicitly permitted spec-only edit to `/Users/zaali/dev/swarm-code/.specs/53_cli_shared_runtime_compatibility_spec.md`; never edit desktop implementation files.
- Execute tasks strictly in order with one implementer at a time. Each task receives a fresh independent spec-compliance review and code-quality review before the next task starts.
- Task 2 is a hard feasibility gate. If any Task 2 stop condition occurs, stop this plan, retain the failing evidence, and return to architecture design. Do not approximate the VFS with pathname or hard-link aliases.
- Target macOS 14+ and Ubuntu 22.04+, arm64 and x86_64; do not enable Erlang distribution, EPMD, HTTP, Phoenix, LiveView, Desktop, wx, or TCP.
- The only native library is the vendored `:exqlite` NIF. `swarm_code_core` remains free of Exqlite, Ecto, daemon, and native-library dependencies.
- Exqlite is exactly `0.39.0-swarm.1`, based on upstream commit `266b34e46b20e1c48f497cb4fb338919c793efee`. Its pristine `sqlite3.c` remains byte-identical with SHA-256 `87497ab605bedd0dbee27a209c1eeff8c89b229b13f921a7efdbb81a13f779fd`.
- Bundled SQLite is exactly 3.53.3 with source ID `2026-06-26 20:14:12 d4c0e51e4aeb96955b99185ab9cde75c339e2c29c3f3f12428d364a10d782c62`. `EXQLITE_USE_SYSTEM`, precompiled-NIF download, and runtime native download are forbidden.
- All filesystem capabilities and ownership receipts are opaque native resources. No raw descriptor, pointer, receipt secret, or absolute mutation pathname enters application state, logs, persistence, IPC, or `inspect/1` output.
- A basename is valid UTF-8 of 1–255 bytes and rejects NUL, slash, empty text, `.`, and `..`. Native errno conversion uses a closed atom table; unknown errno is a bounded integer.
- Product directories are exact mode `0700`; main, WAL, SHM, lease, owner record, ledger, backups, manifests, and other private files are exact mode `0600`, including special bits, and belong to the trusted UID.
- Every governed mutation has a durable intent before mutation and a durable acquired record before the `OwnedRef` leaves `AnchorOwner`. Intent-only crash windows preserve the candidate and return `cleanup_pending`; they never authorize inferred deletion.
- Cleanup history lives under a retained mode-`0700` `<state>/cleanup-v1/` directory, with one mode-`0600`, hash-chained `<ledger-id>.wal` per operation. Each operation admits at most 32 ephemeral dentries, 128 records, 4,096 encoded bytes per valid record, a 65,536-byte absolute decoder rejection ceiling, and 1,048,576 bytes per ledger. Only one namespace-mutating foundation operation is active at a time; terminal ledgers are retained/paged from `done/` rather than accumulated in memory or collapsed into one global checkpoint.
- Runtime-directory `flock` is acquired before data-directory `flock`; both are nonblocking and precede the exact adjacent rollback-journal SQLite lease transaction. Release order is the reverse after Repo and cleanup descendants stop.
- Probe main/WAL use duplicate pinned read-only descriptors. Probe code never hard-links, copies, opens, mmaps, or mutates canonical SHM; it rebuilds private SHM under a ledger-backed workspace.
- `RepoLauncher.consume/2` is the only production Ready-to-Repo route. It uses a real Ecto pool, no database pathname, and attests every initial, lazy, or replacement connection before checkout.
- The current desktop does not implement protocol v2. Concurrent desktop/CLI use remains unsupported, and no task may claim otherwise.
- Tests use task-owned temporary roots, `start_supervised!/1`, messages, monitors, deterministic native barriers, and exact OS PIDs. Do not use `Process.sleep/1`, `Process.alive?/1`, the real development database, or pathname absence as cleanup proof.
- Use `mise exec --` for authoritative commands. Every task starts RED, ends with its focused suite and commit, and the milestone ends with two clean-noise `mise exec -- mix precommit` runs plus production, native, and four-target evidence.
- No browser smoke test applies to this terminal-free foundation milestone.

---

## Locked File and Responsibility Map

```text
mix.exs
  Root preferred CLI environment, precommit aliases, and internal foundation release definition.

vendor/exqlite/
  Exact Exqlite fork, pristine-source attestations, the single NIF, guarded VFS, native resources,
  native unit tests, and build rules. sqlite3.c remains pristine.

apps/swarm_code_core/lib/swarm_code/governance/provenance.ex
  Pure policy/ledger/provenance validation only; no filesystem, daemon, Exqlite, or Ecto dependency.

apps/swarm_code_daemon/lib/swarm_code/daemon/platform/fs*.ex
  Sole product-facing wrapper around Exqlite.SwarmGuard native resources.

apps/swarm_code_daemon/lib/swarm_code/daemon/platform/private_directory.ex
  Descriptor-relative opening/creation of the retained DirectorySet.

apps/swarm_code_daemon/lib/swarm_code/daemon/foundation_supervision/
  Bootstrap/attempt/capability/operation/cleanup supervisors and registries.

apps/swarm_code_daemon/lib/swarm_code/daemon/cleanup/
  CleanupPending and stable pending-to-terminal observation.

apps/swarm_code_daemon/lib/swarm_code/daemon/cleanup_ledger/
  Per-operation bounded JSON WAL schemas, hashing, replay, terminal archival, and paged discovery.

apps/swarm_code_daemon/lib/swarm_code/daemon/namespace/
  AnchorOwner, OwnedRef, and CleanupGuardian; the only product namespace-ownership handshake.

apps/swarm_code_daemon/lib/swarm_code/daemon/cross_app_lease*.ex
  Opaque protocol-v2 config, dual locks, exact SQLite lease, owner record, assertions, and shutdown.

apps/swarm_code_daemon/lib/swarm_code/daemon/database_binding*.ex
  Pinned canonical source set, generation state machine, connection grants, and binding failure.

apps/swarm_code_daemon/lib/swarm_code/daemon/schema/
  Guarded private-workspace probe and compatibility decision; no path-only binding remains.

apps/swarm_code_daemon/lib/swarm_code/daemon/repo*.ex
  Private real Ecto Repo and the one-shot, full-pool-attesting launcher.

apps/swarm_code_daemon/lib/swarm_code/daemon/backup/
  Ledger-backed snapshot, verification, manifest-last publication, replay, and artifact result.

apps/swarm_code_daemon/lib/swarm_code/daemon/governance/
  Effectful native provenance reader and verifier composition used by the root Mix task.

apps/swarm_code_daemon/priv/schema/generate_manifest.exs
  Thin entry point; descriptor-relative generator implementation lives under lib/.

scripts/acceptance/ and scripts/ci/
  Production-boundary probes, native inspection, packaged smoke, and evidence generation.

.github/workflows/foundation-native.yml
  Required target-native sanitizer and four-target internal acceptance jobs.
```

The existing `BoundFile` hard-link alias is removed after guarded probe tests pass. Existing `DirectoryHelper`/`DirectoryBroker` may remain only until their users move under `AnchorOwner`; no unsafe fallback or raw reaper may remain at the milestone gate.

---

### Task 1: Make the Plain Precommit Command Use the Test Environment

**Files:**
- Modify: `mix.exs`

**Interfaces:**
- Produces: `SwarmCodeCLI.MixProject.cli/0 :: keyword()` returning exactly `[preferred_envs: [precommit: :test]]`.
- Preserves: the existing `precommit` alias order and all 274 current tests.

- [ ] **Step 1: Capture the existing RED result**

Run:

```bash
mise exec -- mix precommit
```

Expected: FAIL after the development compile with Mix reporting that `mix test` is running in the `dev` environment. Save the exact output in the task report; do not treat this known failure as a passing baseline.

- [ ] **Step 2: Add the root CLI environment declaration**

Add this public callback beside `project/0`:

```elixir
def cli do
  [preferred_envs: [precommit: :test]]
end
```

Do not set `MIX_ENV` inside the alias and do not reorder its commands.

- [ ] **Step 3: Run the authoritative command twice**

Run:

```bash
mise exec -- mix precommit
mise exec -- mix precommit
```

Expected both times: PASS in `MIX_ENV=test`, core 79 tests, daemon 195 tests, provenance verified, with no TLS/logger noise.

- [ ] **Step 4: Commit**

```bash
git add mix.exs
git commit -m "build: run precommit in test environment"
```

---

### Task 2: Prove the Single-Library Guarded-VFS Design Is Feasible

**Hard gate:** No Task 3 or later work starts until every GREEN command and every hard-stop assertion in this task passes. A failure produces a design-rejection report, not a pathname or hard-link workaround.

**Files:**
- Create: `vendor/exqlite/` from upstream Exqlite tag `v0.39.0`, commit `266b34e46b20e1c48f497cb4fb338919c793efee`
- Create: `vendor/exqlite/UPSTREAM.json`
- Create: `vendor/exqlite/SWARM_PATCHES.md`
- Create: `vendor/exqlite/c_src/sqlite3_swarm.c`
- Create: `vendor/exqlite/c_src/swarm_guard.h`
- Create: `vendor/exqlite/c_src/swarm_guard.c`
- Create: `vendor/exqlite/c_src/swarm_guard_vfs.c`
- Create: `vendor/exqlite/lib/exqlite/swarm_guard.ex`
- Modify: `vendor/exqlite/Makefile`
- Modify: `vendor/exqlite/mix.exs`
- Modify: `vendor/exqlite/c_src/sqlite3_nif.c`
- Modify: `apps/swarm_code_daemon/mix.exs`
- Modify: `mix.lock`
- Modify: `NOTICE`
- Test: `apps/swarm_code_daemon/test/swarm_code/daemon/platform/native_feasibility_test.exs`

**Interfaces:**
- Produces: vendored OTP application `:exqlite` version `0.39.0-swarm.1` with existing Exqlite behavior intact.
- Produces feasibility-only native calls:

```elixir
Exqlite.SwarmGuard.feasibility_admit(Path.t()) ::
  {:ok, resource()} | {:error, atom() | {:errno, non_neg_integer()}}

Exqlite.SwarmGuard.feasibility_open(resource(), Exqlite.SwarmGuard.TestBarrier.t()) ::
  {:ok, Exqlite.Sqlite3.db()} | {:error, atom() | {:errno, non_neg_integer()}}

Exqlite.SwarmGuard.connection_identity(Exqlite.Sqlite3.db()) ::
  {:ok, {:regular, non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}}

Exqlite.SwarmGuard.resource_identity(resource()) ::
  {:ok, {:regular, non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}}
```

- `sqlite3_swarm.c` contains exactly:

```c
#include "sqlite3.c"
#include "swarm_guard_vfs.c"
```

  plus required compile guards; `sqlite3.c` itself remains unchanged.

- [ ] **Step 1: Write the failing fork-attestation and descriptor-binding tests**

The test must assert all of the following before the path dependency exists:

```elixir
test "the fork is pinned and SQLite opens the admitted descriptor" do
  assert Application.spec(:exqlite, :vsn) |> to_string() == "0.39.0-swarm.1"
  assert sqlite_scalar(database, "SELECT sqlite_version()") == "3.53.3"

  assert sqlite_scalar(database, "SELECT sqlite_source_id()") ==
           "2026-06-26 20:14:12 d4c0e51e4aeb96955b99185ab9cde75c339e2c29c3f3f12428d364a10d782c62"

  admitted_application_id = sqlite_scalar(database, "PRAGMA application_id")
  assert {:ok, admitted} = Exqlite.SwarmGuard.feasibility_admit(database)
  assert {:ok, barrier} = Exqlite.SwarmGuard.TestBarrier.new(:before_vfs_main_open, self())
  task_supervisor = start_supervised!(Task.Supervisor)

  opener =
    Task.Supervisor.async_nolink(task_supervisor, fn ->
      Exqlite.SwarmGuard.feasibility_open(admitted, barrier)
    end)

  assert_receive {:native_barrier, ^barrier, :before_vfs_main_open}
  rename_original_and_install_valid_replacement(database)
  Exqlite.SwarmGuard.TestBarrier.release(barrier)
  assert {:ok, conn} = Task.await(opener)
  restore_original_name_after_vfs_open(database)
  assert {:ok, admitted_identity} = Exqlite.SwarmGuard.resource_identity(admitted)
  assert {:ok, ^admitted_identity} = Exqlite.SwarmGuard.connection_identity(conn)
  assert query_scalar(conn, "PRAGMA application_id") == admitted_application_id
end
```

Also assert SHA-256 of the unchanged working-tree `sqlite3.c` and `sqlite3.h`. Reproduce the pristine upstream input into a task-owned temporary directory from the exact Hex package and verify its `sqlite3_nif.c` against `c9e5565269829fa5ed4afccf1cb5d4cd3aa4b7ac3ed584503486cf8a64add819`; do not assert that hash against the intentionally patched working-tree `sqlite3_nif.c`. Assert normal direct `Exqlite.Sqlite3.open/2` still works for a task-owned temporary database and an `ecto_sqlite3` connection starts against a temporary fixture.

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test apps/swarm_code_daemon/test/swarm_code/daemon/platform/native_feasibility_test.exs
```

Expected: FAIL because the vendored dependency and `Exqlite.SwarmGuard` do not exist.

- [ ] **Step 3: Vendor and attest pristine Exqlite before changing it**

`UPSTREAM.json` must encode exact string keys for version, tag, commit, Hex package checksum, SQLite version/source ID, and pristine file hashes. `SWARM_PATCHES.md` must enumerate every added/changed fork file and state that third-party files are not desktop extraction entries. Retain the upstream MIT license.

Change daemon dependency to:

```elixir
{:exqlite, path: "../../vendor/exqlite", override: true}
```

Remove the Hex `exqlite` lock entry. Remove unused `cc_precompiler`; set `make_precompiler: nil`; make the build fail with a clear message whenever `EXQLITE_USE_SYSTEM` is nonempty.

- [ ] **Step 4: Add the smallest pinned-descriptor VFS proof**

The feasibility path must:

1. open the supplied test file once with `O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK`;
2. fstat it as a regular file;
3. pause at a test-only native barrier after descriptor admission and immediately before the guarded VFS `SQLITE_OPEN_MAIN_DB` action;
4. register a bounded unguessable guarded VFS token in the same native library;
5. make `SQLITE_OPEN_MAIN_DB` use `dup` of that descriptor while a valid replacement occupies the original pathname, rather than `open(path)`;
6. attest the connection's actual main identity;
7. close the connection, unregister the token, and close the descriptor explicitly.

Compile with `-Wall -Wextra -Werror` and target-native source compilation. The feasibility call is test/development-only and is replaced by typed production APIs in later tasks.

- [ ] **Step 5: Run the feasibility GREEN suite**

```bash
mise exec -- mix deps.get
mise exec -- mix test apps/swarm_code_daemon/test/swarm_code/daemon/platform/native_feasibility_test.exs
mise exec -- mix test apps/swarm_code_daemon/test/swarm_code/daemon/cross_app_lease_test.exs
mise exec -- mix test apps/swarm_code_daemon/test/swarm_code/daemon/schema/gate_test.exs
mise exec -- mix precommit
```

Expected: PASS with pristine SQLite source ID, exact admitted/connection identity, unchanged existing Exqlite/Ecto behavior, and no compiler warning.

- [ ] **Step 6: Run explicit hard-stop probes**

```bash
test "$(shasum -a 256 vendor/exqlite/c_src/sqlite3.c | awk '{print $1}')" = \
  87497ab605bedd0dbee27a209c1eeff8c89b229b13f921a7efdbb81a13f779fd
EXQLITE_USE_SYSTEM=1 mise exec -- mix compile --force
```

Expected: first command PASS; second command FAIL before compilation with the static system-SQLite prohibition.

Stop the plan if the guarded VFS cannot use the admitted descriptor, requires editing `sqlite3.c`, changes SQLite source ID, breaks Ecto/Exqlite compatibility, needs a separate NIF/shared library, needs a raw descriptor in BEAM state, leaks a native resource, blocks a normal scheduler, or needs a pathname/hard-link alias for the SQLite main open.

- [ ] **Step 7: Commit only after the hard gate passes**

```bash
git add vendor/exqlite apps/swarm_code_daemon/mix.exs mix.lock NOTICE \
  apps/swarm_code_daemon/test/swarm_code/daemon/platform/native_feasibility_test.exs
git commit -m "build: prove guarded exqlite fork feasibility"
```

---

### Task 3: Define Opaque Native Filesystem Resources and Bounded Reads

**Files:**
- Modify: `vendor/exqlite/c_src/swarm_guard.h`
- Modify: `vendor/exqlite/c_src/swarm_guard.c`
- Modify: `vendor/exqlite/c_src/sqlite3_nif.c`
- Modify: `vendor/exqlite/lib/exqlite/swarm_guard.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/platform/fs.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/platform/fs/basename.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/platform/fs/identity.ex`
- Test: `apps/swarm_code_daemon/test/swarm_code/daemon/platform/fs_test.exs`
- Test: `vendor/exqlite/test/exqlite/swarm_guard_resource_test.exs`

**Interfaces:**

```elixir
FS.basename(binary()) :: {:ok, FS.Basename.t()} | {:error, :invalid_basename}
FS.open_root(Path.t(), non_neg_integer()) :: {:ok, FS.Directory.t()} | {:error, FS.error()}
FS.open_directory(FS.Directory.t(), FS.Basename.t(), non_neg_integer(), 0o700) ::
  {:ok, FS.Directory.t()} | {:error, FS.error()}
FS.open_regular(FS.Directory.t(), FS.Basename.t(), :read | :readwrite,
  non_neg_integer(), 0o600) :: {:ok, FS.File.t()} | {:error, FS.error()}
FS.identity(FS.Directory.t() | FS.File.t()) :: {:ok, FS.Identity.t()} | {:error, FS.error()}
FS.read(FS.File.t(), pos_integer()) :: {:ok, binary()} | {:error, FS.error()}
FS.sha256(FS.File.t(), pos_integer()) :: {:ok, <<_::256>>} | {:error, FS.error()}
FS.same_dentry?(FS.Directory.t(), FS.Basename.t(), FS.File.t()) ::
  {:ok, boolean()} | {:error, FS.error()}
FS.close(resource()) :: :ok | {:error, :already_closed | FS.error()}
```

`FS.Directory.t()` and `FS.File.t()` are opaque NIF resources; `inspect/1` exposes only `#FS.Directory<opaque>` or `#FS.File<opaque>`. `FS.Identity` is a fixed semantic tuple/map with kind, device, inode, UID, exact mode, and size; callers cannot use it as mutation authority.

- [ ] **Step 1: Write RED tests for shape, races, and resource closure**

Cover valid/invalid basenames, forged terms, stale/double close, regular file and directory admission, symlink/FIFO/device refusal, wrong UID, wrong mode and special bits, unknown errno shape, bounded read, bounded incremental SHA-256, and resource count returning to baseline after every forced fstat/identity/read/hash failure.

The substitution test must use a native test barrier:

```elixir
assert {:ok, barrier} = FS.TestBarrier.new(:after_open_before_fstat, self())
task_supervisor = start_supervised!(Task.Supervisor)

task =
  Task.Supervisor.async_nolink(task_supervisor, fn ->
    FS.open_regular(dir, name, :read, uid, 0o600)
  end)

assert_receive {:native_barrier, ^barrier, :after_open_before_fstat}
replace_dentry_with_fifo_or_symlink()
FS.TestBarrier.release(barrier)
assert {:error, _closed_error} = Task.await(task)
assert FS.test_resource_counts() == baseline
```

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test apps/swarm_code_daemon/test/swarm_code/daemon/platform/fs_test.exs
```

Expected: FAIL because `SwarmCode.Daemon.Platform.FS` does not exist.

- [ ] **Step 3: Add the resource types and no-follow opens**

Use `O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW` for directories and `O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK` before fstat for entries. On Linux, attempt `openat2` with beneath/no-symlink resolution and fall back only on `ENOSYS`, `EPERM`, or seccomp denial to component-by-component `openat`/`fstatat(AT_SYMLINK_NOFOLLOW)`. macOS uses the portable path directly.

Long read/hash calls are dirty I/O NIFs with fixed 64 KiB buffers and cancellation checks. Every successful open has one explicit close path plus a destructor leak barrier. Test barriers and resource counters compile only under `SWARM_GUARD_TEST`.

- [ ] **Step 4: Run GREEN and native malformed-term stress**

```bash
mise exec -- mix test apps/swarm_code_daemon/test/swarm_code/daemon/platform/fs_test.exs
(cd vendor/exqlite && mise exec -- mix test test/exqlite/swarm_guard_resource_test.exs)
mise exec -- mix precommit
```

- [ ] **Step 5: Commit**

```bash
git add vendor/exqlite apps/swarm_code_daemon/lib/swarm_code/daemon/platform/fs* \
  apps/swarm_code_daemon/test/swarm_code/daemon/platform/fs_test.exs
git commit -m "feat: add opaque descriptor filesystem resources"
```

---

### Task 4: Add Native Owned-Entry State Machines and Atomic Mutation

**Files:**
- Modify: `vendor/exqlite/c_src/swarm_guard.h`
- Modify: `vendor/exqlite/c_src/swarm_guard.c`
- Modify: `vendor/exqlite/c_src/sqlite3_nif.c`
- Modify: `vendor/exqlite/lib/exqlite/swarm_guard.ex`
- Modify: `apps/swarm_code_daemon/lib/swarm_code/daemon/platform/fs.ex`
- Test: `apps/swarm_code_daemon/test/swarm_code/daemon/platform/fs_owned_entry_test.exs`
- Test: `vendor/exqlite/test/exqlite/swarm_guard_owned_entry_test.exs`

**Interfaces:**

```elixir
FS.create_file(FS.Directory.t(), FS.Basename.t(), non_neg_integer(), 0o600) ::
  {:ok, FS.OwnedEntry.t(), FS.File.t()} | {:error, FS.error()}
FS.create_directory(FS.Directory.t(), FS.Basename.t(), non_neg_integer(), 0o700) ::
  {:ok, FS.OwnedEntry.t(), FS.Directory.t()} | {:error, FS.error()}
FS.write(FS.File.t(), iodata(), pos_integer()) :: :ok | {:error, FS.error()}
FS.copy(FS.File.t(), FS.Directory.t(), FS.Basename.t(), non_neg_integer(), 0o600,
  pos_integer()) :: {:ok, FS.OwnedEntry.t(), FS.File.t()} | {:error, FS.error()}
FS.link(FS.File.t(), FS.Directory.t(), FS.Basename.t()) ::
  {:ok, FS.OwnedEntry.t()} | {:error, FS.error()}
FS.rename(FS.OwnedEntry.t(), FS.Directory.t(), FS.Basename.t(), :no_replace | :replace) ::
  {:ok, FS.OwnedEntry.t()} | {:error, FS.error()}
FS.unlink(FS.OwnedEntry.t()) :: :ok | {:error, FS.error()}
FS.fsync(FS.File.t() | FS.Directory.t()) :: :ok | {:error, FS.error()}
FS.receipt_facts(FS.OwnedEntry.t()) :: {:ok, FS.ReceiptFacts.t()} | {:error, FS.error()}
```

Rename consumes and invalidates the source receipt and returns a destination receipt. Unlink consumes the exact live receipt. Copying a BEAM resource term cannot authorize a second mutation after either operation.

- [ ] **Step 1: Write the receipt RED suite**

Test exclusive file/directory creation, `linkat`, no-clobber rename, replacement rename, file/directory fsync, exact `0600`/`0700`, short writes, disk/full and injected fsync failures, directory rename while the descriptor stays live, cross-directory receipt misuse, copied-term double use, dentry substitution, same-inode foreign hard link, and forged/malformed arguments.

Assert this invariant directly:

```elixir
assert {:ok, published} = FS.rename(staging, output_dir, output_name, :no_replace)
assert {:error, :stale_owned_entry} = FS.unlink(staging)
assert :ok = FS.unlink(published)
assert {:error, :stale_owned_entry} = FS.unlink(published)
```

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test apps/swarm_code_daemon/test/swarm_code/daemon/platform/fs_owned_entry_test.exs
```

Expected: FAIL because ownership-changing APIs do not exist.

- [ ] **Step 3: Add exact syscall-to-receipt transitions**

Mint `FS.OwnedEntry` only in the successful native syscall result. Store the retained directory resource, basename, generation nonce, exact dentry identity, class, and state in native memory. Never mint/adopt from caller-supplied identity or post-operation `lstat`. Use `renameat2(RENAME_NOREPLACE)` on Linux and `renameatx_np(RENAME_EXCL)` on macOS for no-clobber publication. If the required primitive is unavailable on a supported target, fail the native feasibility/target gate; never degrade to overwrite or a pathname check-then-rename.

- [ ] **Step 4: Run GREEN**

```bash
mise exec -- mix test apps/swarm_code_daemon/test/swarm_code/daemon/platform/fs_owned_entry_test.exs
(cd vendor/exqlite && mise exec -- mix test test/exqlite/swarm_guard_owned_entry_test.exs)
mise exec -- mix precommit
```

- [ ] **Step 5: Commit**

```bash
git add vendor/exqlite apps/swarm_code_daemon/lib/swarm_code/daemon/platform/fs.ex \
  apps/swarm_code_daemon/test/swarm_code/daemon/platform/fs_owned_entry_test.exs
git commit -m "feat: mint native filesystem ownership receipts"
```

---

### Task 5: Open Private Directory Chains and Close Typed Boot Inputs

**Files:**
- Modify: `apps/swarm_code_daemon/lib/swarm_code/daemon/platform/private_directory.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/platform/fs/directory_set.ex`
- Modify: `apps/swarm_code_daemon/lib/swarm_code/daemon/platform/path_set.ex`
- Modify: `apps/swarm_code_daemon/lib/swarm_code/daemon/platform/paths.ex`
- Modify: `apps/swarm_code_daemon/lib/swarm_code/daemon/foundation_gate/boot_config.ex`
- Create: `apps/swarm_code_daemon/test/support/boot_config_factory.ex`
- Modify: `apps/swarm_code_daemon/test/swarm_code/daemon/platform/private_directory_test.exs`
- Modify: `apps/swarm_code_daemon/test/swarm_code/daemon/platform/paths_test.exs`

**Interfaces:**

```elixir
BootConfig.current() :: {:ok, BootConfig.t()} | {:error, StartupError.t()}
BootConfig.test(keyword()) :: BootConfig.t() # compiled only under MIX_ENV=test
PrivateDirectory.open_chain(BootConfig.t(), non_neg_integer()) ::
  {:ok, FS.DirectorySet.t()} | {:error, StartupError.t()}
```

`DirectorySet` retains data, config, state, cache, runtime, backups, and probe-workspace-parent descriptors plus validated canonical display paths. Production `BootConfig` cannot be built from arbitrary caller home/env/path values.

- [ ] **Step 1: Add failing component-race and production-shape tests**

Extend existing tests with barriers immediately before each `mkdirat` and child `openat`. Rename/replace the parent and assert creation stays under the held original or refuses without mutating the replacement. Add existing wrong-mode/special-bit directory refusals and ensure newly created wrong-mode directories are cleaned only through their receipt.

Add a static production boundary assertion that `BootConfig.current/0` exists while `BootConfig.canonical/3` and public arbitrary constructors do not.

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test \
  apps/swarm_code_daemon/test/swarm_code/daemon/platform/private_directory_test.exs \
  apps/swarm_code_daemon/test/swarm_code/daemon/platform/paths_test.exs
```

Expected: FAIL on the injected mutation boundary and missing `open_chain/2`/`current/0` contract.

- [ ] **Step 3: Replace pathname creation with retained descriptor traversal**

Open the approved physical root once, then use `fstatat`, `mkdirat`, open, and fstat one component at a time. Existing predictable wrong-mode directories fail unchanged. A just-created invalid empty directory is removable only through its `OwnedEntry`. Preserve the narrowly audited macOS physical-root handling; do not add a general symlink exception.

Read actual process XDG variables once inside `BootConfig.current/0`. Preserve canonical macOS and Ubuntu paths and production rejection/ignoring of `DATABASE_PATH`.

- [ ] **Step 4: Run GREEN**

```bash
mise exec -- mix test \
  apps/swarm_code_daemon/test/swarm_code/daemon/platform/private_directory_test.exs \
  apps/swarm_code_daemon/test/swarm_code/daemon/platform/paths_test.exs
mise exec -- mix precommit
```

- [ ] **Step 5: Commit**

```bash
git add apps/swarm_code_daemon/lib/swarm_code/daemon/platform \
  apps/swarm_code_daemon/lib/swarm_code/daemon/foundation_gate/boot_config.ex \
  apps/swarm_code_daemon/test/support/boot_config_factory.ex \
  apps/swarm_code_daemon/test/swarm_code/daemon/platform
git commit -m "feat: retain descriptor-bound private directory chains"
```

---

### Task 6: Establish Foundation and Cleanup Supervision Before Capabilities Open

**Files:**
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/application.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/foundation_supervision/bootstrap_supervisor.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/foundation_supervision/safety_supervisor.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/foundation_supervision/capability_owner.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/foundation_supervision/cleanup_owner_supervisor.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/foundation_supervision/operation_supervisor.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/cleanup/pending.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/cleanup/registry.ex`
- Modify: `apps/swarm_code_daemon/lib/swarm_code/daemon/startup_error.ex`
- Modify: `apps/swarm_code_daemon/mix.exs`
- Test: `apps/swarm_code_daemon/test/swarm_code/daemon/foundation_supervision_test.exs`

**Interfaces:**

```elixir
FoundationBootstrapSupervisor.start_attempt(BootConfig.t()) ::
  {:ok, attempt_id :: binary()} | {:error, StartupError.t()}
CapabilityOwner.directory_set(attempt_id) :: {:ok, FS.DirectorySet.t()} | {:error, atom()}
Cleanup.Registry.status(cleanup_id) ::
  {:ok, :pending | :cleaned | :preserved_ambiguous | :failed_terminal} | {:error, :unknown_cleanup}
Cleanup.Registry.subscribe(cleanup_id) :: :ok | {:error, :unknown_cleanup}
Cleanup.Registry.await(cleanup_id, timeout()) :: {:ok, atom()} | {:error, :timeout}
```

`StartupError` gains optional `cleanup: nil | %Cleanup.Pending{}`; `Pending` validates a canonical UUID, a closed kind, and state `:pending`. It contains no PID, Port, path, or receipt.

- [ ] **Step 1: Write RED supervision tests**

Assert the exact child order starts the attempt supervisor and `CapabilityOwner` before any directory open observer event. Kill caller/capability opener at every opening barrier and assert the attempt supervisor closes partial native resources. Test bounded pending caller settlement, registry subscription, terminal transition, attempt shutdown, and rejection of forged cleanup values.

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test apps/swarm_code_daemon/test/swarm_code/daemon/foundation_supervision_test.exs
```

Expected: FAIL because no application-owned foundation supervision exists.

- [ ] **Step 3: Add the supervision skeleton and typed error field**

Configure `SwarmCode.Daemon.Application` as the daemon OTP application callback. Use supervisors/DynamicSupervisors and Registry; do not use raw spawn or detached Task ownership. The attempt reference is an opaque UUID lookup, never a native resource returned to the caller.

- [ ] **Step 4: Run GREEN**

```bash
mise exec -- mix test apps/swarm_code_daemon/test/swarm_code/daemon/foundation_supervision_test.exs
mise exec -- mix precommit
```

- [ ] **Step 5: Commit**

```bash
git add apps/swarm_code_daemon/lib/swarm_code/daemon/application.ex \
  apps/swarm_code_daemon/lib/swarm_code/daemon/foundation_supervision \
  apps/swarm_code_daemon/lib/swarm_code/daemon/cleanup \
  apps/swarm_code_daemon/lib/swarm_code/daemon/startup_error.ex \
  apps/swarm_code_daemon/mix.exs \
  apps/swarm_code_daemon/test/swarm_code/daemon/foundation_supervision_test.exs
git commit -m "feat: supervise foundation capabilities and cleanup"
```

---

### Task 7: Add the Bounded Hash-Chained Cleanup Ledger

**Files:**
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/cleanup_ledger/record.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/cleanup_ledger/codec.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/cleanup_ledger/store.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/cleanup_ledger/manager.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/cleanup_ledger/replay.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/cleanup_ledger/discovery.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/cleanup_ledger/operation.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/cleanup_ledger/recovery_authority.ex`
- Modify: `apps/swarm_code_daemon/lib/swarm_code/daemon/foundation_supervision/safety_supervisor.ex`
- Modify: `apps/swarm_code_daemon/lib/swarm_code/daemon/foundation_supervision/capability_owner.ex`
- Modify: `apps/swarm_code_daemon/lib/swarm_code/daemon/platform/fs.ex`
- Modify: `vendor/exqlite/c_src/swarm_guard.h`
- Modify: `vendor/exqlite/c_src/swarm_guard.c`
- Modify: `vendor/exqlite/c_src/sqlite3_nif.c`
- Modify: `vendor/exqlite/lib/exqlite/swarm_guard.ex`
- Test: `apps/swarm_code_daemon/test/swarm_code/daemon/cleanup_ledger/codec_test.exs`
- Test: `apps/swarm_code_daemon/test/swarm_code/daemon/cleanup_ledger/store_test.exs`
- Test: `apps/swarm_code_daemon/test/swarm_code/daemon/cleanup_ledger/replay_test.exs`
- Test: `vendor/exqlite/test/exqlite/swarm_guard_recovery_authority_test.exs`

**Interfaces:**

```elixir
CleanupLedger.Manager.begin(manager, operation_id, operation_kind) ::
  {:ok, CleanupLedger.Operation.t()} | {:error, :cleanup_ledger_full | :cleanup_ledger_corrupt}
CleanupLedger.Store.append_intent(operation, map()) :: {:ok, sequence()} | {:error, atom()}
CleanupLedger.Store.append_acquired(operation, sequence(), FS.ReceiptFacts.t()) ::
  :ok | {:error, atom()}
CleanupLedger.Store.transition(operation, :cleaned | :preserved_ambiguous | :committed | :failed_terminal) ::
  :ok | {:error, atom()}
CleanupLedger.Store.recovery_authority(store, operation_id, acquired_sequence) ::
  {:ok, CleanupLedger.RecoveryAuthority.t()} | {:error, :cleanup_ledger_corrupt | :not_acquired}
CleanupLedger.Store.archive(operation) :: :ok | {:error, atom()}
CleanupLedger.Replay.read(FS.File.t()) :: {:ok, replay_state()} | {:error, :cleanup_ledger_corrupt}
CleanupLedger.Discovery.page(manager, cursor, 1..128) ::
  {:ok, %{entries: [map()], next_cursor: binary() | nil}} | {:error, atom()}
```

Every record has exactly string keys `version`, `sequence`, `operation_id`, `transition`, `prior_sha256`, `body`, and `sha256`. Record schemas are closed; runtime text never becomes an atom.

- [ ] **Step 1: Write codec and state-machine RED tests**

Cover exact canonical JSON encoding, duplicate/extra/missing keys, invalid UUID, unknown transitions, 4,096-byte valid maximum, 65,536-byte decoder rejection, broken prior hash, wrong record hash, skipped/duplicate sequence, torn final line, nonfinal partial record, impossible transition, and no attacker text in errors. Prove replay cannot return a recovery authority for intent-only, corrupt, terminal-cleaned, mismatched-operation, or mismatched-sequence state; one verified durable acquired record mints exactly one one-use recovery authority.

Store tests require `CapabilityOwner` to establish exact mode-`0700` `cleanup-v1/` and `cleanup-v1/done/` retained directories before `Manager` starts a distinct exact mode-`0600` `<ledger-id>.wal` for each operation. Existing symlink, nondirectory, wrong-owner, wrong-mode, or special-bit ledger directories fail closed without repair. The ledger ID is a new canonical UUID independent of the operation ID. Ledger creation is file- and directory-fsynced before the first governed mutation. Each store verifies its declared worst-case transition sequence fits 1,048,576 bytes, 32 dentries, and 128 total records including header/terminal; it rejects overflow before mutation and fsyncs every append. The manager allows only one active mutation operation while cursor-paging at most 128 terminal ledger names and retaining at most 256 summaries/1,048,576 aggregate bytes in memory.

Archive tests retain the complete verified ledger and move it from `cleanup-v1/<ledger-id>.wal` to `cleanup-v1/done/<ledger-id>.wal` only after a valid terminal record, ledger fsync, descriptor-relative no-clobber rename, and fsync of both source and destination directories. There is no checkpoint compaction. A committed ledger retains the operation ID, final database/manifest receipt facts and digests, manifest hash, and verification summary required for duplicate-operation admission while either artifact exists. A crash during the move replays from exactly one valid location; two occupants or substitution yield `cleanup_pending` without overwrite/deletion. One operation's capacity never blocks a later distinct ledger except when an ambiguous/corrupt active operation still blocks the single mutation slot or a real filesystem/durability failure occurs.

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test apps/swarm_code_daemon/test/swarm_code/daemon/cleanup_ledger
```

Expected: FAIL because cleanup ledger modules do not exist.

- [ ] **Step 3: Add exact codecs, reservation accounting, and replay**

Use `SwarmCode.Protocol.JsonLimits` for bounded JSON admission while applying the tighter ledger limits. Open retained `<state>/cleanup-v1/` and `done/` directories through `FS`; no `File.open` fallback. One supervised `Store` owns each active `<ledger-id>.wal`, updates its hash chain only after write and file fsync succeed, and makes repeated identical acquired records idempotent. Corrupt/ambiguous active ledgers are never truncated or compacted. `Manager` keeps only the active operation and a bounded terminal-page cache; discovery uses retained directory-stream cursors, may idempotently revisit but never skip an entry, and demand-loads one ledger at a time.

`RecoveryAuthority` is a distinct opaque, one-use native cleanup resource; it is not a reconstructed `FS.OwnedEntry`. `LedgerStore` asks the native layer to mint it only after replay verifies the durable acquired record and exact operation/sequence/receipt facts. It authorizes identity-checked unlink only, never rename, publication, or additional ownership. A native `OwnedEntry` dying with the VM does not survive or silently recreate authority.

- [ ] **Step 4: Run GREEN**

```bash
mise exec -- mix test apps/swarm_code_daemon/test/swarm_code/daemon/cleanup_ledger
(cd vendor/exqlite && mise exec -- mix test test/exqlite/swarm_guard_recovery_authority_test.exs)
mise exec -- mix precommit
```

- [ ] **Step 5: Commit**

```bash
git add vendor/exqlite apps/swarm_code_daemon/lib/swarm_code/daemon/cleanup_ledger \
  apps/swarm_code_daemon/lib/swarm_code/daemon/foundation_supervision/safety_supervisor.ex \
  apps/swarm_code_daemon/lib/swarm_code/daemon/foundation_supervision/capability_owner.ex \
  apps/swarm_code_daemon/lib/swarm_code/daemon/platform/fs.ex \
  apps/swarm_code_daemon/test/swarm_code/daemon/cleanup_ledger
git commit -m "feat: persist bounded cleanup ownership transitions"
```

---

### Task 8: Put Namespace Anchors and Guardians Around Every Receipt

**Files:**
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/namespace/anchor_supervisor.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/namespace/anchor_owner.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/namespace/create_spec.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/namespace/owned_ref.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/namespace/guardian_supervisor.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/namespace/cleanup_guardian.ex`
- Modify: `apps/swarm_code_daemon/lib/swarm_code/daemon/foundation_supervision/safety_supervisor.ex`
- Test: `apps/swarm_code_daemon/test/swarm_code/daemon/namespace/anchor_owner_test.exs`
- Test: `apps/swarm_code_daemon/test/swarm_code/daemon/namespace/cleanup_guardian_test.exs`

**Interfaces:**

```elixir
AnchorSupervisor.start_anchor(attempt_id, directory, operation) :: {:ok, anchor_id}
AnchorOwner.create(anchor_id, Namespace.CreateSpec.t()) ::
  {:ok, Namespace.OwnedRef.t()} | {:error, atom()}
AnchorOwner.rename(anchor_id, owned_ref, basename, mode) ::
  {:ok, Namespace.OwnedRef.t()} | {:error, atom()}
AnchorOwner.unlink(anchor_id, owned_ref) :: :ok | {:error, atom()}
AnchorOwner.recover_unlink(anchor_id, CleanupLedger.RecoveryAuthority.t()) ::
  :ok | {:error, atom()}
AnchorOwner.fsync(anchor_id) :: :ok | {:error, atom()}
CleanupGuardian.abort(guardian_id, reason) :: :ok | {:error, Cleanup.Pending.t()}
CleanupGuardian.status(guardian_id) :: :pending | :cleaned | :preserved_ambiguous | :failed_terminal
```

`AnchorOwner.create/2` enforces the complete intent → native mutation → acquired fsync → `OwnedRef` reply handshake. `OwnedRef` is attempt/operation/generation scoped and cannot be serialized or used directly with `FS`.

`Namespace.CreateSpec` is a closed union constructed only by checked functions:

```elixir
CreateSpec.file(entry_class, FS.Basename.t(), iodata(), maximum_bytes, 0o600)
CreateSpec.directory(entry_class, FS.Basename.t(), 0o700)
CreateSpec.copy(entry_class, FS.File.t(), FS.Basename.t(), maximum_bytes, 0o600)
CreateSpec.link(entry_class, FS.File.t(), FS.Basename.t())
```

It validates class, basename, mode, and bound before the GenServer call. `AnchorOwner` pattern-matches this union and invokes the corresponding `FS` operation itself; it never executes a caller-supplied function, module, MFA, callback, or raw NIF operation.

- [ ] **Step 1: Write RED ownership-handshake tests**

Use deterministic barriers at: after intent fsync, after native mutation before receipt handling, after receipt arrival before acquired append, after acquired fsync before worker reply, and during unlink. Kill the worker/anchor/store/guardian at each point.

Assert:

- intent-only candidates are preserved and registry becomes `:preserved_ambiguous`;
- acquired candidates are exact-cleaned after worker death;
- replacing the dentry preserves the replacement;
- renaming the held directory does not redirect cleanup;
- a replacement directory at the old path remains unchanged;
- canonical-path absence is never reported as cleaned;
- anchor restart retries the same acquired record idempotently, then uses a distinct one-shot recovery authority minted from that verified durable acquired record rather than pretending the dead VM's native `OwnedEntry` survived;
- intent-only, mismatched, copied, and already-consumed recovery authorities cannot unlink;
- a random 256-bit operation marker follows the same handshake.

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test apps/swarm_code_daemon/test/swarm_code/daemon/namespace
```

Expected: FAIL because anchor and guardian ownership do not exist.

- [ ] **Step 3: Add the namespace owner and guardian**

Only `AnchorOwner` retains native receipts. Workers receive `OwnedRef`; all mutation calls round-trip through the anchor. `CleanupGuardian` monitors anchor, ledger, and worker independently and publishes one monotonic registry transition. Bounded restart relocation searches only beneath the still-identical recorded parent for exactly one matching directory identity plus acquired marker; zero/multiple matches remain pending. In-VM cleanup uses the original live `OwnedEntry`; post-VM replay can only call `recover_unlink/2` with the separate one-shot authority returned by `LedgerStore.recovery_authority/3` after full hash-chain/acquired verification.

- [ ] **Step 4: Run GREEN**

```bash
mise exec -- mix test apps/swarm_code_daemon/test/swarm_code/daemon/namespace
mise exec -- mix precommit
```

- [ ] **Step 5: Commit**

```bash
git add apps/swarm_code_daemon/lib/swarm_code/daemon/namespace \
  apps/swarm_code_daemon/lib/swarm_code/daemon/foundation_supervision/safety_supervisor.ex \
  apps/swarm_code_daemon/test/swarm_code/daemon/namespace
git commit -m "feat: guard native namespace ownership receipts"
```

---

### Task 9: Move Port and Helper Reapers Under Observable Supervision

**Files:**
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/cleanup/process_owner.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/cleanup/port_owner.ex`
- Modify: `apps/swarm_code_daemon/lib/swarm_code/daemon/platform/external_command.ex`
- Modify: `apps/swarm_code_daemon/lib/swarm_code/daemon/platform/directory_helper.ex`
- Modify: `apps/swarm_code_daemon/test/swarm_code/daemon/platform/external_command_test.exs`
- Modify: `apps/swarm_code_daemon/test/swarm_code/daemon/platform/directory_helper_test.exs`
- Test: `apps/swarm_code_daemon/test/swarm_code/daemon/cleanup/owner_test.exs`

**Interfaces:**

```elixir
CleanupOwnerSupervisor.start_process_owner(cleanup_id, request) :: {:ok, pid()}
CleanupOwnerSupervisor.start_port_owner(cleanup_id, request) :: {:ok, pid()}
ExternalCommand.run(Path.t(), [String.t()], keyword()) ::
  {:ok, String.t()} | {:error, atom() | Cleanup.Pending.t()}
DirectoryHelper.stop(DirectoryHelper.t()) :: :ok | {:error, Cleanup.Pending.t()}
```

- [ ] **Step 1: Convert existing pending tests to demand stable observation**

Change stalled-stop/signal-failure assertions so the caller receives `%Cleanup.Pending{id: id}` within its deadline, then subscribes to `Cleanup.Registry`, releases the deterministic stall, and receives exactly one terminal transition before the supervised owner disappears.

Add supervisor-shutdown tests proving TERM, bounded grace, KILL, exact Port exit, OS PID/process-group terminal evidence, and owner exit occur in order.

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test \
  apps/swarm_code_daemon/test/swarm_code/daemon/platform/external_command_test.exs \
  apps/swarm_code_daemon/test/swarm_code/daemon/platform/directory_helper_test.exs \
  apps/swarm_code_daemon/test/swarm_code/daemon/cleanup/owner_test.exs
```

Expected: FAIL because current raw reapers are demonitorable and unobservable.

- [ ] **Step 3: Replace raw owners with supervised children**

Move exact Port/PID/process-group state into `ProcessOwner`/`PortOwner`. Caller timeouts return pending without demonitoring the cleanup owner. Remove raw `spawn_monitor` reaper loops and infinite caller waits. Directory helper namespace deletion remains transitional until Tasks 16–17 move it to `AnchorOwner`; it may not mint ownership from expected names.

- [ ] **Step 4: Run GREEN**

```bash
mise exec -- mix test \
  apps/swarm_code_daemon/test/swarm_code/daemon/platform/external_command_test.exs \
  apps/swarm_code_daemon/test/swarm_code/daemon/platform/directory_helper_test.exs \
  apps/swarm_code_daemon/test/swarm_code/daemon/cleanup/owner_test.exs
mise exec -- mix precommit
```

- [ ] **Step 5: Commit**

```bash
git add apps/swarm_code_daemon/lib/swarm_code/daemon/cleanup \
  apps/swarm_code_daemon/lib/swarm_code/daemon/platform/external_command.ex \
  apps/swarm_code_daemon/lib/swarm_code/daemon/platform/directory_helper.ex \
  apps/swarm_code_daemon/test/swarm_code/daemon/cleanup \
  apps/swarm_code_daemon/test/swarm_code/daemon/platform
git commit -m "fix: supervise and expose pending process cleanup"
```

---

### Task 10: Acquire Protocol-v2 Directory Locks and the Exact SQLite Lease

**Files:**
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/cross_app_lease/config.ex`
- Modify: `apps/swarm_code_daemon/lib/swarm_code/daemon/cross_app_lease.ex`
- Modify: `apps/swarm_code_daemon/lib/swarm_code/daemon/cross_app_lease/owner_record.ex`
- Modify: `apps/swarm_code_daemon/lib/swarm_code/daemon/files/atomic_replace.ex`
- Modify: `vendor/exqlite/c_src/swarm_guard.c`
- Modify: `vendor/exqlite/c_src/swarm_guard_vfs.c`
- Modify: `vendor/exqlite/lib/exqlite/swarm_guard.ex`
- Modify: `apps/swarm_code_daemon/test/swarm_code/daemon/cross_app_lease_test.exs`

**Interfaces:**

```elixir
CrossAppLease.Config.from_attempt(attempt_id, ProcessIdentity.t(), fingerprint(), schema_contract()) ::
  {:ok, CrossAppLease.Config.t()} | {:error, StartupError.t()}
CrossAppLease.start_link(CrossAppLease.Config.t()) :: GenServer.on_start()
CrossAppLease.assert_held(pid()) :: :ok | {:error, StartupError.t()}
CrossAppLease.binding_authority(pid()) :: {:ok, opaque_authority()} | {:error, atom()}
```

Production `start_link/1` accepts only the opaque config. Owner record protocol is exactly 2 and accepts only values minted from config plus live native state.

- [ ] **Step 1: Replace lease tests with protocol-v2 RED cases**

Keep all current rollback journal, owner nonce, crash linkage, wrong type/UID/mode/special-bit, and cleanup-order cases. Add distinct-directory requirement, runtime-lock then data-lock observer order, nonblocking failure, connection main identity equality, `sqlite3_get_autocommit() == 0`, unexpected sidecar refusal, owner-record receipt identity, and mode drift assertion.

Port the useful behavioral assertion from detached commit `12b5521`; do not cherry-pick its pathname implementation.

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test apps/swarm_code_daemon/test/swarm_code/daemon/cross_app_lease_test.exs
```

Expected: FAIL because the current keyword lease neither locks directories nor exact-opens SQLite.

- [ ] **Step 3: Add native locks and guarded lease open**

Inside the supervised lease child:

1. assert retained runtime/data directory identity and `0700`;
2. acquire nonblocking runtime `flock`, then data `flock`;
3. open or exclusively create `instance_lease.db` relative to data at `0600`;
4. make guarded VFS main open duplicate the already-open lease descriptor;
5. route rollback journal relative to data and validate it;
6. set/verify DELETE journal, zero busy timeout, foreign keys, and `BEGIN EXCLUSIVE`;
7. attest connection main identity and disabled autocommit;
8. publish owner record through descriptor-relative atomic replacement.

Unwind in strict reverse order. `assert_held/1` verifies both locks, both directory dentries/modes, lease dentry/descriptor/mode, VFS identity, transaction, and owner receipt. Add stable errors `foundation_lock_held`, `lease_held`, `lease_binding_changed`, and `lease_privacy_changed`.

- [ ] **Step 4: Run GREEN**

```bash
mise exec -- mix test apps/swarm_code_daemon/test/swarm_code/daemon/cross_app_lease_test.exs
mise exec -- mix precommit
```

- [ ] **Step 5: Commit**

```bash
git add vendor/exqlite apps/swarm_code_daemon/lib/swarm_code/daemon/cross_app_lease* \
  apps/swarm_code_daemon/lib/swarm_code/daemon/files/atomic_replace.ex \
  apps/swarm_code_daemon/test/swarm_code/daemon/cross_app_lease_test.exs
git commit -m "feat: acquire the exact protocol v2 data lease"
```

---

### Task 11: Prove Protocol-v2 Exclusion in Fresh OS Processes

**Files:**
- Modify: `apps/swarm_code_daemon/test/support/lease_probe.exs`
- Modify: `apps/swarm_code_daemon/test/support/os_process.ex`
- Modify: `apps/swarm_code_daemon/test/swarm_code/daemon/cross_app_lease_os_test.exs`

**Interfaces:**
- Consumes: `CrossAppLease.Config` and protocol-v2 native resources from Task 10.
- Produces: deterministic fresh-VM commands `READY`, `HELD`, `ASSERTED`, `STOPPED`, and fault-barrier acknowledgements without exposing native resources.

- [ ] **Step 1: Add all Section 6.3 races as RED tests**

Test one winner/loser, clean release, SIGKILL release, lease-only replacement, data-directory-only replacement, runtime-directory-only replacement, pre-open lease swap, lease ABA barrier, mode/special-bit drift, and nonblocking acquisition order. Each adversary-controlled replacement records before/after bytes, mode, and sidecars.

- [ ] **Step 2: Run RED once**

```bash
mise exec -- mix test apps/swarm_code_daemon/test/swarm_code/daemon/cross_app_lease_os_test.exs --seed 101
```

Expected: at least one new protocol-v2 race FAILS against the old probe protocol.

- [ ] **Step 3: Upgrade only the test process protocol and deterministic barriers**

Use task-owned temporary roots, exact OS PIDs, Port monitors, and bounded messages. Never wait by sleeping or liveness polling. Ensure a killed process cannot emit a later owner or mutate a replacement.

- [ ] **Step 4: Run five full seeds**

```bash
for seed in 101 202 303 404 505; do
  mise exec -- mix test apps/swarm_code_daemon/test/swarm_code/daemon/cross_app_lease_os_test.exs --seed "$seed" || exit 1
done
mise exec -- mix precommit
```

Expected: every seed PASS; each race has exactly one live owner and invariant replacements.

- [ ] **Step 5: Commit**

```bash
git add apps/swarm_code_daemon/test/support/lease_probe.exs \
  apps/swarm_code_daemon/test/support/os_process.ex \
  apps/swarm_code_daemon/test/swarm_code/daemon/cross_app_lease_os_test.exs
git commit -m "test: prove protocol v2 exclusion across OS processes"
```

---

### Task 12: Bind the Exact Canonical Main, WAL, and SHM Set Under Supervision

**Files:**
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/database_binding.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/database_binding_owner.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/database_binding/sidecar_set.ex`
- Modify: `vendor/exqlite/c_src/swarm_guard.c`
- Modify: `vendor/exqlite/lib/exqlite/swarm_guard.ex`
- Test: `apps/swarm_code_daemon/test/swarm_code/daemon/database_binding_owner_test.exs`

**Interfaces:**

```elixir
DatabaseBindingOwner.start_link(attempt_id, lease_pid) :: GenServer.on_start()
DatabaseBindingOwner.admit(owner) ::
  {:ok, DatabaseBinding.t()} | {:ok, :new_database} | {:error, StartupError.t()}
DatabaseBindingOwner.verify(owner) :: :ok | {:error, StartupError.t()}
DatabaseBindingOwner.close(owner) :: :ok
```

`DatabaseBinding.t()` is an attempt/generation opaque reference, not a struct containing a path. The owner retains writable-admission and separate same-inode read-only probe descriptors for main/WAL plus SHM identity/hash metadata without opening SHM for probe use.

- [ ] **Step 1: Write source-admission RED tests**

Cover main only, WAL+SHM, WAL without SHM, all absent, unexpected sidecars without main, symlink/nonregular/wrong UID/wrong mode/special bits, main/WAL descriptor pair equality, and appearance/disappearance/inode/mode/size/content drift. Assert fixed-memory hashing and native resource counts after every refusal.

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test apps/swarm_code_daemon/test/swarm_code/daemon/database_binding_owner_test.exs
```

Expected: FAIL because no live database binding owner exists.

- [ ] **Step 3: Add retained admission resources and verification**

Use the live lease's data directory capability. Open main `O_RDWR` for later Repo admission and separately `O_RDONLY` for probe, proving identical inode. Treat opening writable as admission only. Open WAL similarly when present. For SHM, capture no-follow identity, mode, size, and descriptor hash without passing that descriptor to probe. Hash all source members incrementally; retain no complete file binary.

- [ ] **Step 4: Run GREEN**

```bash
mise exec -- mix test apps/swarm_code_daemon/test/swarm_code/daemon/database_binding_owner_test.exs
mise exec -- mix precommit
```

- [ ] **Step 5: Commit**

```bash
git add vendor/exqlite apps/swarm_code_daemon/lib/swarm_code/daemon/database_binding* \
  apps/swarm_code_daemon/test/swarm_code/daemon/database_binding_owner_test.exs
git commit -m "feat: retain exact canonical database bindings"
```

---

### Task 13: Probe Through a Ledger-Backed Private SHM Workspace

**Files:**
- Modify: `vendor/exqlite/c_src/swarm_guard_vfs.c`
- Modify: `vendor/exqlite/c_src/swarm_guard.c`
- Modify: `vendor/exqlite/lib/exqlite/swarm_guard.ex`
- Modify: `apps/swarm_code_daemon/lib/swarm_code/daemon/schema/probe.ex`
- Modify: `apps/swarm_code_daemon/lib/swarm_code/daemon/schema/gate.ex`
- Modify: `apps/swarm_code_daemon/lib/swarm_code/daemon/schema/binding.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/schema/probe_worker.ex`
- Modify: `apps/swarm_code_daemon/test/swarm_code/daemon/schema/gate_test.exs`
- Test: `apps/swarm_code_daemon/test/swarm_code/daemon/schema/probe_workspace_test.exs`

**Interfaces:**

```elixir
Schema.Probe.inspect(DatabaseBinding.t(), attempt_id) ::
  {:ok, Schema.Probe.t()} | {:error, StartupError.t()}
Schema.Gate.check(DatabaseBinding.t() | :new_database, MigrationManifest.t(), String.t(), attempt_id) ::
  {:ok, Schema.Gate.Decision.t()} | {:error, StartupError.t()}
```

`Schema.Gate.Decision` contains a binding reference only for compatible ready status; it no longer treats `Schema.Binding` path/identity metadata as authority.

- [ ] **Step 1: Write probe-workspace RED tests**

For current, WAL+SHM, and WAL-without-SHM fixtures, record main/WAL/SHM bytes, identities, modes, sizes, hashes, and timestamps before every success/failure test. Assert they are unchanged afterward. Inspect the workspace through test-only facts and prove it has no main/WAL alias and its SHM is a new private `0600` owned dentry.

Reject URI escapes, `ATTACH`, `DETACH`, disk temp databases, external durable paths, late sidecars, source drift, worker death, and ambiguous workspace cleanup. WAL-without-SHM must succeed without creating canonical SHM.

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test \
  apps/swarm_code_daemon/test/swarm_code/daemon/schema/probe_workspace_test.exs \
  apps/swarm_code_daemon/test/swarm_code/daemon/schema/gate_test.exs
```

Expected: FAIL because current `BoundFile` hard-links canonical sidecars and returns metadata after closing.

- [ ] **Step 3: Route the probe through the anchor/ledger/VFS**

Reserve a ledger operation, start a probe `AnchorOwner` below the retained state directory, and create the workspace/marker/private SHM through the intent/acquired handshake. Map virtual main/WAL directly to duplicate pinned read-only descriptors. Never pass canonical SHM to the VFS. Set query-only, foreign keys, memory temp store, and an authorizer rejecting ATTACH/DETACH.

On timeout, use SQLite progress/interrupt and supervised worker cleanup. Return `cleanup_pending`, not schema-ready, until workspace cleanup is terminal. Reverify the complete canonical set through fresh descriptor-relative identity/mode/size/hash comparisons before success.

- [ ] **Step 4: Remove the alias authority**

After the new tests pass, delete `apps/swarm_code_daemon/lib/swarm_code/daemon/platform/bound_file.ex` and all `BoundFile` call sites. Keep no fallback branch.

- [ ] **Step 5: Run GREEN**

```bash
mise exec -- mix test \
  apps/swarm_code_daemon/test/swarm_code/daemon/schema/probe_workspace_test.exs \
  apps/swarm_code_daemon/test/swarm_code/daemon/schema/gate_test.exs
mise exec -- mix precommit
```

- [ ] **Step 6: Commit**

```bash
git add vendor/exqlite apps/swarm_code_daemon/lib/swarm_code/daemon/schema \
  apps/swarm_code_daemon/lib/swarm_code/daemon/platform/bound_file.ex \
  apps/swarm_code_daemon/test/swarm_code/daemon/schema
git commit -m "feat: probe schemas with private guarded shared memory"
```

---

### Task 14: Add the One-Shot Ready Capability State Machine

**Files:**
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/ready_capability.ex`
- Modify: `apps/swarm_code_daemon/lib/swarm_code/daemon/database_binding_owner.ex`
- Modify: `vendor/exqlite/c_src/swarm_guard.c`
- Modify: `vendor/exqlite/lib/exqlite/swarm_guard.ex`
- Test: `apps/swarm_code_daemon/test/swarm_code/daemon/ready_capability_test.exs`

**Interfaces:**

```elixir
DatabaseBindingOwner.ready(owner, Schema.Gate.Decision.t()) ::
  {:ok, ReadyCapability.t()} | {:error, StartupError.t()}
DatabaseBindingOwner.claim(owner, ReadyCapability.t()) ::
  {:ok, connection_generation()} | {:error, StartupError.t()}
DatabaseBindingOwner.mark_live(owner, connection_generation(), [attestation()]) :: :ok | {:error, StartupError.t()}
DatabaseBindingOwner.fail(owner, connection_generation(), atom()) :: :ok
DatabaseBindingOwner.close(owner) :: :ok
```

States are exactly `probed -> starting_repo -> live -> closing -> closed`, with `starting_repo|live -> failed -> closing`. Only the first compare-and-set claim succeeds.

- [ ] **Step 1: Write RED state-machine tests**

Test copied BEAM term, second claim, stale generation, wrong owner, owner death, dropped unconsumed capability, failed Repo start, invalid transition, concurrent claims, and no transition back to `probed`. Assert `inspect/1` and serialization reveal no token/path/resource.

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test apps/swarm_code_daemon/test/swarm_code/daemon/ready_capability_test.exs
```

Expected: FAIL because ready decisions are reusable metadata.

- [ ] **Step 3: Add native-backed atomic claim plus explicit owner lifecycle**

Put CAS validity in native resource state and authoritative transition/cleanup in `DatabaseBindingOwner`. A native destructor is only a last-resort close. Owner death invalidates every copied capability. Failed start consumes the capability permanently.

- [ ] **Step 4: Run GREEN**

```bash
mise exec -- mix test apps/swarm_code_daemon/test/swarm_code/daemon/ready_capability_test.exs
mise exec -- mix precommit
```

- [ ] **Step 5: Commit**

```bash
git add vendor/exqlite apps/swarm_code_daemon/lib/swarm_code/daemon/ready_capability.ex \
  apps/swarm_code_daemon/lib/swarm_code/daemon/database_binding_owner.ex \
  apps/swarm_code_daemon/test/swarm_code/daemon/ready_capability_test.exs
git commit -m "feat: make ready capabilities one shot"
```

---

### Task 15: Consume Ready Through a Real Fully Attested Ecto Pool

**Files:**
- Create: `apps/swarm_code_daemon/lib/swarm_code/repo.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/repo_launcher.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/repo_capability.ex`
- Modify: `vendor/exqlite/lib/exqlite/connection.ex`
- Modify: `vendor/exqlite/lib/exqlite/sqlite3.ex`
- Modify: `vendor/exqlite/c_src/sqlite3_nif.c`
- Modify: `vendor/exqlite/c_src/swarm_guard_vfs.c`
- Test: `apps/swarm_code_daemon/test/swarm_code/daemon/repo_launcher_test.exs`

**Interfaces:**

```elixir
RepoLauncher.consume(ReadyCapability.t(), keyword()) ::
  {:ok, RepoCapability.t()} | {:error, StartupError.t()}
RepoLauncher.stop(RepoCapability.t()) :: :ok | {:error, Cleanup.Pending.t()}
DatabaseBindingOwner.issue_connection(owner, generation) ::
  {:ok, opaque_connection_authorization()} | {:error, StartupError.t()}
Exqlite.Connection.connect(database_binding: opaque_connection_authorization(), swarm_purpose: :repo) ::
  DBConnection.on_start()
```

The private Repo uses a per-generation name held only by `RepoLauncher`. `RepoCapability` is not the Repo PID/name and is published only after the initial pool barrier.

- [ ] **Step 1: Write full-pool RED integration tests**

Use a real `Ecto.Repo` with pool size 3. Assert all three connections have unique one-use authorizations but the same binding generation/main inode. Add concurrent checkout during startup and prove it cannot run before the barrier.

Test post-Ready main swap, second consume, killed connection/reconnect, lazy connection, main mode drift, WAL/SHM appearance/disappearance/inode/mode drift, lease assertion failure, binding-owner death, and Repo shutdown ordering. A test-only pathname-open counter must remain zero for every guarded connection/reconnect.

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test apps/swarm_code_daemon/test/swarm_code/daemon/repo_launcher_test.exs
```

Expected: FAIL because the Repo and `:database_binding` adapter route do not exist.

- [ ] **Step 3: Add guarded Exqlite connection selection**

In `Exqlite.Connection.connect/1`, select a valid opaque `:database_binding` before ordinary `:database` validation. This branch must not call `Path.dirname`, `File.mkdir_p`, `Sqlite3.open(path, ...)`, storage commands, or structure commands. Reject simultaneous raw database and production binding inputs. Each authorization is consumed once by native open and produces an attestation with binding generation and actual main identity.

The VFS duplicates the pinned writable-admission main descriptor. Canonical journal/WAL/SHM operations are descriptor-relative, exact-basename only, exact `0600`, and binding-tracked. Use memory temp storage and deny ATTACH/DETACH.

- [ ] **Step 4: Add pool startup and reconnect barriers**

`RepoLauncher.consume/2` claims Ready, starts the private Repo below the attempt supervisor, eagerly starts every configured pool connection, waits for initialization pragmas and attestations, reasserts the lease, then marks the binding live. Replacement connections obtain a fresh authorization only after `DatabaseBindingOwner.verify/1` succeeds. Any failure freezes admission, interrupts connections, stops Repo, retains the lease through cleanup, and returns `database_binding_changed` or `repo_binding_failed`.

- [ ] **Step 5: Run GREEN**

```bash
mise exec -- mix test apps/swarm_code_daemon/test/swarm_code/daemon/repo_launcher_test.exs
mise exec -- mix precommit
```

- [ ] **Step 6: Commit**

```bash
git add vendor/exqlite apps/swarm_code_daemon/lib/swarm_code/repo.ex \
  apps/swarm_code_daemon/lib/swarm_code/daemon/repo_launcher.ex \
  apps/swarm_code_daemon/lib/swarm_code/daemon/repo_capability.ex \
  apps/swarm_code_daemon/test/swarm_code/daemon/repo_launcher_test.exs
git commit -m "feat: attest every guarded repo connection"
```

---

### Task 16: Create and Independently Verify Ledger-Owned Backup Staging

**Files:**
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/backup/request.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/backup/operation_supervisor.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/backup/worker.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/backup/snapshot.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/backup/verifier.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/backup/restore_verifier.ex`
- Modify: `apps/swarm_code_daemon/lib/swarm_code/daemon/backup/gate.ex`
- Modify: `vendor/exqlite/c_src/swarm_guard_vfs.c`
- Modify: `apps/swarm_code_daemon/test/swarm_code/daemon/backup/gate_test.exs`
- Test: `apps/swarm_code_daemon/test/swarm_code/daemon/backup/staging_test.exs`

**Interfaces:**

```elixir
Backup.Request.from_decision(attempt_id, lease, binding, decision, operation_id) ::
  {:ok, Backup.Request.t()} | {:error, StartupError.t()}
Backup.Snapshot.create(request, anchor_id) ::
  {:ok, staged_backup :: Namespace.OwnedRef.t()} | {:error, StartupError.t()}
Backup.Verifier.verify(anchor_id, staged_backup, expected_probe) ::
  {:ok, verification()} | {:error, StartupError.t()}
Backup.RestoreVerifier.verify(anchor_id, staged_backup, verification()) ::
  {:ok, restore_proof()} | {:error, StartupError.t()}
```

- [ ] **Step 1: Write staging and worker-death RED tests**

Retain current committed-WAL, source invariance, every-table counts, shadowed-rowid, quick/FK, representative proof, SHA, and independently restorable-copy tests. Add deterministic death after every private SHM/staging/restore mutation and before worker reply, plus backup-directory rename/replacement during VACUUM and restore.

Assert the worker never owns the only anchor/receipt and never uses source-pin path aliases. Main/WAL/SHM source bytes remain exact. Canonical SHM is never opened by snapshot work.

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test \
  apps/swarm_code_daemon/test/swarm_code/daemon/backup/staging_test.exs \
  apps/swarm_code_daemon/test/swarm_code/daemon/backup/gate_test.exs
```

Expected: FAIL because current backup ownership is reconstructed around DirectoryHelper replies.

- [ ] **Step 3: Route SQLite snapshot destinations through guarded opaque names**

Start ledger operation, anchor, guardian, and disposable worker under the attempt. The worker opens the exact bound main/WAL through guarded VFS. `VACUUM INTO` receives an opaque virtual destination mapped by the VFS to the already authorized anchor/basename; arbitrary SQL paths are rejected. All staging, private sidecars, and restore copies use AnchorOwner's receipt handshake.

Extract existing verification calculations without changing their manifest values. Open staged/restore files through retained descriptors. Close every connection/statement/resource on all results; pending cleanup retains the lease.

- [ ] **Step 4: Run GREEN**

```bash
mise exec -- mix test \
  apps/swarm_code_daemon/test/swarm_code/daemon/backup/staging_test.exs \
  apps/swarm_code_daemon/test/swarm_code/daemon/backup/gate_test.exs
mise exec -- mix precommit
```

- [ ] **Step 5: Commit**

```bash
git add vendor/exqlite apps/swarm_code_daemon/lib/swarm_code/daemon/backup \
  apps/swarm_code_daemon/test/swarm_code/daemon/backup
git commit -m "feat: stage verified backups under durable ownership"
```

---

### Task 17: Publish Backup Database First, Manifest Last, and Replay Safely

**Files:**
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/backup/publication.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/backup/recovery.ex`
- Modify: `apps/swarm_code_daemon/lib/swarm_code/daemon/backup/gate.ex`
- Modify: `apps/swarm_code_daemon/lib/swarm_code/daemon/backup/manifest.ex`
- Modify: `apps/swarm_code_daemon/lib/swarm_code/daemon/backup/artifact.ex`
- Modify: `apps/swarm_code_daemon/test/swarm_code/daemon/backup/gate_test.exs`
- Test: `apps/swarm_code_daemon/test/swarm_code/daemon/backup/publication_test.exs`
- Test: `apps/swarm_code_daemon/test/swarm_code/daemon/backup/recovery_test.exs`

**Interfaces:**

```elixir
Backup.Publication.commit(anchor_id, staged_backup, staged_manifest, verification) ::
  {:ok, Backup.Artifact.t()} | {:error, StartupError.t()}
Backup.Recovery.replay(attempt_id, operation_id) ::
  {:ok, Backup.Artifact.t()} | {:error, StartupError.t()}
Backup.Gate.create(Backup.Request.t()) ::
  {:ok, Backup.Artifact.t()} | {:error, StartupError.t()}
```

- [ ] **Step 1: Write the manifest-last RED fault matrix**

Fault after final backup mutation, after acquired fsync, after directory fsync, before manifest mutation, after manifest mutation, after manifest acquired fsync, before committed transition, after committed fsync, and before result reply. Repeat after held backup directory rename and replacement.

Port only the behavioral insight from detached `2d2d824`: final DB without final manifest is uncommitted. Do not port its pathname scan/deletion.

Test valid committed duplicate before and after its full ledger moves to `done/`, multiple retained committed operation ledgers discovered across cursor pages, per-ledger capacity exhaustion before mutation, corrupt backup, corrupt manifest, source digest drift, intent-only final DB, acquired final DB, preexisting substituted final names, broken ledger, and bounded relocation. Every refusal checks held and replacement directory identities/content. Moving/archive discovery must not discard membership or verification facts that distinguish a genuine duplicate from a reused operation ID.

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test \
  apps/swarm_code_daemon/test/swarm_code/daemon/backup/publication_test.exs \
  apps/swarm_code_daemon/test/swarm_code/daemon/backup/recovery_test.exs
```

Expected: FAIL because current final-link acknowledgement can be lost without durable acquired ownership.

- [ ] **Step 3: Add the exact publication state machine**

Execute: fsync staging pair; no-clobber final DB; fsync acquired record; fsync directory; no-clobber final manifest; fsync acquired record; fsync directory; append/fsync committed; reopen both by descriptor and reverify; only then return artifact.

An acquired uncommitted final DB may be exact-cleaned by its guardian using the live receipt or, after verified replay, the distinct one-use recovery authority. Intent-only candidates are preserved ambiguous. Duplicate IDs return only a fully matching committed artifact after demand-loading that operation's complete ledger from active or `done/`. A committed full ledger remains correlated with the final pair and is not compacted or deleted while either artifact exists. Remove `register_source_pin_identities`, expected-path ownership, `unknown_operation_files`, process-dictionary ownership lists, and deletion from matching inode/name.

- [ ] **Step 4: Remove obsolete broker namespace authority**

After all backup tests use `AnchorOwner`, delete unused namespace-mutating `DirectoryBroker`/`DirectoryHelper` operations and their tests. If the helper has no remaining non-namespace responsibility, remove both modules and `DirectoryProtocol`; otherwise retain only supervised compute/Port control with no path mutation API. Add an architecture test proving no production caller can use the old authority.

- [ ] **Step 5: Run GREEN**

```bash
mise exec -- mix test apps/swarm_code_daemon/test/swarm_code/daemon/backup
mise exec -- mix test apps/swarm_code_daemon/test/swarm_code/daemon/platform/directory_helper_test.exs
mise exec -- mix precommit
```

If the helper test file was deleted because the module became unused, replace the second command with:

```bash
test ! -e apps/swarm_code_daemon/lib/swarm_code/daemon/platform/directory_helper.ex
test ! -e apps/swarm_code_daemon/lib/swarm_code/daemon/platform/directory_broker.ex
```

- [ ] **Step 6: Commit**

```bash
git add -A apps/swarm_code_daemon/lib/swarm_code/daemon/backup \
  apps/swarm_code_daemon/lib/swarm_code/daemon/platform \
  apps/swarm_code_daemon/test/swarm_code/daemon/backup \
  apps/swarm_code_daemon/test/swarm_code/daemon/platform
git commit -m "feat: commit and replay backup publication safely"
```

---

### Task 18: Invert Provenance I/O Without Polluting Core Dependencies

**Files:**
- Modify: `apps/swarm_code_core/lib/swarm_code/governance/provenance.ex`
- Modify: `apps/swarm_code_core/test/swarm_code/governance/provenance_test.exs`
- Delete: `apps/swarm_code_core/lib/mix/tasks/swarm_code.provenance.verify.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/governance/provenance_reader.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/governance/provenance_verifier.ex`
- Create: `apps/swarm_code_daemon/lib/mix/tasks/swarm_code.provenance.verify.ex`
- Test: `apps/swarm_code_daemon/test/swarm_code/daemon/governance/provenance_reader_test.exs`
- Modify: `apps/swarm_code_core/test/swarm_code_core/architecture_test.exs`

**Interfaces:**

```elixir
SwarmCode.Governance.Provenance.validate(map(), map(), map()) :: :ok | {:error, [String.t()]}
SwarmCode.Daemon.Governance.ProvenanceReader.read_inputs(Path.t()) ::
  {:ok, %{policy: map(), ledger: map(), authorization_files: map(), digests: map()}}
  | {:error, String.t()}
SwarmCode.Daemon.Governance.ProvenanceVerifier.verify(Path.t()) ::
  :ok | {:error, [String.t()]}
```

- [ ] **Step 1: Write dependency and descriptor-leak RED tests**

Core tests call `validate/3` with pure values and assert `apps/swarm_code_core/mix.exs` has no Exqlite/Ecto/daemon dependency. Daemon reader tests cover FIFO, oversized JSON/destination, symlink ancestors, identity mismatch immediately after open in JSON and digest paths, exceptions/cancellation, and repeated native resource count return to baseline.

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test \
  apps/swarm_code_core/test/swarm_code/governance/provenance_test.exs \
  apps/swarm_code_daemon/test/swarm_code/daemon/governance/provenance_reader_test.exs
```

Expected: FAIL because current core verifier performs effectful pathname opens and the daemon adapter is absent.

- [ ] **Step 3: Split pure policy from native effects**

Move all open/read/hash/path confinement into the daemon reader using the vendored FS resources. Keep 1 MiB policy/ledger, 64 MiB destination, fixed-memory hash, monitored one-second worker, deterministic errors, and explicit close in every branch. Move the Mix task to daemon so it composes reader plus pure core validator without starting Repo, sockets, scheduler, or desktop code.

- [ ] **Step 4: Run GREEN**

```bash
mise exec -- mix test \
  apps/swarm_code_core/test/swarm_code/governance/provenance_test.exs \
  apps/swarm_code_daemon/test/swarm_code/daemon/governance/provenance_reader_test.exs
mise exec -- mix swarm_code.provenance.verify
mise exec -- mix precommit
```

- [ ] **Step 5: Commit**

```bash
git add -A apps/swarm_code_core/lib/swarm_code/governance \
  apps/swarm_code_core/lib/mix/tasks \
  apps/swarm_code_core/test \
  apps/swarm_code_daemon/lib/swarm_code/daemon/governance \
  apps/swarm_code_daemon/lib/mix/tasks \
  apps/swarm_code_daemon/test/swarm_code/daemon/governance
git commit -m "fix: close provenance descriptors through native inversion"
```

---

### Task 19: Close Generator, Basename, and Permission Regression Debts

**Files:**
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/schema/manifest_generator.ex`
- Modify: `apps/swarm_code_daemon/priv/schema/generate_manifest.exs`
- Modify: `apps/swarm_code_daemon/test/swarm_code/daemon/schema/generate_manifest_test.exs`
- Modify: remaining `directory_protocol_test.exs` only if the transitional broker remains
- Modify: `schema/gate_test.exs`
- Modify: `cross_app_lease_test.exs`

**Interfaces:**

```elixir
Schema.ManifestGenerator.run!([String.t()]) :: :ok
```

The generator stages outside upstream, holds each output parent descriptor, and publishes using `AnchorOwner`/FS receipt operations. The `.exs` file only loads the application and calls `run!/1`.

- [ ] **Step 1: Add RED closure regressions**

Add a deterministic barrier between output-parent admission and publication; rename/retarget the ancestor and prove output remains under the held destination or refuses. Assert upstream worktree identity, `.git`, porcelain status, and generated bytes remain unchanged.

Add direct `.`/`..` tests for every remaining source/destination/broker basename decoder before syscall. Add explicit main/WAL/SHM/lease wrong-mode, special-bit, and injectable wrong-UID tests with before/after invariance.

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test \
  apps/swarm_code_daemon/test/swarm_code/daemon/schema/generate_manifest_test.exs \
  apps/swarm_code_daemon/test/swarm_code/daemon/schema/gate_test.exs \
  apps/swarm_code_daemon/test/swarm_code/daemon/cross_app_lease_test.exs
```

Expected: FAIL at the newly injected generator write boundary or missing direct closure regression.

- [ ] **Step 3: Move generator publication behind held capabilities**

Remove process-wide cwd and pathname `mkdir`/rename publication. Stage bounded outputs in a private external directory, open destination parents component-by-component, reject any ancestor identity matching upstream, publish atomically through owned receipts, and clean only those receipts.

- [ ] **Step 4: Reproduce audited outputs from an isolated clone**

Use the exact pinned upstream commit and original generator command from `2026-09-01-foundation-safety-gate.md`. Compare every generated manifest/fixture byte with tracked outputs and assert upstream porcelain is unchanged.

- [ ] **Step 5: Run GREEN**

```bash
mise exec -- mix test \
  apps/swarm_code_daemon/test/swarm_code/daemon/schema/generate_manifest_test.exs \
  apps/swarm_code_daemon/test/swarm_code/daemon/schema/gate_test.exs \
  apps/swarm_code_daemon/test/swarm_code/daemon/cross_app_lease_test.exs
mise exec -- mix precommit
```

- [ ] **Step 6: Commit**

```bash
git add apps/swarm_code_daemon/lib/swarm_code/daemon/schema/manifest_generator.ex \
  apps/swarm_code_daemon/priv/schema/generate_manifest.exs \
  apps/swarm_code_daemon/test/swarm_code/daemon/schema \
  apps/swarm_code_daemon/test/swarm_code/daemon/cross_app_lease_test.exs
git commit -m "fix: close residual generator and permission races"
```

---

### Task 20: Recompose FoundationGate Around the Supervised Capability Handoff

**Files:**
- Modify: `apps/swarm_code_daemon/lib/swarm_code/daemon/foundation_gate.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/foundation_gate/attempt.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/foundation_gate/ready.ex`
- Modify: `apps/swarm_code_daemon/lib/swarm_code/daemon/foundation_gate/boot_config.ex`
- Modify: `apps/swarm_code_daemon/test/swarm_code/daemon/foundation_gate_test.exs`
- Modify: `docs/foundation-safety.md`

**Interfaces:**

```elixir
FoundationGate.prepare(BootConfig.t()) ::
  {:ok, FoundationGate.Ready.t()} | {:error, StartupError.t()}
FoundationGate.Ready.capability(FoundationGate.Ready.t()) :: ReadyCapability.t()
FoundationGate.cleanup_status(binary()) ::
  {:ok, :pending | :cleaned | :preserved_ambiguous | :failed_terminal} | {:error, atom()}
```

Production rejects `[]`, keyword options, caller-provided environment/home/path/mode, callbacks, and raw identity/lease/owner data. Test seams use `BootConfig.test/1` compiled only in test.

- [ ] **Step 1: Rewrite the orchestration tests RED-first**

Expected order is: start supervised attempt/capability owner; resolve and retain directory set; trusted identity; first desktop detection; dual locks/exact lease; second detection; database admission; manifest; guarded schema probe; then either one-shot Ready, verified backup plus migration-not-installed refusal, new-database-not-installed refusal, or typed failure.

Test caller death at every phase, second detector failure, cleanup timeout, pending registry observation, backup pending retaining lease, Ready owner death, and shutdown order: Repo, binding, backup/guardians, owner record, lease transaction, data lock, runtime lock, directories.

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test apps/swarm_code_daemon/test/swarm_code/daemon/foundation_gate_test.exs
```

Expected: FAIL because current caller temporarily owns paths/lease and Ready is metadata.

- [ ] **Step 3: Split the 1,446-line gate into attempt orchestration and result types**

`prepare/1` asks `FoundationBootstrapSupervisor` to start an attempt and monitors its reference. It never receives raw capabilities. The supervised attempt executes the ordered gates and returns Ready containing only the one-shot capability plus safe metadata. Cleanup timeout preserves the primary error, attaches registry-issued pending data, and leaves the lease under `LeaseKeeper` until cleanup becomes terminal.

Update `docs/foundation-safety.md` to state exact descriptor binding, one-shot Repo consumption, the remaining desktop race, malicious-same-UID boundary, mutation-to-ledger ambiguity, and lost-directory limitation without overstating support.

- [ ] **Step 4: Run GREEN**

```bash
mise exec -- mix test apps/swarm_code_daemon/test/swarm_code/daemon/foundation_gate_test.exs
mise exec -- mix precommit
```

- [ ] **Step 5: Commit**

```bash
git add apps/swarm_code_daemon/lib/swarm_code/daemon/foundation_gate* \
  apps/swarm_code_daemon/test/swarm_code/daemon/foundation_gate_test.exs \
  docs/foundation-safety.md
git commit -m "feat: compose the supervised ready to repo foundation"
```

---

### Task 21: Amend Desktop Compatibility Spec 53 for Lease Protocol v2

**Repository boundary:** This is the only task that writes `/Users/zaali/dev/swarm-code`. It changes exactly one numbered spec and no desktop implementation.

**Files:**
- Modify only: `/Users/zaali/dev/swarm-code/.specs/53_cli_shared_runtime_compatibility_spec.md`

**Interfaces:**
- Produces: a reciprocal protocol-v2 specification requiring runtime-first/data-second directory locks, exact descriptor-bound SQLite lease open, owner protocol 2, assertions, and reverse shutdown order before later desktop implementation begins.
- Preserves: explicit wording that the currently released desktop remains nonparticipating and simultaneous operation is unsupported.

- [ ] **Step 1: Verify the desktop repository is clean before editing**

```bash
test -z "$(git -C /Users/zaali/dev/swarm-code status --porcelain)"
```

Expected: PASS. If it fails, stop this task without modifying or cleaning the user's changes.

- [ ] **Step 2: Add a failing content check before changing the spec**

Run:

```bash
grep -F "runtime-directory lock" /Users/zaali/dev/swarm-code/.specs/53_cli_shared_runtime_compatibility_spec.md && \
grep -F "data-directory lock" /Users/zaali/dev/swarm-code/.specs/53_cli_shared_runtime_compatibility_spec.md && \
grep -F "protocol version 2" /Users/zaali/dev/swarm-code/.specs/53_cli_shared_runtime_compatibility_spec.md
```

Expected: FAIL because spec 53 currently defines only the adjacent SQLite lease/owner protocol.

- [ ] **Step 3: Amend only the contract text**

Specify:

1. descriptor-relative retained runtime/data directories at `0700`;
2. distinct directory identities;
3. nonblocking runtime `flock` then data `flock`;
4. exact descriptor-bound adjacent lease at `0600` and rollback `BEGIN EXCLUSIVE`;
5. owner record protocol 2 from typed runtime state;
6. held-state checks for both locks, directories, lease descriptor/dentry/mode, transaction, and owner receipt;
7. Repo-before-binding-before-lease reverse shutdown;
8. no force unlock;
9. current desktop nonparticipation and unsupported concurrency until implementation ships.

Do not edit `.ex`, `.heex`, JS, CSS, migration, configuration, or test files.

- [ ] **Step 4: Verify spec-only scope and desktop repository gate**

```bash
test "$(git -C /Users/zaali/dev/swarm-code diff --name-only | tr -d '\n')" = ".specs/53_cli_shared_runtime_compatibility_spec.md"
grep -F "runtime-directory lock" /Users/zaali/dev/swarm-code/.specs/53_cli_shared_runtime_compatibility_spec.md
grep -F "data-directory lock" /Users/zaali/dev/swarm-code/.specs/53_cli_shared_runtime_compatibility_spec.md
grep -F "protocol version 2" /Users/zaali/dev/swarm-code/.specs/53_cli_shared_runtime_compatibility_spec.md
(cd /Users/zaali/dev/swarm-code && mise exec -- mix precommit)
```

No browser smoke test is required for a spec-only change.

- [ ] **Step 5: Commit in the desktop repository**

```bash
git -C /Users/zaali/dev/swarm-code add .specs/53_cli_shared_runtime_compatibility_spec.md
git -C /Users/zaali/dev/swarm-code commit -m "docs: specify shared lease protocol v2"
```

Record the desktop spec commit hash in the task report; do not merge or implement the desktop protocol in this plan.

---

### Task 22: Enforce the Production Boundary in a Real Production Build

**Files:**
- Create: `scripts/acceptance/production_foundation.exs`
- Create: `scripts/acceptance/production_foundation.sh`
- Create: `apps/swarm_code_daemon/test/swarm_code/daemon/production_surface_test.exs`
- Modify: `config/runtime.exs`
- Modify: `apps/swarm_code_core/test/swarm_code_core/architecture_test.exs`
- Modify: `vendor/exqlite/mix.exs`

**Interfaces:**
- Produces a no-Repo-start `MIX_ENV=prod` probe that returns success only after it proves raw path/options are rejected and the fork metadata/native symbols are production-safe.

- [ ] **Step 1: Write RED static and runtime production checks**

Assert production exports only `BootConfig.current/0`, `FoundationGate.prepare/1` with opaque config, typed lease config, and `RepoLauncher.consume/2`. Reject `[]`, raw keywords, arbitrary home/env/XDG/database paths, raw owner maps, descriptors, cleanup callbacks, and fault barriers. Export `DATABASE_PATH` to a sentinel and prove canonical resolution does not use it.

Assert the closed public error mapping includes `native_guard_unavailable`, `unsafe_private_directory`, `foundation_lock_held`, `lease_held`, `lease_binding_changed`, `lease_privacy_changed`, `database_binding_changed`, `ready_already_consumed`, `repo_binding_failed`, `cleanup_pending`, `cleanup_ledger_corrupt`, `schema_incompatible`, and `backup_failed`, and that no native string, receipt, descriptor, or unbounded path is echoed.

Scan source/application dependency metadata for Phoenix/Desktop/wx/distribution, `EXQLITE_USE_SYSTEM`, `:prim_file`, pathname database fallback in guarded branches, raw reaper creation, runtime atom conversion, and test barrier exports.

- [ ] **Step 2: Run RED production compile/probe**

```bash
MIX_ENV=prod mise exec -- mix compile --warnings-as-errors
DATABASE_PATH=/tmp/must-not-open.sqlite3 MIX_ENV=prod \
  mise exec -- mix run --no-start scripts/acceptance/production_foundation.exs
```

Expected: the new probe command FAILS because its file/assertions do not yet exist; compile must remain warning-free.

- [ ] **Step 3: Close the production API and native build surface**

Keep all callbacks/barriers/test constructors behind compile-time test modules and `SWARM_GUARD_TEST`. The production Exqlite fork is source-built, carries immutable fork/SQLite metadata, rejects system SQLite, and has no precompiler URL/path. Production startup performs no raw alternate open and logs no resource details.

- [ ] **Step 4: Run GREEN**

```bash
mise exec -- mix test apps/swarm_code_daemon/test/swarm_code/daemon/production_surface_test.exs
MIX_ENV=prod mise exec -- mix compile --warnings-as-errors
DATABASE_PATH=/tmp/must-not-open.sqlite3 MIX_ENV=prod \
  mise exec -- mix run --no-start scripts/acceptance/production_foundation.exs
mise exec -- mix precommit
```

- [ ] **Step 5: Commit**

```bash
git add scripts/acceptance config/runtime.exs vendor/exqlite/mix.exs \
  apps/swarm_code_daemon/test/swarm_code/daemon/production_surface_test.exs \
  apps/swarm_code_core/test/swarm_code_core/architecture_test.exs
git commit -m "test: enforce production foundation capabilities"
```

---

### Task 23: Generate Target-Native Sanitizer and Four-Target Package Evidence

**Files:**
- Create: `.github/workflows/foundation-native.yml`
- Create: `scripts/ci/assert-target.sh`
- Create: `scripts/ci/native-sanitizers.sh`
- Create: `scripts/ci/build-foundation-release.sh`
- Create: `scripts/ci/inspect-foundation-release.sh`
- Create: `scripts/ci/smoke-foundation-release.sh`
- Create: `scripts/ci/write-foundation-evidence.exs`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/native_acceptance.ex`
- Create: `rel/vm.args.eex`
- Create: `rel/foundation_env.sh.eex`
- Modify: `mix.exs`
- Modify: `.gitignore`
- Test: `apps/swarm_code_daemon/test/swarm_code/daemon/native_acceptance_test.exs`

**Interfaces:**
- Produces internal release `:swarm_code_foundation` with `include_erts: true`.
- Produces per-target evidence JSON containing commit, target, OS version, CPU, OTP/Elixir, fork version, SQLite version/source ID, NIF digest, linked-library inspection, test commands/results, and archive SHA-256.
- Produces internal archives only for:
  - `macos-arm64` on macOS 14+ arm64;
  - `macos-x86_64` on macOS 14+ x86_64;
  - `ubuntu-22.04-arm64` on aarch64 glibc 2.35 baseline;
  - `ubuntu-22.04-x86_64` on x86_64 glibc 2.35 baseline.

- [ ] **Step 1: Write RED acceptance assertions**

`native_acceptance_test.exs` must invoke the same bounded cases used by packaged smoke: FS no-follow/resource cycle, directory flock, guarded lease, WAL-without-SHM private probe, one-shot pool size 3, killed connection reconnect, backup intent/acquired replay, and SIGKILL release. It records no success merely from compilation.

- [ ] **Step 2: Run local RED**

```bash
mise exec -- mix test apps/swarm_code_daemon/test/swarm_code/daemon/native_acceptance_test.exs
```

Expected: FAIL because packaged acceptance entry points do not exist.

- [ ] **Step 3: Add release and inspection scripts**

`assert-target.sh` fails unless `uname`, OS release, and CPU exactly match the matrix entry. `native-sanitizers.sh` builds/runs native tests with compiler warnings as errors and ASan/UBSan on supported native CI hosts. Mac builds set and inspect `MACOSX_DEPLOYMENT_TARGET=14.0`; actual macOS 14 behavior still requires the floor jobs. Release build rejects system SQLite and network native fetch.

Inspection uses `file` plus `otool -L`/Mach-O deployment inspection or `readelf -d`/`objdump -T`. Linux rejects any `GLIBC_*` symbol above 2.35. Scan ERTS, Exqlite NIF, and every helper for architecture, linked libraries, RPATH/RUNPATH, and forbidden test/fault symbols.

Packaged smoke unpacks into a clean temporary root, removes Erlang/Elixir/compiler/system SQLite from `PATH`, disables network, and invokes `SwarmCode.Daemon.NativeAcceptance.run!/0`. It must observe actual native tests, not reuse build-host result files.

- [ ] **Step 4: Add exact hosted build jobs and minimum-runtime floor jobs**

Use these exact GitHub-hosted labels for target-native builds:

```text
macos-15            -> macos-arm64
macos-15-intel      -> macos-x86_64
ubuntu-24.04-arm    -> ubuntu-22.04-arm64 build inside ubuntu@sha256:2edbbc5dc405e9612ba3584ce95480277e3eb374407b5505fe26f17df77c7dbc
ubuntu-24.04        -> ubuntu-22.04-x86_64 build inside ubuntu@sha256:2edbbc5dc405e9612ba3584ce95480277e3eb374407b5505fe26f17df77c7dbc
```

The pinned multi-architecture container is official Ubuntu 22.04 and establishes the glibc 2.35 build/ABI floor; the workflow verifies `/etc/os-release`, architecture, image digest, and emitted symbol versions before compilation. A 24.04 host kernel does not prove Ubuntu 22.04/Linux 5.15 runtime behavior.

Require four additional minimum-runtime jobs before compatibility is claimed:

```text
[self-hosted, foundation-floor, macos-14, ARM64]
[self-hosted, foundation-floor, macos-14, X64]
[self-hosted, foundation-floor, ubuntu-22.04, linux-5.15, ARM64]
[self-hosted, foundation-floor, ubuntu-22.04, linux-5.15, X64]
```

The floor jobs download the matching hosted-built archive by verified digest and run inspection plus the full offline packaged acceptance suite; they do not rebuild it on a newer host. Every hosted build and floor-runtime job performs the applicable portion of:

```text
assert-target
mix precommit
MIX_ENV=prod compile --warnings-as-errors
native sanitizer/unit tests
five OS lease seeds
build include_erts release
native binary/symbol inspection
offline clean-host packaged smoke
write evidence JSON
upload archive and evidence as internal artifacts
```

Cross-compilation does not satisfy a build job, and a hosted newer-OS run does not satisfy a minimum-runtime job. A missing floor runner, skipped native case, unsigned Mac artifact, or failed inspection leaves the milestone incomplete and uploads no releasable asset. These archives are labeled internal/nonrelease; this task does not publish the one-command installer.

- [ ] **Step 5: Run the local-host subset without claiming other targets**

```bash
mise exec -- mix test apps/swarm_code_daemon/test/swarm_code/daemon/native_acceptance_test.exs
scripts/ci/assert-target.sh "$(uname -s)" "$(uname -m)"
scripts/ci/native-sanitizers.sh
scripts/ci/build-foundation-release.sh local
scripts/ci/inspect-foundation-release.sh local
scripts/ci/smoke-foundation-release.sh local
mise exec -- mix precommit
```

Expected: PASS only for the current host. The task report must say the other three targets remain unevidenced until their CI jobs finish.

- [ ] **Step 6: Commit CI and package definitions**

```bash
git add .github/workflows/foundation-native.yml scripts/ci rel mix.exs .gitignore \
  apps/swarm_code_daemon/lib/swarm_code/daemon/native_acceptance.ex \
  apps/swarm_code_daemon/test/swarm_code/daemon/native_acceptance_test.exs
git commit -m "ci: gate foundation on four native releases"
```

- [ ] **Step 7: Require remote build and floor-runtime evidence before promotion**

Trigger the committed workflow and require all four hosted build jobs plus all four minimum-runtime floor jobs. Download each evidence JSON and verify its target/commit/archive digest and matching floor-runtime result. Do not edit the branch to fabricate status files and do not claim macOS 14 or Ubuntu 22.04/Linux 5.15 compatibility from the local or hosted-newer-OS subset.

---

## Completion Evidence Required Before Promotion

After Task 23, all four hosted target-native build jobs, and all four minimum-runtime floor jobs are green:

```bash
mise exec -- mix precommit
mise exec -- mix precommit
MIX_ENV=prod mise exec -- mix compile --warnings-as-errors
DATABASE_PATH=/tmp/must-not-open.sqlite3 MIX_ENV=prod \
  mise exec -- mix run --no-start scripts/acceptance/production_foundation.exs
for seed in 101 202 303 404 505; do
  mise exec -- mix test apps/swarm_code_daemon/test/swarm_code/daemon/cross_app_lease_os_test.exs --seed "$seed" || exit 1
done
git diff --check 180a591d515b383b8500298d34668a26b2944a83..HEAD
git status --short
git -C /Users/zaali/dev/swarm-code status --short
```

Also require:

- pristine Exqlite/SQLite hashes and recorded fork patch manifest;
- generator byte equality against pinned desktop commit;
- provenance verification;
- no tracked database, WAL, SHM, cleanup ledger, backup, native build residue, key, or credential;
- no unexplained task-owned temporary root or exact child process;
- hosted-build and minimum-runtime evidence JSON plus internal archive digest for all four targets;
- desktop spec 53 protocol-v2 commit hash with no desktop implementation change;
- a fresh independent whole-branch review finding no unresolved Critical or Important issue in exact lease binding, lock lifetime, probe invariance, one-shot Repo handoff/reconnect, backup ownership/replay, supervision, descriptor closure, or production/native packaging boundaries.

Passing broad tests alone does not promote the branch. If whole-VM mutation precedes durable acquired recording, or a renamed directory cannot be relocated beneath the bounded identical parent, the accepted result is preserved ambiguity plus observable `cleanup_pending`, not deletion or claimed cleanup success.

## Self-Review Against the Authoritative Spec

- **C1 / Sections 3 and 6:** Tasks 2, 10, and 11 prove SQLite uses the admitted lease descriptor plus runtime/data locks and real OS-process races.
- **C2 / Sections 7 and 8:** Tasks 12–15 retain source descriptors, probe privately, CAS Ready once, and attest every real Ecto pool connection/reconnect.
- **I1/I2 / Sections 9–11:** Tasks 6–9 establish supervision and the ledger/anchor/guardian handshake before Task 13 creates a probe workspace; Tasks 16–17 rebuild backup ownership and manifest-last replay.
- **I4/I5:** Tasks 3–5 and 19 cover no-follow component mutation, exact UID/modes/special bits, and canonical source invariance.
- **I6:** Task 18 preserves core purity while moving effectful reads to the single native library and proves descriptor counts return to baseline.
- **I8:** Tasks 6 and 9 provide bounded caller settlement, stable cleanup IDs, observable terminal states, and structural shutdown.
- **M2/production:** Tasks 5, 10, 20, and 22 close BootConfig, lease, owner, and production native surfaces.
- **Desktop reciprocity:** Task 21 changes only numbered spec 53 and retains the current desktop race warning.
- **Native/four-target gate:** Tasks 2 and 23 separate local feasibility from required target-native CI evidence and never treat cross-compilation/local success as four-target proof.
- **Scope:** No task extracts the engine, runs migrations, adds IPC/TUI/installer functionality, or changes desktop implementation.

## Execution Handoff

Execute with `superpowers:subagent-driven-development`: one fresh implementer per task, then independent spec-compliance and code-quality review before continuing. Task 2 is the mandatory stop/go review checkpoint; Tasks 10, 13, 15, 17, 20, and the final whole-branch review are additional load-bearing checkpoints.
