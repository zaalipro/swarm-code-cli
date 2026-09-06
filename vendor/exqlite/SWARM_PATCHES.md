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
