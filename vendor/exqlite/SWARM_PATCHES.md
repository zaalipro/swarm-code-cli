# Swarm Exqlite feasibility fork

Version `0.39.0-swarm.1`, OTP application `:exqlite`. Baseline is Exqlite tag
`v0.39.0`, commit `266b34e46b20e1c48f497cb4fb338919c793efee`, from the pinned Hex
package recorded in `UPSTREAM.json`. The original MIT license is unchanged.
These are third-party fork files, not desktop-extraction provenance entries.

This fork contains **test/development-only read-only clean-fixture feasibility**.
It does not implement a production database binding, Ready consumption, writable
lease, journal/WAL/SHM support, or a guarded Ecto pool. Production compiles no
native feasibility exports and the public facade returns
`{:error, :native_guard_unavailable}`.

## Every changed or added upstream file

| Path | Change |
|---|---|
| `mix.exs` | Fork version; disable precompiler/download metadata; remove `cc_precompiler` and unrelated upstream development-tool dependencies/lint alias; native build environment fixes `MIX_ENV` and fixture switch; reject system SQLite. |
| `Makefile` | Compile `sqlite3_swarm.c` instead of standalone amalgamation; source attestation before object compilation; warnings as errors; reject system library/production fixture switch; distinguish fixture/plain object directories and always relink for mode changes. |
| `Makefile.win` | Compile wrapper, reject system SQLite and unsupported Windows fixture mode. Windows functionality/compilation is not tested or part of the supported target matrix. |
| `README.md` | Fork scope and provenance/build notice. |
| `c_src/sqlite3_nif.c` | Conditional feasibility resource/API inclusion and registration; conditional connection retention; guarded close refuses outstanding statements; guarded deserialize refuses; close-error caller cleanup under mutex; unused arguments explicitly cast to void, unused local removed, and zero NIF flags initialized for warning-clean compilation. Ordinary open/close API remains available. |
| `c_src/sqlite3_swarm.c` | Include pristine SQLite then guard in the same image. Suppress only pristine SQLite's unused callback parameters around that include; guard and NIF warnings remain errors. |
| `c_src/swarm_guard.h` | Narrow private interface between NIF and SQLite translation units, no BEAM raw-fd API. |
| `c_src/swarm_guard_vfs.c` | Read-only regular-fixture admission, exact descriptor duplicate, complete Unix bookkeeping, close callback, temporary VFS registration, identity and disposal. |
| `c_src/swarm_guard_nif.c` | Opaque retained resource, one-use open, explicit close, typed identity, proof counters/close callback attestation; all native API entries dirty IO. |
| `lib/exqlite/sqlite3_nif.ex` | Compile fixture NIF stubs only in development/test. |
| `lib/exqlite/swarm_guard.ex` | Development/test facade and production typed refusal. |
| `UPSTREAM.json` | Immutable upstream identity and original SHA-256 for every copied baseline file. |
| `SWARM_PATCHES.md` | This patch and safety record. |
| `scripts/attest-source.py` | Fixed SQLite/license input and source-only build metadata checks. |
| `scripts/run-feasibility.py` | Build both modes and run native/lifecycle, ordinary Ecto, and production checks in isolated `_build` paths without Mix. |
| `test/swarm_guard/feasibility.exs` | Descriptor substitution, handlers, read-only/stale/close refusal, owner death, GC, registration and known incompatible-fixture checks. |
| `test/swarm_guard/ecto_compat.exs` | Ordinary Ecto parameter/transaction/restart persistence against a private fixture. |
| `test/swarm_guard/production.exs` | No native fixture exports, refusing facade, and ordinary in-memory SQLite. |

`c_src/sqlite3.c`, `sqlite3.h`, `sqlite3ext.h`, `LICENSE`, and all unlisted copied
upstream implementation files are byte-identical. SQLite source ID is unchanged.
The source-only native build never uses a precompiled NIF URL or system SQLite.
The unrelated upstream development-tool dependencies (`ex_sqlean`, `ex_doc`,
`temp`, `credo`, `dialyxir`) and their lint alias are removed so a root test/dev
build does not introduce tool downloads. Runtime dependencies are unchanged.

## Lifetime and registration

Admission retains the read-only pinned fd. An actual Exqlite connection retains
the admission resource; Exqlite statement resources retain the connection.
Explicit guarded `sqlite3_close` refuses outstanding statements. Finalization
then close invokes the actual Unix `xClose`, after which connection retention is
released and explicit admission close can dispose the fd/VFS. GC follows the same
resource reference graph; killed BEAM owners are covered with and without live
statements, and transfer to another live owner is covered.

VFS registration exists only around synchronous `sqlite3_open_v2`, with a native
random name never returned to BEAM, and unregisters on success or failure. No
registration is retained for a dormant admission or live connection. SQLite's
file object retains its VFS memory through admission ownership.

Native counters confirm admitted resources, guarded connections, and temporary
registrations return to zero in the tested lifecycle cases. Close attestation
records `unixClose` completion, not an fd-number lookup after close. Under future
same-inode concurrency SQLite may defer a descriptor in its unused list; closing
the separate admitted fd can also release process-wide POSIX locks. Therefore
this design must not be promoted to concurrent guarded pools without additional
ownership/locking work.

Explicit native entry points are dirty IO. Resource destructors still use the
upstream NIF destructor execution model and may execute close/finalize on a
normal scheduler. The current bounded tests establish cleanup, not a production
latency guarantee. A production cleanup worker/supervisor ownership design is a
separate prerequisite.

The fixture precheck rejects WAL header bytes and currently present journal,
WAL or SHM names. Those pathname observations are not a race-safe canonical
admission policy. `xAccess` intentionally reports absence for these controlled
fixtures, sidecar open/delete refuses, and shared-memory mapping refuses. Never
use this API for an arbitrary/live/canonical database or hot-journal recovery.

## Local verification

From the CLI repository root after its ordinary dependencies have compiled:

```sh
python3 vendor/exqlite/scripts/run-feasibility.py
```

The script copies existing dependency beams into its own `_build` directories,
compiles this fork's actual native library and changed Elixir modules, tests both
development/test and production builds, and runs both forbidden-build probes.
No root Mix, dependency source, or shared compiled artifact is written. Tests
create/remove their own fixture directories; they do not use canonical paths.
Copied-beam compatibility does not replace a coordinated root Mix integration
and complete upstream regression suite.

Cross-platform native/OS-floor, sanitizer, adversarial namespace/lifecycle and
full production binding/lease/Ready/pool checks remain separate requirements.


## Production directory capability predecessor

The native production directory API is independent of the fixture SQLite API.
`c_src/swarm_directories.c` (new) is included by `c_src/sqlite3_nif.c` and owns a
bounded directory graph with captured BEAM owner monitoring, component-wise
no-follow admission, descriptor-relative child opens and runtime-first/data-second
nonblocking flock. `lib/exqlite/directory_scope.ex` (new) delegates to new NIF stubs
in `lib/exqlite/sqlite3_nif.ex`. It accepts no raw descriptors and confers no
SQLite/Ready/canonical-database authority. It performs no mkdir/chmod/unlink.

The separate refcounted native control block owns all directory descriptors.
Owner-down and resource destruction only revoke/enqueue a preallocated cleanup
node. One NIF-owned cleanup thread closes graphs; explicit close is dirty IO.
Unload stops/drains/joins the thread. Hot NIF upgrade now refuses because native
resource/thread takeover is not implemented. Close errors are retained as a
terminal failure rather than reported as clean closure.

`test/swarm_guard/directory_scope.exs` (new) exercises real external-process flock
contention, rollback after data-lock failure, owner death with copied resources,
private directory admission, replacement detection and bounded directory capacity.
The GC case drops all terms while its owner stays alive and verifies external
lock acquisition before allowing owner exit, independently of owner-down cleanup.
Unsafe-mode fixtures use native `os.chmod` and verify actual modes: OTP's
`File.chmod(01700)` on the tested macOS host cleared the special bit.
`scripts/run-feasibility.py` now compiles the directory facade and runs those tests
in both native test and production modes. Target-native runtime verification is
required after applying this change; this record alone is not test evidence.

Root local verification passed the isolated test/production runner (24 tests),
the corrected owner-alive GC suite (eight tests), and coordinated Mix integration
(three guarded-fork tests including actual external-process directory locks).
No sanitizer, global-capacity failure injection, unusual filesystem, hot-upgrade,
or supported-target matrix result is claimed by those checks.


## Production guarded lease predecessor

`c_src/swarm_lease.h`, `swarm_lease_vfs.c`, and `swarm_lease_nif.c` (new) add one
fixed `instance_lease.db` child to the production directory scope. The SQLite
translation unit includes the new VFS after pristine SQLite; the directory NIF
includes its ownership adapter. `lib/exqlite/guarded_lease.ex` and new stubs expose
only acquire/assert/identity/close/status, not SQL, fd integers or Exqlite db
resources. `test/swarm_guard/guarded_lease.exs` adds real SQLite/flock and fresh
OS-producer acceptance cases. The isolated runner builds/tests this facade in
both modes. `swarm_directories.c` gains child retention/drain and scope-close
refusal; NIF exports and wrapper include wiring are updated.

Lease creation is exclusive and descriptor-relative. Main opens duplicate the
admitted fd; rollback journals have exact main/journal role identities, real
access/open/delete and retained-parent sync. WAL/SHM/FAT paths refuse. Existing
lease compatibility is checked using a read-only SQLite handle before writable
operations: no schema entries, application_id zero, user_version zero or one.
The read-only handle fully closes before writable exclusive acquisition; the
same policy is checked under the exclusive lock before initializing a zero-byte
legacy/new lease. Unknown hot-journal recovery that would require writes during
compatibility checking refuses. No occupied arbitrary SQLite schema is adopted.

Directory scope cleanup closes SQLite and all lease descriptors before releasing
data/runtime flocks. Explicit scope close refuses an active lease; explicit lease
close leaves directory locks held. Owner death or GC of an active lease revokes
and queues the existing native graph, even if other processes retain copied
opaque terms. Undrainable native state is quarantined with close_failed and held
exclusion instead of releasing directory locks beneath a live SQLite child.
A quarantined failure requires VM restart/diagnosis; healthy-path tests do not
claim fault-injection or recovery from that state. Production database bindings,
WAL/pools/Ready and daemon CrossAppLease replacement are still separate work.


### Lease close-result accounting

All owned lease descriptor closes now use `sl_close_owned_fd`: one OS close,
recorded result, no fd-number probe or retry. Main closure holds SQLite's Unix
global-before-inode mutex order, requires the single-connection inode with no
pending descriptors/SHM, checks `unixUnlock`, then reuses `releaseInodeInfo` and
`closeUnixFile` bookkeeping with `h` already detached. Thus stock cleanup cannot
silently close the owned duplicate. Journal and failed-open cleanup use the same
accounting. Unknown close/unlock or unexpected sibling/pending state marks native
uncertainty; successful logical detach never clears it. The scope quarantines
that uncertainty and retains directory flocks instead of reporting clean closure.
This is a bounded one-connection path, not a general pending-fd pool adapter.

`test/swarm_guard/lease_close_errors.exs` adds three targeted cases, run only in
test mode by the isolated runner. Test builds install a SQLite close syscall hook
once before NIF callers run and restore it after cleanup-thread drain. It filters
by a thread-local lease, exact currently-owned closing fd and armed site; unrelated
closes pass directly to the saved OS call. The real close runs once, then the
fault model reports EIO (a consumed-descriptor error). This is injected close
failure evidence, not a real filesystem-fault or fd-still-open simulation.
Production contains no hook/injection exports. No pointer or fd is exposed to
BEAM. The three RED cases exercised actual stock SQLite close behavior before the
production accounting change, not a cloned failing implementation.

Quarantine remains a VM-restart-only failure disposition. It does not establish
safe NIF unload/reload, same-VM operator recovery, or normal lifecycle completion.
The native control retains memory/anchors/flocks in that state; the test process
must exit to dispose a quarantined injected-fault fixture completely.
