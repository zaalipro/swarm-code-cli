# Foundation safety gate

This milestone composes the SwarmCode CLI's pre-Repo startup checks. It resolves the canonical
paths, establishes trusted process identity, validates product-owned private directories, performs
the platform desktop check, computes a versioned database fingerprint, acquires the adjacent
rollback-journal lease, repeats the desktop check, validates the audited migration manifest, and
runs the read-only schema probe. It deliberately does **not** start `SwarmCode.Repo`, migrations,
Phoenix, sockets, MCP, the scheduler, or any user work.

`FoundationGate.prepare/1` returns a live lease only for an already compatible database. The
immediate long-lived caller owns that lease: it must monitor the lease and stop all Repo/work
descendants before stopping the lease itself. A new database is refused because creation is not
installed in this pre-Repo milestone. A database requiring migration is backed up through the
verified Task 7 gate, the backup pair is retained, and startup then refuses because migration
execution is not installed yet. No normal CLI startup path is implied by this infrastructure.

## Audited schema contracts

The current contract pins desktop `fb1b4ff82354ac8ff2e82d4f6516121fd55ff212`
and its 46 migrations through `20260929000000`. It includes provider fallback
preferences, node cache-token counters, and the consensus bench-layout setting.
The original `dbb8804b` manifest remains unchanged and can be validated explicitly.
Under the current contract, that exact 43-migration database requires the three
appended migrations; it is not silently treated as current or modified in place.

`Schema.Contract` pins the complete ordered entry digest for each audited source,
including every intermediate schema hash. Unknown commits, altered prefix hashes,
schema drift and more than 46 migration records reject. The probe reads at most
47 migration rows to detect overflow. The manifest reader enforces its 256 KiB
limit on the descriptor read before parsing JSON.

The [schema evidence](evidence/schema/desktop-fb1b4ff.json) records two actual
migration replays into fresh private fixture databases and exact preservation of
the historical prefix. The production generator also reproduces both contracts'
artifacts byte-for-byte. None of these commands reads a user database.

An explicit `Backup.Gate.create` request may back up an already-ready database as
well as a migration-required database. A ready decision must have no pending
migrations and its applied versions must match its probe. Both paths retain the
live lease, identity checks, source re-probe and independent restore verification.
Normal ready admission does not create a backup automatically.

## macOS safety limitation

The current macOS desktop release does not acquire the shared SQLite lease. SwarmCode CLI detects an already-running desktop before and after acquiring its own lease, but the desktop can still start after the second check. Concurrent desktop/CLI operation is unsupported. Quit the desktop before starting the CLI daemon, and stop the CLI daemon before reopening the desktop. There is no force-unlock option.

The signed macOS bundle-identity detector is a separate follow-up spike. Until it is available,
macOS startup fails closed with `:macos_platform_helper_unavailable`; the CLI never falls back to
process-name matching or kills a desktop process. Linux uses the no-op detector after its trusted
identity and path checks.

## Recovery and data guarantees

The schema probe now copies main/WAL under SQLite-compatible native locks and
opens SQLite only on the owned private copy. Its 24 focused gate tests pass,
including the three regressions that previously reproduced canonical SHM writes,
a successful fresh live-WAL probe, an absent-SHM source, and physical resolution
of symlink/.. inputs. Source bindings and
post-probe identity checks still refer to the canonical files.

Backup applies the same locked snapshot operation, then copies those files into
independent broker-owned inodes before opening SQLite. Snapshot cancellation
cannot remove the broker’s files. Fresh-WAL restore, requester loss, broker death
and duplicate-call convergence have focused regression coverage. Full precommit passed 825 tests, five properties and 12 native checks; production
compilation passed with warnings treated as errors. The broader native binding/one-shot Repo work and
platform acceptance remain incomplete.
The lease is held before schema or backup admission and released on refusal.
Backups remain SQLite-engine based, independently restorable, and mode `0600`.
Failure paths are static, redacted `StartupError` values; callers should
inspect the action and preserve any retained artifact rather than deleting lease or backup files.

The approved architecture and sequencing are recorded in
[`docs/superpowers/specs/2026-09-01-swarm-code-cli-design.md`](superpowers/specs/2026-09-01-swarm-code-cli-design.md)
and [`docs/superpowers/plans/2026-09-01-foundation-safety-gate.md`](superpowers/plans/2026-09-01-foundation-safety-gate.md).
