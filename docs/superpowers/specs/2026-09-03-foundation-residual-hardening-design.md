# Foundation Residual Hardening — Design Specification

**Status:** Proposed closure design; the foundation branch remains blocked until every promotion gate in this document passes
**Date:** 2026-09-03
**Target repository:** `/Users/zaali/dev/swarm-code-cli`
**Baseline:** `180a591d515b383b8500298d34668a26b2944a83` (`feature/foundation-safety`)
**Parent architecture:** [`2026-09-01-swarm-code-cli-design.md`](2026-09-01-swarm-code-cli-design.md)

## 1. Purpose and scope

This design closes the unresolved foundation-safety findings discovered after Tasks 1–10. The existing tests are green, but they do not prove the two load-bearing properties needed before canonical persistence can be opened:

1. SQLite must operate on the exact lease and database objects admitted by the foundation gate, not a pathname that can be substituted before SQLite opens it.
2. A successful schema decision must be consumed exactly once by the Repo that opens that same admitted database; metadata describing a connection that has already been closed is not a handoff.

The same native capability boundary also closes the related pathname, cleanup-ownership, resource-leak, and supervision gaps. This is one coupled foundation subsystem: lease exclusion, schema admission, Repo consumption, and backup cleanup all depend on descriptor-relative identities and explicit ownership.

This specification covers:

- a narrow descriptor-relative POSIX filesystem NIF surface;
- a guarded SQLite VFS in a pinned Exqlite 0.39.0 fork;
- runtime-first/data-second directory locks plus the adjacent SQLite lease transaction;
- a private schema-probe workspace that never aliases canonical shared memory;
- a one-shot `Ready` to Repo capability and guarded pool reconnection;
- supervised, observable cleanup/reaper ownership;
- a durable backup cleanup ledger and opaque per-dentry ownership receipts;
- descriptor closure in provenance verification;
- production-only boundary rejection and closure coverage;
- native and packaged acceptance on all four supported targets.

It does not extract the domain engine, implement migrations, add IPC, render a TUI, or modify the desktop repository. The current desktop still does not acquire the shared lease. No result of this work may be presented as safe concurrent desktop/CLI operation.

## 2. Findings that block promotion

The following dispositions from the final re-review are normative inputs:

| ID | Required closure |
|---|---|
| C1 | SQLite lease acquisition is bound to the exact pre-opened lease inode. Replacing the lease pathname cannot let another cooperating CLI owner acquire a second lease. |
| C2 | `Ready` carries a live, one-use capability. The eventual Repo consumes it once and derives one-use authorizations for every pool connection; production never reopens the canonical database from a pathname. |
| I1 | Backup cleanup remains owned after an operation worker or helper dies, including death after final-DB publication but before reply and while the backup directory has been renamed. |
| I2 | Deletion authority comes only from a receipt returned by the mutation that created that exact dentry and durably recorded before the receipt leaves the namespace owner. An expected name, inode, or post-reply `lstat` is not ownership. |
| I4 | Main, WAL, SHM, lease, owner, backup, manifest, and other private files enforce trusted UID and exact `0600`, including special bits. Schema probing never writes canonical SHM. |
| I5 | Private directory creation, validation, chmod, and entry mutation are descriptor-relative at effect time. |
| I6 | Every successfully opened provenance descriptor closes even when `fstat`, identity comparison, size admission, read, or hashing fails. |
| I8 | Reapers and cleanup owners are supervised, bounded for callers, observable after `cleanup_pending`, and structurally terminated during supervisor shutdown. |
| M2 | Production lease and owner-record APIs consume closed typed capabilities, not plausible caller-supplied keyword paths and runtime identity text. |

The current bounded JSON protocol, manifest contract, schema compatibility rules, backup verification, generator staging, production `BootConfig` boundary, dot-name rejection, and exact mode/UID validators are retained unless this document explicitly strengthens them.

## 3. Chosen approach

### 3.1 Why a guarded Exqlite fork is required

Hard-link aliases plus post-open pathname checks cannot identify the descriptor SQLite actually opened. They always leave an alias substitution/restore window. A separate generic NIF also cannot safely inject an already-open file into SQLite's internal Unix VFS or share private NIF resource types with Exqlite's native library.

The implementation therefore vendors a small, auditable fork at `vendor/exqlite`, based exactly on **Exqlite 0.39.0** tag `v0.39.0` and upstream commit `266b34e46b20e1c48f497cb4fb338919c793efee`. It is versioned `0.39.0-swarm.1`, retains the `:exqlite` OTP application, package-facing module names, and existing public behavior, while adding:

- opaque directory, file, lock, identity, basename, and owned-entry resource types;
- descriptor-relative POSIX operations needed by the foundation;
- a guarded VFS compiled into the same shared object as Exqlite's bundled SQLite;
- an opaque `:database_binding` option accepted by `Exqlite.Connection` instead of a path;
- connection-attestation and test-only fault-barrier APIs.

`swarm_code_daemon` uses `{:exqlite, path: "../../vendor/exqlite", override: true}`; the repository commit pins the vendored bytes and the Hex Exqlite lock entry disappears. `vendor/exqlite/UPSTREAM.json`, `vendor/exqlite/SWARM_PATCHES.md`, the upstream MIT license, and third-party notices record every baseline/changed file and SHA-256. Third-party fork files do not enter the desktop-extraction provenance ledger. The fork must remain compatible with `ecto_sqlite3 == 0.24.1`; normal runtime does not fork Ecto. Ecto storage/structure commands that require a filesystem path are not a production database-opening route.

The pristine baseline is the Hex package whose package checksum is `603de0f7637adc88275fa12ccbd58954ff6000f75386e876565b49032d9aede9`. Its bundled SQLite is 3.53.3 with source ID `2026-06-26 20:14:12 d4c0e51e4aeb96955b99185ab9cde75c339e2c29c3f3f12428d364a10d782c62`; pristine `c_src/sqlite3.c` is SHA-256 `87497ab605bedd0dbee27a209c1eeff8c89b229b13f921a7efdbb81a13f779fd`, `c_src/sqlite3.h` is `4ff81af4849acabc76fc8349abb926814395072617ca18e08800abf734ab7612`, and `c_src/sqlite3_nif.c` is `c9e5565269829fa5ed4afccf1cb5d4cd3aa4b7ac3ed584503486cf8a64add819`. Fork provenance tests compare against these exact values before applying the recorded patch set.

The 9.5 MB SQLite amalgamation remains byte-identical. A small `sqlite3_swarm.c` translation unit includes the pristine `sqlite3.c` and then the version-coupled guarded VFS implementation, allowing the guard to use the same SQLite image and audited Unix internals without editing the amalgamation or changing its source ID. Any Exqlite/SQLite upgrade fails the checksum gate and requires a new native review.

The fork disables Exqlite's precompiled-NIF path and compiles target-natively; `make_precompiler: nil` is enforced and `cc_precompiler` is removed when unused. `EXQLITE_USE_SYSTEM` is forbidden in development, CI, and release builds. The build must fail when it is set. No runtime may download a NIF, SQLite library, migration, or helper.

### 3.2 Why directory locks are added to the SQLite lease

An exclusive SQLite transaction prevents a second owner of the same lease inode, but cannot prevent two transactions on two lease inodes after the lease name is replaced. Two nonblocking advisory directory locks add stable coordination anchors around that inode:

1. acquire an exclusive BSD `flock` on the pinned runtime directory;
2. acquire an exclusive BSD `flock` on the pinned canonical data directory;
3. open the adjacent lease through the data-directory capability;
4. acquire `BEGIN EXCLUSIVE` on that exact lease descriptor through the guarded VFS.

All cooperating CLI versions use this order. A lease-file replacement still shares the data-directory lock; a data-directory replacement still shares the runtime-directory lock. The locks are additional exclusion, not a replacement for the SQLite transaction or identity checks. The two directory capabilities must refer to distinct inodes; an unsafe path layout that aliases them is refused.

Advisory locks cannot stop a malicious process running as the same UID from ignoring the protocol or replacing both anchors. Section 15 states this boundary explicitly.

The desktop compatibility document `/Users/zaali/dev/swarm-code/.specs/53_cli_shared_runtime_compatibility_spec.md` currently specifies only the adjacent SQLite transaction/owner-record protocol. Before this v2 foundation can be described as reciprocal or the desktop implementation begins, a spec-only amendment must define the same runtime-first/data-second directory-lock order, guarded exact-inode lease open, typed owner metadata, assertions, and shutdown order. This CLI work does not edit desktop implementation files, and the unmodified desktop remains nonparticipating until that later implementation ships.

## 4. Native filesystem capability boundary

### 4.1 Resource model

`SwarmCode.Daemon.Platform.FS` is the only product-facing wrapper for the fork's filesystem NIF functions. The wrapper exposes opaque values with these semantic types:

- `FS.Directory` — a retained `O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW` descriptor and its admitted identity;
- `FS.File` — a retained `O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK` descriptor and its admitted identity;
- `FS.DirectoryLock` — an exclusive, nonblocking `flock` tied to a retained directory resource;
- `FS.Identity` — kind, device, inode, UID, exact permission/special bits, and file size where applicable;
- `FS.Basename` — a validated single component, never a path;
- `FS.OwnedEntry` — an opaque receipt minted by the exact successful namespace-creation operation;
- `FS.DirectorySet` — the retained private-directory chain needed through foundation lifetime.

No raw file-descriptor integer, C pointer, absolute mutable pathname, or receipt secret crosses into application state, logs, IPC, persistence, or `inspect/1` output. Runtime input cannot manufacture a resource. A basename is valid UTF-8 of 1–255 bytes and rejects NUL, slash, empty text, `.`, and `..`.

Identity equality for a regular file means type, device, inode, and UID. Admission additionally checks exact mode and expected size/content where the caller's contract requires them. Directory identity means type, device, inode, and UID plus the exact required mode. Identity checks never follow a symlink.

### 4.2 Required operations

The NIF surface must support, at minimum, these operations behind the Elixir wrapper:

- open an admitted root and descend or create one component at a time with `openat`, `mkdirat`, and `fstatat(AT_SYMLINK_NOFOLLOW)`;
- open an existing regular file relative to a `Directory`, no-follow and nonblocking, then `fstat` the opened descriptor;
- exclusively create a regular file at mode `0600` or directory at mode `0700` relative to a `Directory`;
- create a hard link, unlink, and rename relative to held source/destination directories using `linkat`, `unlinkat`, and `renameat`;
- atomically publish without overwriting an existing destination;
- acquire/release/assert a nonblocking exclusive BSD `flock`;
- fsync an exact file and exact directory;
- bounded read of a known-size metadata file and incremental SHA-256 of a regular descriptor;
- compare a held resource with a current descriptor-relative dentry without reopening by absolute path;
- close explicitly and report the terminal state of a resource.

Linux uses `openat2` with beneath/no-symlink resolution as defense in depth when the host kernel and container policy admit it. `ENOSYS`, `EPERM`, or a seccomp denial falls back to the same portable component-by-component `openat`/`fstatat(AT_SYMLINK_NOFOLLOW)` descriptor walk used on macOS. The fallback retains and validates every parent before the next component; it is not a single pathname reopen or a reduction in the no-follow/effect-time contract.

Every opened descriptor uses `O_CLOEXEC`. Entry opens use `O_NOFOLLOW` and `O_NONBLOCK` before validating `S_ISREG`, so a raced FIFO or device cannot block the scheduler. Operations that can scale with file size run as dirty I/O NIF work, use fixed-size buffers, accept cancellation, and never retain the whole file. Short namespace syscalls remain bounded and may not call back into BEAM code while holding native locks.

An ownership-changing operation consumes its current `FS.OwnedEntry`. Rename or no-clobber publication invalidates the source receipt and mints a destination receipt; unlink accepts only a still-live receipt and invalidates it on success. A copied receipt cannot authorize a second mutation because validity is enforced in the native resource state, not only in an Elixir struct.

Native errno conversion uses a closed atom table. An unknown errno is returned as a bounded integer code, never converted into a runtime atom. Malformed terms, stale resources, double close, and cross-operation receipt use return typed errors rather than invoking undefined behavior.

### 4.3 Descriptor-relative private directory chains

`PrivateDirectory.open_chain/2` replaces validation followed by pathname `mkdir`/`chmod`. It opens the already-approved physical root once, then for each component:

1. use `fstatat(..., AT_SYMLINK_NOFOLLOW)` relative to the retained parent;
2. if absent, `mkdirat(..., 0700)` and open the created directory immediately;
3. if present, require a directory with the configured trusted owner;
4. require exact `0700` after opening; an existing predictable wrong-mode directory fails closed rather than being silently repaired;
5. retain the child descriptor before moving to the next component.

Newly created product directories are requested as `0700` under umask `077` and revalidated. If creation yields another mode, the owned empty entry is cleaned through its receipt and startup refuses. Any explicit recovery-time mode repair must operate on an already-open descriptor under its own reviewed command; normal startup never pathname-chmods a predictable occupant.

The returned `DirectorySet` remains alive through lease, schema, backup, Repo startup, and shutdown. Production mutation code receives capabilities and basenames, not recomposed absolute paths. Existing physical-root policy, including its narrowly audited macOS system-path handling, remains in force; this change does not broaden accepted symlinks.

A rename/symlink race between every admission and mutation phase must be injectable in tests. The mutation either stays under the held parent or refuses. It never creates, chmods, opens, or removes an entry under the replacement target.

## 5. Typed boot and lease configuration

`FoundationGate` constructs an opaque `CrossAppLease.Config` only from a validated production `BootConfig`, retained directory capabilities, process identity, canonical database fingerprint, and fixed build metadata. It contains semantic fields for:

- runtime and data `FS.Directory` capabilities;
- validated lease and owner-record basenames;
- trusted UID;
- protocol/schema versions;
- product, PID, process-start identity, random nonce, and start time;
- exact canonical database identity/fingerprint;
- supervised owner references.

`CrossAppLease.start_link/1` accepts only this opaque config in production. `OwnerRecord` accepts only values minted from the config and the live lease state. Raw keyword forms, absolute lease/owner paths, caller-supplied product/socket/fingerprint text, cleanup callbacks, startup replies, and fault hooks are test-only private adapters and are absent or rejected in a production build.

`BootConfig.current/0` is the single production resolver and reads the actual process environment once. On Ubuntu, validated `XDG_DATA_HOME`, `XDG_CONFIG_HOME`, `XDG_STATE_HOME`, `XDG_CACHE_HOME`, and `XDG_RUNTIME_DIR` values define the documented canonical XDG paths; on macOS the approved platform paths remain canonical. After resolution, `FoundationGate.prepare/1` accepts only that opaque `BootConfig`. It does not accept `[]`, raw keywords, a caller-injected environment map, alternate home/path fields, arbitrary modes, or test callbacks in production. `DATABASE_PATH` is never canonical and is ignored/rejected as previously specified. Tests use an explicitly test-only constructor.

## 6. Exact cross-application lease

### 6.1 Acquisition

The lease owner is supervised by the pre-Repo foundation tree, not linked directly to the calling process. Acquisition is fail-fast and ordered:

1. assert the runtime and data directory descriptors still have trusted identity and exact `0700`;
2. acquire the runtime-directory lock nonblockingly;
3. acquire the data-directory lock nonblockingly;
4. descriptor-relatively open or exclusively create the adjacent lease file at exact `0600`;
5. reject symlink, nonregular file, wrong UID, group/world access, any special bit, or unexpected lease sidecar;
6. create a guarded SQLite-open token using the already-open lease file and data directory;
7. make the guarded VFS use a `dup` of that pinned lease descriptor as `SQLITE_OPEN_MAIN_DB`; it must not resolve the lease name for the main open;
8. route lease journal access descriptor-relatively, enforce exact `0600`, set and verify `journal_mode=DELETE`, set zero busy timeout, and execute `BEGIN EXCLUSIVE`;
9. verify the SQLite connection's actual main-file identity equals the pinned lease identity and `sqlite3_get_autocommit()` is false;
10. publish the diagnostic owner record by descriptor-relative same-directory atomic replacement only after every exclusion primitive is live.

Failure unwinds in reverse order and waits for the supervised terminal result. It never changes a replacement inode, reports success with a pending lock acquisition, or leaves a caller linked to a process it may kill.

### 6.2 Held-state assertion and shutdown

`CrossAppLease.assert_held/1` verifies all of the following each time:

- both native directory-lock resources remain held;
- runtime/data descriptor identities and exact `0700` still match their canonical dentries;
- the open lease descriptor and current lease dentry are the same regular object, trusted UID, exact `0600`, with no special bits;
- the guarded SQLite main descriptor is that same lease object;
- the connection remains in the exclusive transaction;
- the owner record, when present, has this lease's nonce and is still the exact owned dentry.

A mode change on the same lease inode is a lease failure, not an identity match. Any failed assertion freezes new admission and initiates structured foundation shutdown. There is no force-unlock, stale-record takeover, or fallback pathname open.

Shutdown order is Repo connections, database binding, backup operations/guardians, diagnostic owner record, SQLite lease transaction/connection, data-directory lock, then runtime-directory lock. An abrupt OS-process death relies on kernel descriptor/lock release; stale owner text never establishes ownership.

### 6.3 Required lease races

Fresh OS-process tests, not two processes inside one BEAM, must prove:

- one immediate winner and one immediate loser under simultaneous acquisition;
- clean owner shutdown admits the next contender;
- `SIGKILL` releases the kernel locks and transaction;
- replacing only the lease file cannot admit a contender because the data-directory lock remains held;
- replacing only the data directory cannot admit a contender because the runtime-directory lock remains held;
- replacing only the runtime directory cannot admit a contender because the data-directory lock remains held;
- a pre-open lease swap cannot make SQLite mutate or lock the replacement;
- a lease mode/special-bit change makes `assert_held/1` fail;
- no test-only guarded-open ABA barrier can cause two successful live owners;
- acquisition order never deadlocks and never blocks past the bounded nonblocking result.

Each replacement test must also assert byte, mode, and sidecar invariance of the untrusted replacement.

## 7. Safe schema probe

### 7.1 Source admission

The schema gate captures the exact canonical set before probing:

- a pinned `O_RDWR` main descriptor admitted for a later writable Repo, plus a separately opened `O_RDONLY` probe descriptor verified as the same inode;
- when WAL is present, a pinned writable-admission WAL descriptor plus a separate same-inode read-only probe descriptor;
- optional WAL and SHM identities, presence, trusted UID, exact `0600`, sizes, and incremental SHA-256 values; canonical SHM is identity/hash-admitted but is not opened for probe use;
- the canonical data-directory capability and current directory identity;
- the live lease and both directory locks.

Opening an `O_RDWR` descriptor is admission only: no SQLite connection or write uses it until the one-shot Repo consume. A read-only probe never receives that descriptor. Every descriptor pair is opened no-follow, checked against the same admitted identity, and retained by `DatabaseBindingOwner` rather than the caller.

WAL and SHM presence is part of the admitted state. A sidecar appearing, disappearing, changing inode, changing mode, changing size, or changing content outside an operation owned by the guard is a binding failure. Main, WAL, and SHM are hashed through descriptors with fixed memory. No full database binary is retained.

### 7.2 Private probe workspace

The probe creates a random mode-`0700`, descriptor-owned workspace beneath the retained private state directory. Every workspace dentry is created through the ownership-receipt protocol in Section 10, which is live before probe admission.

The workspace is populated as follows:

- create no main or WAL pathname alias: the probe VFS maps its virtual main and WAL names directly to `dup` of the exact pinned `O_RDONLY` descriptors;
- **never hard-link, copy, open, mmap, or otherwise expose canonical SHM to probe writes**;
- create a new mode-`0600` SHM dentry in the workspace through the guarded VFS, so SQLite rebuilds its WAL index privately;
- open the virtual database read-only/query-only through the guarded VFS; main/WAL come from pinned descriptors and SHM access is relative to the workspace descriptor;
- reject every unrecognized VFS filename, URI escape, `ATTACH`, temp database on disk, or external durable path.

The probe runs the existing application ID, migration list, normalized schema, SQLite version/source ID, `quick_check`, and foreign-key checks. It then closes the probe connection and cleans the workspace through owned receipts.

Before a successful return, the gate rechecks the canonical directory/dentry identities, exact modes, complete sidecar presence set, sizes, and hashes through fresh descriptor-relative comparisons. Main/WAL/SHM bytes must be byte-for-byte unchanged by a successful or failed probe. A WAL-without-SHM database is a required success fixture: the private probe rebuilds SHM without creating canonical SHM. Any private-workspace cleanup ambiguity returns `cleanup_pending`, not `ready`.

### 7.3 Probe result

`Schema.Gate` may return a normal migration/new-database refusal without a Repo capability. It returns a `ReadyCapability` only for a schema that is already compatible and whose live binding is still held. The capability contains no usable database pathname and cannot be serialized.

The current `BoundFile` hard-link-alias SQLite open and metadata-only `Schema.Binding` cease to be authority. They are removed after focused replacement tests pass; keeping them as an undocumented fallback is forbidden.

## 8. One-shot `Ready` to Repo handoff

### 8.1 Capability state machine

A supervised `DatabaseBindingOwner` retains the directory locks, lease, data-directory descriptor, pinned main descriptor, admitted sidecar set, and guarded VFS state. It exposes an opaque `ReadyCapability` backed by an atomic state machine:

```text
probed -> starting_repo -> live -> closing -> closed
              |             |
              +-> failed <--+
```

Only `probed -> starting_repo` may succeed, and it is compare-and-set exactly once. A second consumer, a copied BEAM term, a stale generation, owner death, or a capability presented to another binding returns a typed terminal error. A failed Repo start does not return the capability to `probed`; callers must repeat the complete foundation gate and schema probe.

Dropping the last BEAM reference is not a normal lifecycle. The supervisor explicitly closes unconsumed/failed capabilities. Native destructors are a last-resort leak barrier, never the primary cleanup mechanism.

### 8.2 Repo launcher and pool barrier

`RepoLauncher.consume/2` is the only production path from schema-ready to an Ecto Repo. It:

1. claims the `ReadyCapability`;
2. starts `SwarmCode.Repo` with a private per-generation name under the foundation/runtime supervision boundary using the opaque `:database_binding` connection option and no canonical database pathname;
3. makes the forked `Exqlite.Connection` select `:database_binding` before normal database validation and bypass `Path.dirname`, `File.mkdir_p`, and `Sqlite3.open(path, ...)`;
4. eagerly starts the complete configured Ecto pool and waits until every connection has completed native open, connection initialization pragmas, and attestation;
5. verifies every attestation belongs to this binding generation and exact main inode;
6. advances to `live` only after the entire initial pool is guarded and the lease still asserts held.

The integration uses a real `Ecto.Repo`/`DBConnection` pool, not a fake Repo, a single direct `Exqlite.Sqlite3` connection, or metadata assertion. This milestone need not add domain schemas or migrations, but it must exercise the adapter path that later extracted core code will use.

The private Repo PID/name is held only by `RepoLauncher`; it is not registered under the public `SwarmCode.Repo` name, returned to the caller, placed in application configuration, or exposed to runtime workers during the barrier. Runtime admission and all domain workers remain stopped. Only after `live` does the supervisor publish a stable Repo capability to later children. A pre-consumption canonical swap may cause initialization against the still-pinned admitted descriptor, but no query, pragma, sidecar write, or VFS open may reach the replacement object; the failed launch closes the admitted connection and returns `database_binding_changed`.

For each SQLite connection, the guarded VFS duplicates the pinned writable-admission main descriptor. Journal, WAL, and SHM access is relative to the held data directory and accepts only the exact canonical basename plus SQLite's fixed sidecar suffixes. Existing sidecars are identity/mode/UID checked at open. Sidecars created by this binding use exact `0600` and become tracked transitions owned by the live binding.

The supported baseline uses guarded Unix WAL semantics and permits Repo to create or mutate canonical SHM only through the descriptor-relative VFS, after exact UID/mode/identity admission. The schema **probe** remains forbidden from touching canonical SHM; that immutability guarantee is not incorrectly extended to normal writable Repo operation. Guarded `unix-excl` with in-process shared memory is an optional optimization only after a separate feasibility result proves WAL recovery, multiple Ecto pool connections, initial/lazy/replacement connections, and desktop reopen compatibility on all four targets. Until that proof exists, the product makes no no-SHM claim for Repo. There is never an unguarded or pathname fallback.

The runtime uses memory temp storage and rejects `ATTACH`/`DETACH`; a connection cannot make the guarded VFS open an unrelated database. Normal storage-up/down and structure shell commands cannot consume the guarded production token.

### 8.3 Reconnection and binding loss

Pool reconnection or any lazy/replacement connection requests a new one-use connection authorization from the live `DatabaseBindingOwner`. Before issuing it, the owner reasserts both directory locks, the lease transaction, canonical main identity/mode, and all externally managed sidecar invariants. The connection remains private and unavailable for checkout until its native open, initialization pragmas, and attestation succeed.

If any assertion or attestation fails, the owner:

- refuses the reconnect without trying the stored path;
- marks the binding failed exactly once;
- freezes daemon admission;
- interrupts and closes all existing pool connections;
- stops Repo and reports `database_binding_changed` with recovery guidance;
- retains the lease until supervised cleanup has reached a terminal or observable pending state.

Tests must prove a compatible database swapped after `Ready` but before `RepoLauncher.consume/2` is refused before any query or write, consuming twice is refused, all initial connections use the exact inode, a crash/reconnect remains guarded, mode/sidecar drift fails closed, and no production trace reaches Exqlite's pathname-open branch.

## 9. Foundation safety supervision

An application-owned `FoundationBootstrapSupervisor` exists before `FoundationGate.prepare/1` is callable. The gate asks it to start one supervised foundation attempt and monitors the returned attempt reference; the caller never temporarily owns a directory, lock, SQLite, Port, or cleanup capability.

The attempt's first child is `CapabilityOwner`. That process performs physical-root admission and opens/creates the private directory chain while already supervised, retains every resulting resource, and returns only an opaque attempt-scoped reference. If the caller, capability opener, or handoff fails, the attempt supervisor closes the partial chain. `LedgerStore` and later children obtain capabilities from this owner; there is no open-in-caller then adopt-by-supervisor interval.

All remaining work runs under the attempt's pre-Repo `FoundationSafetySupervisor`. Its exact child organization may be split into focused modules, but it must provide these ownership roles:

```text
FoundationBootstrapSupervisor
└── FoundationSafetySupervisor (one supervised attempt)
    ├── CapabilityOwner
    ├── CleanupRegistry
    ├── CleanupOwnerSupervisor
    ├── LedgerStore
    ├── AnchorSupervisor
    │   └── one AnchorOwner per active backup/probe namespace
    ├── GuardianSupervisor
    │   └── one CleanupGuardian per admitted cleanup operation
    ├── OperationSupervisor
    │   └── disposable schema/backup/external-command workers
    ├── CrossAppLease owner
    ├── DatabaseBindingOwner
    └── RepoLauncher / private Repo subtree after capability consumption
```

The attempt supervisor and capability owner start before any private directory is opened. Lease/schema/backup workers start only after the owner reports a complete retained layout. The attempt is stopped only after Repo, operations, guardians, the lease, and capabilities are settled.

`DirectoryHelper`, `ExternalCommand`, foundation lease cleanup, and future broker/port work submit exact PID/Port ownership to `CleanupOwnerSupervisor`; they do not call raw `spawn`, `spawn_link`, `spawn_monitor`, or detached `Task.start` to retain cleanup. A cleanup child has a stable cleanup ID, owner monitor, absolute deadline, exact PID/Port/process-group identity, current phase, and terminal result.

A caller may receive a bounded `*_cleanup_pending` result with that cleanup ID. It can query or subscribe through `CleanupRegistry` for `pending -> cleaned | preserved_ambiguous | failed_terminal`. Returning pending does not demonitor or orphan the child. Supervisor shutdown terminates and reaps the exact external child before the cleanup owner itself exits.

Lease cleanup is performed by a supervised `LeaseKeeper`/cleanup owner that already owns or safely receives the lease. It never kills a lease still linked to the `FoundationGate.prepare/1` caller. Cleanup timeout preserves the primary `StartupError`, attaches the cleanup ID, and keeps the supervised owner observable; it must not kill the caller or bypass owner-record cleanup.

`StartupError` therefore gains an optional `cleanup` field whose value is `nil` or a bounded `%CleanupPending{id: canonical_uuid, kind: closed_kind, state: :pending}`. Constructors default it to `nil`; only `CleanupRegistry`-issued values are accepted. JSON/error presentation exposes the ID, closed kind, and corrective action but never PID, Port, receipt, path, or native resource details.

Tests use `start_supervised!/1`, monitors, messages, and registry transitions. They prove caller settlement, pending-to-terminal observation, child removal, exact process-group reaping, and supervisor shutdown while each cleanup phase is pending. They do not use `Process.sleep/1` or `Process.alive?/1`.

## 10. Durable cleanup ledger

### 10.1 Ledger format and authority

`LedgerStore` owns `<state>/cleanup-v1` through a retained descriptor. It is a mode-`0600`, append-only sequence of bounded UTF-8 JSON records. The decoder rejects any record over 65,536 bytes; every valid v1 header/checkpoint/intent/receipt/transition schema has an encoded maximum of 4,096 bytes; the active ledger is at most 1,048,576 bytes. Records contain a format version, monotonically increasing sequence, operation ID, transition, prior-record SHA-256, and record SHA-256. Body keys remain strings and decode through a closed schema without runtime atom creation.

An operation may own at most 32 ephemeral dentries and append at most 128 intent/receipt/state records. Only one namespace-mutating foundation operation (schema probe, backup, or migration preparation) is admitted at a time. Before its first mutation, `LedgerStore` requires `current_bytes + (129 * 4,096) <= 1,048,576`, reserving one checkpoint/header record plus the full operation bound. If that reservation cannot fit, admission fails before mutation. When no operation is active, the store may atomically compact verified terminal history to one new header/checkpoint and fsync file and directory. It never compacts an active, corrupt, or ambiguous operation.

Each append is complete only after the record and ledger descriptor are fsynced. A malformed record, broken hash chain, nonfinal partial record, impossible transition, oversize record, or unexplained tail blocks new mutations and produces `cleanup_ledger_corrupt`. No automatic truncation or guessed repair authorizes deletion.

### 10.2 Ownership handshake

The ledger governs only ephemeral or rollback-cleanable entries created after `LedgerStore` is live: probe workspaces, operation markers, source pins, private sidecars, staging/restore outputs, published backup artifacts before commit, and manifests. Predictable durable product/config/state/runtime directories are preserve-only capabilities established by `CapabilityOwner`; they are never retrospectively adopted into this cleanup ledger or automatically removed.

For every governed link, file, directory, staging output, published database, or manifest:

1. `LedgerStore` durably records an intent containing the exact already-held directory identity, preselected random basename, operation generation, entry class, and expected creation method before mutation;
2. `AnchorOwner` performs the descriptor-relative mutation and receives the native `FS.OwnedEntry` receipt directly;
3. `AnchorOwner` sends the actual receipt facts to `LedgerStore` while retaining the native receipt and before replying to the operation worker;
4. `LedgerStore` appends and fsyncs `acquired` for that exact dentry;
5. only then does `AnchorOwner` return an opaque `OwnedRef` to the worker.

An `OwnedRef` authorizes operations only on that recorded dentry and operation generation. It is not interchangeable by basename or inode. Expected names, source identities, directory scans, process-dictionary lists, and post-reply `lstat` results never mint or enlarge deletion authority.

If the worker dies before receiving a reply, `AnchorOwner` and `CleanupGuardian` retain the receipt. If `LedgerStore` restarts before acknowledgement, `AnchorOwner` retries the same acquired record idempotently before releasing the token. If the namespace owner or whole VM dies in the unavoidable interval between the POSIX mutation and durable acquired record, replay sees intent-only state and preserves the candidate as ambiguous. It does not infer ownership and delete it.

On replay, a durable valid `acquired` record is the creation-history proof that permits reconstruction of cleanup authority. The guardian must also relocate and verify the exact recorded directory identity and current dentry identity/mode immediately before unlinking. A mismatch is preserved and reported pending; replay never adopts a matching expected name without an acquired record. POSIX does not make the final identity-check-plus-`unlinkat` conditional, so this guarantee assumes a cooperative/unchanged namespace during that final syscall; a malicious same-UID swap in that interval is the explicit Section 15 boundary.

### 10.3 Directory anchors and rename behavior

`AnchorOwner` retains the exact backup/probe directory descriptor and all live receipts. While it is alive, cleanup and fsync remain relative to that descriptor even if the directory is renamed. The canonical pathname being absent is never treated as proof that cleanup succeeded, and a replacement directory at the old pathname is never touched.

At operation admission, the anchor creates a random 256-bit operation-marker dentry through the same intent/acquired handshake, fsyncs it, and records its identity and content hash. Before successful publication, the owner verifies that the canonical backup directory still names the held identity. If not, it aborts publication and cleans through the descriptor. After a VM restart, a guardian may reconstruct an anchor only when a bounded descriptor-relative search under a recorded, still-identical parent finds exactly one directory with the recorded identity **and** the exact acquired operation marker. If the exact directory and marker cannot be safely relocated, status remains `cleanup_pending`; no unbounded filesystem scan or pathname guess is allowed.

## 11. Backup ownership and publication

The existing backup artifact, verification, integrity, no-clobber, source-invariance, and manifest-content contracts remain. Namespace ownership and publication change as follows.

### 11.1 Operation topology

Each backup has:

- one durable ledger operation;
- one `AnchorOwner` holding the exact backup directory and receipts;
- one supervised `CleanupGuardian` monitoring ledger, anchor, and worker;
- one disposable SQLite/verification operation worker;
- one bounded final result or cleanup ID.

The operation worker never owns the only directory descriptor or deletion list. Killing it at any fault phase leaves the anchor and guardian able to continue.

Source-pin pathname aliases are removed. Backup SQLite reads main/WAL from duplicate pinned descriptors through the guarded VFS, while canonical SHM is never linked or opened by the snapshot worker. Any private rebuilt SHM, staging file, or restore copy is created one dentry at a time through the ownership handshake. Parent-side `register_source_pin_identities`, expected-path pre-registration, `unknown_operation_files`, and any deletion based solely on a matching source inode are removed as authority.

The disposable SQLite connection uses the guarded VFS. `VACUUM INTO` receives an opaque virtual destination mapped to an already-authorized directory/basename; it cannot open an arbitrary filesystem path. Reads, hashes, independent restore verification, and durability checks use retained descriptors.

### 11.2 Publish state machine

After backup and manifest staging are independently verified:

1. fsync staged backup and staged manifest;
2. descriptor-relatively publish the final backup without overwriting;
3. durably record the final-backup acquired receipt;
4. fsync the backup directory;
5. descriptor-relatively publish the final manifest **last** without overwriting;
6. durably record the final-manifest acquired receipt;
7. fsync the backup directory;
8. append and fsync the ledger `committed` transition;
9. return the artifact only after reopening/verifying the committed pair by descriptor.

The final manifest remains the commit marker. A final database without a final manifest is never treated as committed. If its acquired receipt is durable, the guardian may remove it during abort. If only intent is durable, it is preserved as ambiguous and future attempts return `cleanup_pending`. A preexisting or detected substituted final name is never deleted; the hostile same-UID check/unlink race remains bounded as stated in Section 15.

Duplicate operation IDs return the existing artifact only when the committed ledger transition, manifest, database digest, modes, identities, and verification all agree. Otherwise they fail closed without mutation.

### 11.3 Crash and reply-loss acceptance

Deterministic faults must cover death:

- after every private-SHM/staging mutation and before worker reply;
- after staged snapshot creation and after independent restore creation;
- after final backup publication but before worker reply/ledger acknowledgement;
- after final backup fsync and before manifest publication;
- after manifest publication but before committed acknowledgement;
- after the held backup directory is renamed and before a reply;
- while `LedgerStore`, `AnchorOwner`, guardian, or operation worker is restarting;
- during graceful abort and supervisor shutdown.

For in-VM worker/broker death, cleanup completes or remains observable under the guardian. For an unacknowledged whole-VM mutation, the exact candidate is preserved and reported ambiguous on replay. In no case may cleanup return settled success merely because an expected old pathname is absent.

## 12. Provenance, generator, and bounded opens

### 12.1 Provenance descriptor closure

Provenance policy/digest comparison remains a pure `swarm_code_core` concern. The effectful provenance reader moves behind a daemon/build-tool adapter that uses the same `FS.Directory`/`FS.File` resources from the vendored Exqlite native boundary; core does not acquire a daemon dependency. The root `swarm_code.provenance.verify` Mix task composes that adapter with the pure validator.

The native provenance JSON-reader and destination-hash branches explicitly close every resource after `fstat`, identity comparison, size admission, read, hashing, timeout, malformed input, exception, or caller cancellation. The existing 1 MiB policy/ledger limit, 64 MiB extracted-destination limit, incremental hashing, monitored one-second worker, and deterministic FIFO/malformed/race errors remain. No standard-library pathname-open fallback is permitted for verification.

Tests repeatedly force an identity mismatch immediately after open in both read and hash paths under a low descriptor limit or test-native resource counter. After each terminal result, open descriptor/resource counts return to baseline. FIFO and oversized-file cases remain nonblocking.

The Mix task may load the native adapter without starting Repo, the daemon runtime, a socket, scheduler, or desktop code. Core purity is preserved by dependency inversion, not by weakening no-follow/nonblocking descriptor guarantees.

### 12.2 Generator and basename closure coverage

The manifest generator retains external staging and identity-bound publication. Add a deterministic barrier between parent admission and publication, rename/retarget an ancestor, and prove output remains inside the held destination while the upstream checkout identity/status and generated bytes remain unchanged.

Every broker/source/destination basename shape has direct regressions for `.` and `..`; malformed names are rejected before a filesystem syscall. Existing bounded JSON/1 MiB/no-ETF/no-runtime-atom guarantees remain unchanged.

## 13. Production guards and error model

The production artifact enforces all of these boundaries:

- only canonical `BootConfig` and opaque filesystem/lease/database capabilities enter foundation APIs;
- actual validated Ubuntu process XDG variables are resolved once by `BootConfig.current/0`, while `DATABASE_PATH` and caller-injected home/XDG/environment maps cannot redirect normal startup;
- raw lease keywords, raw owner-record maps, raw descriptors, absolute mutation paths, cleanup callbacks, fault points, and test barriers are rejected or not compiled;
- the Exqlite fork is immutable, bundled, and uses its own SQLite amalgamation;
- no `EXQLITE_USE_SYSTEM`, runtime native download, path-open fallback, `:prim_file` internal API, ETF boundary, distributed Erlang, or runtime atom creation is present;
- database, sidecar, lease, socket metadata, cleanup ledger, backup, and manifest entries enforce trusted UID and exact private modes;
- special bits fail the same checks as group/world access.

Native fault barriers exist only in a test build guarded by an explicit compile definition. Release symbol/invocation scans must prove they are absent from all four production NIFs.

Failures use `StartupError` or a focused typed native error translated once at the daemon boundary. Required stable codes include:

- `native_guard_unavailable`;
- `unsafe_private_directory`;
- `foundation_lock_held`;
- `lease_held`, `lease_binding_changed`, and `lease_privacy_changed`;
- `database_binding_changed`, `ready_already_consumed`, and `repo_binding_failed`;
- `cleanup_pending` and `cleanup_ledger_corrupt`;
- the existing `schema_incompatible` and `backup_failed`.

Messages contain a safe explanation and corrective action, never raw secrets, receipt contents, descriptors, arbitrary native strings, or unbounded paths. Cleanup ambiguity is retryable only through inspection/reconciliation; it is not silently retried as a destructive delete.

## 14. Verification and packaging matrix

### 14.1 Test discipline

Implementation is test-driven. Tests use task-owned temporary roots, deterministic native barriers, messages, monitors, exact OS PIDs, and supervised children. They never sleep, poll `Process.alive?/1`, touch the real development database, or infer filesystem ownership from a name.

Focused suites must include:

1. **Native capabilities:** no-follow/nonblocking open, component races, exact modes/UIDs/special bits, owned-receipt scope, rename-safe held descriptors, fsync, double close, malformed term fuzzing, and resource-count return to baseline.
2. **Lease:** all races in Section 6.3, including five consecutive full OS-process race-suite seeds.
3. **Schema/Repo:** compatible/legacy/incompatible fixtures, canonical main/WAL/SHM byte invariance, WAL-only/no-SHM, post-Ready swaps, one-shot consumption, full pool attestation, guarded reconnect, and binding-loss shutdown.
4. **Cleanup supervision:** pending-to-terminal observation for DirectoryHelper, ExternalCommand, lease cleanup, probe cleanup, and backup cleanup; supervisor termination reaps exact descendants.
5. **Backup ledger:** valid replay, torn/corrupt/hash-chain failure, capacity reservation, idempotent record retry, worker/broker death, final-DB reply loss, manifest-last ordering, directory rename/replacement, ambiguous preservation, committed idempotency, and replacement invariance.
6. **Closure debts:** main/WAL/SHM wrong modes and special bits, injectable wrong UID, direct dot-name rejection, generator ancestor retarget, provenance mismatch leak, and production boundary probes.

Every test that expects refusal records before/after digests and modes for canonical and adversary-controlled files. Cleanup tests inspect the held directory identity, not only the old path.

### 14.2 Native quality gates

The fork and filesystem/VFS patch run:

- C compiler warnings as errors;
- native unit tests for resource state machines and VFS filename admission;
- AddressSanitizer and UndefinedBehaviorSanitizer jobs on supported CI hosts;
- seeded malformed-term/property tests through the NIF API;
- cancellation and repeated open/close/connection-crash stress;
- proof that long reads/hashes use dirty I/O schedulers and fixed memory;
- a patch-size/source manifest review against pristine Exqlite 0.39.0.

A reproducible NIF crash, hang, descriptor leak, unbounded scheduler stall, unguarded SQLite open, or sidecar escape blocks promotion regardless of Elixir test status.

### 14.3 Four native target gates

The exact same foundation acceptance runs in target-native release builds for:

| Target | Minimum runtime |
|---|---|
| `macos-arm64` | macOS 14+ Apple Silicon |
| `macos-x86_64` | macOS 14+ Intel |
| `ubuntu-22.04-arm64` | aarch64 GNU/Linux, glibc 2.35 floor |
| `ubuntu-22.04-x86_64` | x86_64 GNU/Linux, glibc 2.35 floor |

Each target must prove:

- offline start on a clean host with bundled ERTS/Elixir and no compiler/system SQLite;
- expected Mach-O/ELF architecture, linked libraries, deployment target, RPATH/RUNPATH, and Linux `GLIBC_* <= 2.35` for ERTS, the forked Exqlite NIF, and every helper;
- the bundled SQLite source ID/version and guarded VFS identity match release metadata;
- directory `flock`, descriptor-relative syscalls, pinned-descriptor probe, private SHM rebuild, exact lease transaction, OS-process races, `SIGKILL` release, pool reconnect, and backup crash replay all pass on the real filesystem;
- no NIF or native asset download occurs on first boot;
- production test/fault symbols are absent;
- these foundation matrix archives are internal acceptance artifacts and are labeled nonrelease if unsigned; any later **public** macOS asset requires nested native signing, hardened-runtime verification, notarization, and Gatekeeper acceptance, with no credentials-optional exception.

Cross-compilation alone is not evidence. A target that cannot run the lease, VFS, WAL-only, reconnect, and crash-recovery suite is unsupported and no artifact is published for it.

### 14.4 Repository gate

Before promotion, from a clean checkout and clean shell:

- the root `MixProject.cli/0` declares `preferred_envs: [precommit: :test]`, so the authoritative plain `mise exec -- mix precommit` runs every umbrella alias step in the test environment and passes without warnings or transient logger/native noise;
- `MIX_ENV=prod mise exec -- mix compile --warnings-as-errors` passes;
- a real `MIX_ENV=prod mise exec -- mix run --no-start` probe rejects raw paths/options and an exported `DATABASE_PATH`;
- provenance verifies the Exqlite fork baseline/patch authorization and all extracted-source entries;
- generator output is byte-identical to the audited migration source;
- no generated database, WAL, SHM, cleanup ledger, backup, NIF build residue, key, or credential is tracked;
- exact child-process and task-owned temporary-root scans are clean.

No browser test applies to this terminal-free foundation milestone.

## 15. Guarantee classes, impossibility, and support boundaries

This design fails closed where POSIX cannot provide a stronger proof. Product and test language must preserve these limits.

| Situation | Promised behavior |
|---|---|
| Two compliant CLI runtimes using an unchanged anchor set, or a replacement of only one coordination name | Dual directory locks plus the exact SQLite lease admit at most one owner. |
| Active same-UID mutation that remains reachable through either held anchor | Identity/mode/content assertions detect drift, freeze admission, and shut down without opening a replacement. |
| Operation-worker, broker/helper, or reply-path death while the foundation supervisor and namespace anchor remain alive | The independent anchor, durable ledger, and guardian complete cleanup or publish an observable terminal pending state. |
| Whole-VM/power loss in the mutation-to-ledger interval, or loss of every descriptor to a directory renamed beyond the bounded recorded parent | Preserve ambiguous objects, report `cleanup_pending`, and perform no inferred deletion. |

1. **Current desktop race:** the released desktop does not acquire either directory lock or the SQLite lease. Detection before and after CLI acquisition cannot stop it from starting later. Concurrent desktop/CLI use remains unsupported until the desktop implements the reciprocal protocol. Users must quit desktop before CLI and stop CLI before desktop. There is no force option.
2. **Malicious same-UID process:** file modes, advisory locks, random names, and descriptor rechecks prevent accidents and common substitution races; they are not a security boundary against code already running with the user's full UID. Such code can ignore `flock`, chmod files, ptrace the VM where permitted, tamper with private state, or replace both directory anchors. The application detects reachable drift and stops, but cannot promise exclusion against this adversary.
3. **Mutation-to-ledger crash interval:** POSIX does not atomically combine a namespace syscall with fsync of a separate cleanup ledger. Whole-VM or power loss after a mutation but before durable `acquired` is inherently ambiguous. The only safe automatic behavior is to preserve the candidate, record/report `cleanup_pending`, and require inspection; deleting an intent-only match would reintroduce I2.
4. **Lost directory location:** an open descriptor remains useful across rename while its owner lives. After all holders die, POSIX offers no portable global inode-to-path lookup. If bounded search beneath the still-identical recorded parent cannot relocate the exact directory, cleanup remains pending and does not claim the moved artifacts are gone.
5. **Native failure domain:** the guarded VFS must live in SQLite's native library, so memory corruption in that code can crash the VM. The narrow API, pinned fork, sanitizers, four-target stress, supervision, durable ledger, and kernel lock release reduce impact; they do not turn a NIF into an isolated OS process.
6. **Filesystem support:** guarantees are made only for supported local filesystems on the four target OS families. Network filesystems or hosts whose `flock`, hard-link, fsync, or SQLite locking semantics fail the native acceptance suite are refused or unsupported; the runtime does not silently downgrade to pathname opens.

These are not reasons to weaken checks. They define when the only truthful result is refusal or observable pending recovery.

## 16. Delivery order and promotion gate

Implementation order follows dependency direction:

1. pin and attest the Exqlite 0.39.0 fork; implement opaque native resources and descriptor-relative primitives;
2. replace pathname private-directory mutation and introduce typed lease config;
3. introduce foundation cleanup supervision and migrate raw reapers/lease cleanup;
4. implement the generic durable ledger, anchor, guardian, and receipt handshake required by every temporary namespace;
5. implement dual directory locks and exact guarded lease acquisition, including mode drift;
6. implement private-SHM schema probing and canonical byte-invariance checks atop the receipt/guardian layer;
7. implement `DatabaseBindingOwner`, one-shot `ReadyCapability`, `RepoLauncher`, full-pool attestation, and guarded reconnect;
8. rebuild backup ownership, verification, manifest-last publication, and replay atop the same ledger/anchor primitives;
9. close provenance, generator, dot-name, permission, and production acceptance debts;
10. run native, repository, and four-target gates; perform a fresh whole-branch safety review.

The branch must not merge merely because broad tests pass. Promotion requires an independent whole-branch review to find no unresolved Critical or Important issue in:

- exact SQLite-opened lease inode binding;
- directory-lock and lease lifetime;
- canonical main/WAL/SHM admission and probe immutability;
- one-shot Ready-to-Repo consumption and reconnection;
- backup ownership, manifest-last publication, ambiguity handling, and rename-safe cleanup;
- supervised/observable reapers;
- descriptor/resource closure;
- production path/fork/package guards.

Promotion also requires the spec-only protocol-v2 amendment to desktop compatibility spec 53. It does not authorize or require a desktop implementation change in this branch.

Only after that review may the foundation merge to `main` and later engine, IPC, TUI, and installer plans depend on it.

## 17. Acceptance checklist

The residual-hardening milestone is accepted only when all statements below are true:

- SQLite's lease main file is a duplicate of the exact admitted descriptor; no hard-link alias/pathname is used for that main open.
- Runtime and data directory locks, the lease transaction, exact modes, and canonical identities remain live and asserted through Repo shutdown.
- Replacing a single coordination name cannot produce two cooperating CLI owners.
- Schema probing never aliases or mutates canonical SHM and preserves exact main/WAL/SHM bytes on every success/failure fixture.
- A compatible schema yields an opaque, live, one-use capability; it cannot be reused or converted back into a path.
- Every initial and replacement Repo pool connection attests to the same guarded binding before serving a query.
- A post-Ready swap refuses before query/write and there is no production pathname reconnect.
- Every cleanup task has a supervisor, stable ID, bounded caller settlement, and observable terminal/pending state.
- Every deletion is authorized by a durable acquired receipt from the creating mutation; intent-only/name/inode matches are preserved.
- Final backup publication is database first, manifest last, directory-fsynced, ledger-committed, independently reopened, and idempotently verified.
- Broker/worker death and renamed-directory tests never return false cleanup success or touch a replacement.
- Provenance mismatch races return descriptor/resource counts to baseline.
- Production rejects raw alternate configuration and system SQLite; the fork/NIF is pinned, attested, and offline.
- All focused, precommit, production, native sanitizer, OS race, and four-target packaged suites pass cleanly.
- Documentation continues to state the desktop race, malicious-same-UID boundary, and mutation-ledger ambiguity without claiming more protection than the implementation can provide.
