# Guarded writable storage handoff review

_Date: 2026-09-08 · scope: CLI checkout only · read-only audit_

## Recommendation

The smallest correct production path is to finish the existing Foundation-to-Repo capability handoff before adding any writable daemon behavior. Keep `FoundationGate.Ready` as an admission result, but make its database authority an opaque, supervised, one-use capability consumed only by a guarded Repo launcher. Do not reopen `ready.paths.database`, and do not add an independent JSON/SQLite store or a pathname fallback.

The first useful writable vertical slice after that predecessor is daemon-owned history/`mark_seen`, using the existing client `DataSource` seam. Provider/run execution should follow only after restart, reconnect, and lease-loss behavior is proven.

## Already implemented

- `FoundationGate.prepare/1` performs canonical path resolution, trusted identity, private-directory checks, desktop detection, fingerprinting, `CrossAppLease` acquisition, schema manifest/probe admission, and typed refusal for new or migration-required databases. It returns `%FoundationGate.Ready{paths, identity, lease, schema, backup, binding}`.
- `CrossAppLease` is supervised and owns `Exqlite.DirectoryScope` plus `Exqlite.GuardedLease`; runtime then data locks are acquired nonblocking, owner records are atomically published, physical identities are rechecked, and cleanup closes lease before scope. `assert_held/1` fences changed bindings.
- Native directory and lease APIs are production-capable: `DirectoryScope.new/open_root/open_child/identity/lock/assert_locked/close/status`; `GuardedLease.acquire/assert_held/identity/close/status`. Owner death revokes the resource graph.
- The schema/backup path uses the complete locked SourceSnapshot and does not touch canonical SHM during probing. `Exqlite.SwarmGuard` is intentionally fixture/dev/test only and returns `:native_guard_unavailable` in production.
- Existing client transport contracts (`DataSource`, request bounds, epoch/revision correlation, fake source) are suitable for a daemon adapter. No persistent daemon service or Repo startup is wired yet.

## Missing production pieces

1. **Supervised foundation ownership:** `FoundationBootstrapSupervisor`/attempt and a long-lived capability owner must retain scope, locked directories, lease, pinned database descriptors, and cleanup ownership. The caller, renderer, or request worker must never temporarily own these resources.
2. **One-use Ready capability:** replace metadata/path authority with an opaque `ReadyCapability` state machine (`probed -> starting_repo -> live -> closing/closed`). A copied term, stale generation, second consumer, owner death, or failed start must be terminal and typed.
3. **Guarded Repo launcher and adapter:** add `RepoLauncher.consume/2` as the only production promotion API. It starts a private per-generation Ecto Repo, passes an opaque `:database_binding` connection option, and extends the vendored Exqlite connection path to select that binding before normal path validation. The binding path must never call `Sqlite3.open(path, ...)`, `Path.dirname`, or `File.mkdir_p`.
4. **Pool barrier and reconnect authorization:** eagerly open every configured pool connection, initialize pragmas, attest exact main identity/generation, and publish `live` only after all pass while lease/locks still assert. Lazy/replacement connections must obtain a fresh one-use authorization from the binding owner and fail closed on any identity, sidecar, mode, or lock drift.
5. **Foundation supervision/cleanup settlement:** add the ordered shutdown boundary (Repo/connections, binding, operations, lease, data lock, runtime lock, directories), plus observable cleanup-pending ownership. Lease must remain held until supervised cleanup is terminal or explicitly observable.

## Exact native/vendor touch points

- `vendor/exqlite/lib/exqlite/connection.ex` (open/bootstrap branch): accept only the opaque binding option for production; reject ordinary pathname reopening for that branch; preserve normal non-production behavior.
- `vendor/exqlite/lib/exqlite/sqlite3_nif.ex`: expose the production binding-open/attestation/reconnect primitives needed by the adapter, without exporting fixture `SwarmGuard` admission in production.
- `vendor/exqlite/c_src/swarm_guard_vfs.c` and its NIF wrapper: evolve the current test-only exact-main VFS into a descriptor-relative writable binding. Retain SQLite Unix VFS state initialized by `unixOpen` (not merely `fillInUnixFile`), allow only canonical main plus fixed WAL/SHM/journal suffixes relative to the retained data directory, enforce `0600`/UID/mode and sidecar identity transitions, and close/attest every connection.
- `vendor/exqlite/c_src/swarm_directories.c`, `swarm_lease_nif.c`, `swarm_lease_vfs.c`: reuse current scope/lock/lease assertions and add any binding-generation/connection authorization state; preserve owner checks, revocation, and lease-before-scope close ordering.
- `vendor/exqlite/lib/exqlite/guarded_lease.ex` and `directory_scope.ex`: keep the narrow wrappers; add only opaque binding capability types and assertion APIs, never raw paths or constructors usable by clients.
- `apps/swarm_code_daemon/lib/swarm_code/daemon/foundation_gate.ex`: return the supervised capability and safe metadata, not a pathname-authoritative Ready struct. Preserve all current refusal branches and macOS detector limitation.
- `apps/swarm_code_daemon/lib/swarm_code/daemon/cross_app_lease.ex`: retain as the lease owner; integrate it beneath the foundation owner and ensure Repo shutdown precedes `GuardedLease.close/1` and `DirectoryScope.close/1`.
- New daemon modules should be limited to `foundation_gate/attempt.ex`, `foundation_gate/ready.ex`/capability owner, and `repo_launcher.ex` (plus binding owner); domain persistence starts only after this boundary.

## Safety conditions and evidence required

- No production trace may reach an Exqlite pathname-open branch, and no code may derive authority from `Ready.paths.database`.
- Consumption is compare-and-set exactly once; failed launch consumes the capability and requires a fresh full gate/probe.
- Every initial, reconnect, and replacement connection proves exact admitted main inode, binding generation, lock/lease health, sidecar policy, and initialization completion before checkout.
- Canonical replacement, mode/UID/sidecar drift, revoked/stale/forged capability, duplicate consume, owner death, or lease assertion failure freezes admission, closes the pool, and reports typed `database_binding_changed`/handoff errors. No attempt is made to reopen the stored path.
- Shutdown order is Repo/connections, binding owner, operations/guardians, owner record, lease, data lock, runtime lock, directory scope. Cleanup timeout preserves the lease under supervision and reports a bounded pending identity.
- Production proof must cover multiple Ecto pool connections, WAL recovery and canonical SHM writes through the guarded VFS, lazy/replacement connections, restart/reconnect, and target-native builds. The existing `SwarmGuard` feasibility tests do not constitute this evidence.

Once this handoff is complete, wire the daemon's bounded history queries and revisioned `mark_seen` command through the existing `DataSource`; verify persistence across daemon restart and client detach/reconnect before adding provider or agent writes.
