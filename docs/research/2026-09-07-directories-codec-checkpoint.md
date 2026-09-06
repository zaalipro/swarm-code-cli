# Native directory ownership and client wire codec checkpoint

The source-built Exqlite fork now includes a production `DirectoryScope`
primitive. It owns opaque, bounded directory capabilities, admits paths through
descriptor-relative no-follow opens, checks effective UID and exact `0700`, and
holds runtime then data directory locks. Owner death and resource GC revoke
copied capabilities and queue native cleanup. Explicit close runs on dirty IO;
the cleanup thread drains before NIF unload. Hot NIF upgrades refuse.

This primitive does not open SQLite, create directories, acquire the SQLite
cross-application lease, or authorize canonical database/Repo startup. Those
remain dependent work. Its checks detect observed namespace changes; they do
not promise atomic exclusion of arbitrary same-UID filesystem mutation.

The new pure client `DataSource.Daemon.Codec` translates supported typed requests
into bounded protocol frames with remaining deadlines and distinct wire IDs.
It validates response kinds, envelope and body scope, detail reference/offset/
byte limits, and every nested request ID before restoring local IDs. Service
responses require explicit fields even where fixture decoders retain legacy
defaults. Error decoding accepts only fixed known code/message pairs. Steering
and approvals preserve real UUID node targets; membership is still the service's
responsibility. Socket transport, the daemon endpoint and live adapter are not
implemented by this codec.

Verification on this macOS checkout:

- Final `mise exec -- mix precommit`, seed `424977`, exited zero: **93 core + 403
  daemon + 532 CLI = 1,028 tests**, five properties, twelve native snapshot checks,
  plus formatting, compilation, dependency, provenance and Unicode checks.
  Log: `_build/live-coding-harness-verify/precommit-directories-client-codec-final.log`.
- The first full run found a 100 ms test-helper timeout for asynchronous initial
  snapshots. The same six tests passed alone at the original seed. The helper
  now allows two seconds against the source's one-second deadline; application
  deadlines and expected delivery assertions are unchanged. The full rerun above
  includes the fix and preserves failures for missing/error deliveries.
- The isolated vendor runner passed 24 tests across test/production builds,
  including ordinary Ecto compatibility and fixture-guard production refusal.
  Strict native builds and forbidden system-SQLite/test-mode checks passed.
- The corrected owner-alive GC test proves real OS locks release before its
  owner exits, independently of owner-down cleanup. All eight directory cases
  passed in isolated test/production and against the actual root production
  artifacts (`directory-root-production.log`, seed `32535`).
- Coordinated Mix integration passed eleven core, three daemon and ten client
  tests. Production compilation with warnings treated as errors passed.

Independent scoped native and codec reviews closed their findings. The native
mode test was corrected after OS and BEAM observations proved `File.chmod(01700)`
had produced `0700`; it now uses native `os.chmod` with observed-mode assertions.
The native privacy check was unchanged.

Sanitizers, injected native allocation/close failures, global-capacity recovery,
unusual filesystems, supported OS/architecture floors and full native performance
acceptance remain open. No user database or remote paid provider was accessed.
The executable TUI still uses its synthetic source. Next: guarded SQLite lease,
writable database binding/pools, certified persistence migration/store, local
service and live TUI adapter, then the remaining advanced and release features.
