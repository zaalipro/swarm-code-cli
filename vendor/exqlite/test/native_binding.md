# Private writable binding predecessor

`native_binding.c` includes the pinned SQLite translation unit and the private
`c_src/swarm_binding_experimental.c`. The latter requires the explicit
`SWARM_BINDING_EXPERIMENTAL` define and is **not** included by the production
SQLite wrapper, Makefiles, NIF, or an Elixir API. Nothing here promotes Foundation
Ready or opens a user database.

The C interface is deliberately private: `sb_admit(parent_fd, &binding)` retains
an independently opened parent descriptor and exact existing main/sidecar
identities; `sb_open(binding, &db)` is the one-shot first-owner admission; internal `sb_connect` admits up to eight additional concurrent handles under an atomic bound. `sb_revoke`, `sb_close`, and `sb_dispose` settle that isolated lifetime. The basename
is fixed to `application.db`. No descriptor is exposed to BEAM.

The experiment uses the pinned Unix file IO and inode machinery, including an
owned unused-descriptor record for main, filesystem checks, `fillInUnixFile`,
explicit inode discovery, POSIX locking, and Unix close bookkeeping. Main opens
duplicate the admitted descriptor. Journal/WAL creation, existence checks, and
deletes use `openat`/`fstatat`/`unlinkat` beneath the held directory. Existing and
created roles require exact UID, `0600`, regular type and link count one; changed
identities revoke the binding. Canonical SHM uses descriptor-relative admission,
real shared mmap, the Unix lock-byte locations, and dead-man-switch recovery.
SHM remains on disk at orderly close, with descriptor cleanup at disposal.

## Reproducible checks

Run from the CLI repository root; all databases are owned `/tmp` fixtures:

```sh
cc -std=c11 -O2 -Wall -Wextra -Werror -Ivendor/exqlite/c_src \
  vendor/exqlite/test/native_binding.c -lpthread -lm \
  -o /tmp/swarm-native-binding-test
/tmp/swarm-native-binding-test

cc -std=c11 -O0 -g -fsanitize=address,undefined -Ivendor/exqlite/c_src \
  vendor/exqlite/test/native_binding.c -lpthread -lm \
  -o /tmp/swarm-native-binding-asan
/tmp/swarm-native-binding-asan
```

Both passed on macOS arm64 in this checkpoint. Checks execute real SQLite WAL
commits and reopen, inspect canonical WAL/SHM mode and size, recover a committed
WAL after a child exits without closing SQLite, switch through rollback journal,
refuse duplicate consumption and ATTACH, revoke writes, and preserve replacement
main/WAL files without writing to them. Tests explicitly reenable C assertions
after the SQLite amalgamation, which otherwise defines NDEBUG.

## Remaining production work

This is a writable native mechanics predecessor, not production admission:

- Up to eight live connections are supported in this predecessor. The directory flock excludes other instances of this experiment, **not** arbitrary SQLite users or desktop. Directory ownership and lease authority still need to come from the production native scope graph.
- SHM locks use per-connection shared/exclusive masks and aggregate process-level POSIX lock transitions under the binding mutex. Cross-process pool lock protocol, pending-descriptor handling and close-result attestation still require the production binding/File ownership graph.
- NIF resource ownership, supervised owner-death revocation, durable cleanup,
  initial pool/reconnect attestation and one-shot Foundation consumption are not
  implemented. The explicit C revoke test is not BEAM owner-death evidence.
- Stock Unix close result accounting does not provide the stronger production
  close-failure/quarantine guarantee already implemented for the lease VFS.
- The temporary VFS registration and SQLite handle lifecycle are synchronous;
  concurrency, external-process SHM contention, injected failures, symlink races,
  other filesystem behavior and all supported native targets need further proof.
- The fixed SHM region cap is 32 regions of 32768 bytes. No general database-size
  or production performance claim follows from the fixtures.
- Descriptor-relative identity checks and namespace mutation are not an atomic
  compare-and-unlink defense against malicious concurrent same-UID substitution.

The production binding predecessor now also rejects symlink, non-regular,
foreign-owner, or non-0600 WAL/SHM/journal entries during every binding
assertion. This closes the sidecar namespace hole in the pinned-resource layer;
it does not replace the descriptor-retaining VFS requirement above.

The binding resource destructor releases its retained lease reference after
explicit close as well as implicit destruction. A regression exercises 140
successive acquire/close/GC generations, exceeding the 128 live-scope limit;
without the fix it fails with `directory_capacity`. The five binding tests pass
against both test and production NIF builds. The production facade test also
confirms fixture exports remain absent.

Production promotion remains blocked on concrete missing behavior: retain exact
main/sidecar descriptors in one writable VFS, initialize full Unix file state,
route canonical SHM and rollback/WAL lifecycle through it, preserve the lease on
uncertain close, and authorize/attest every initial/replacement pool connection.
The current sidecar checks enforce file policy but deliberately do not claim to
detect replacement by another equally private regular sidecar. No connection
opener or temporary authorization-only API was added to mask that gap.

Preserve existing production lease and directory semantics while closing these
items, then add the real NIF/Exqlite `:database_binding` route. There is no fixture
API or pathname fallback that can stand in for that work.


## Multi-connection checkpoint

The predecessor now admits up to eight concurrent SQLite handles under one binding.
Each main handle retains its own Unix inode state while the binding retains sidecar
identity and shared mappings until the final handle closes. Per-handle SHM shared and
exclusive masks are aggregated under the binding mutex; the underlying process lock is
released only when no local handle retains that byte. Disposal and close refuse while
connections, statements, or role files remain.

The native test now proves three-handle reader snapshots, writer serialization and
replacement, a threaded `BEGIN IMMEDIATE` busy result, the eight-handle bound,
statement-held close refusal, retained SHM shared locks across one reader closing,
WAL recovery and sidecar replacement refusal. Strict and ASan/UBSan builds both pass.

This remains experimental: NIF resource ownership, supervised owner death, guarded
reconnect authorization, cross-process pool lock protocol, production close-error
quarantine, and descriptor-bound Exqlite `:database_binding` remain unimplemented.
