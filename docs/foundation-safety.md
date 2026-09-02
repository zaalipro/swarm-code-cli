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

## macOS safety limitation

The current macOS desktop release does not acquire the shared SQLite lease. SwarmCode CLI detects an already-running desktop before and after acquiring its own lease, but the desktop can still start after the second check. Concurrent desktop/CLI operation is unsupported. Quit the desktop before starting the CLI daemon, and stop the CLI daemon before reopening the desktop. There is no force-unlock option.

The signed macOS bundle-identity detector is a separate follow-up spike. Until it is available,
macOS startup fails closed with `:macos_platform_helper_unavailable`; the CLI never falls back to
process-name matching or kills a desktop process. Linux uses the no-op detector after its trusted
identity and path checks.

## Recovery and data guarantees

The lease is held before any later schema or backup admission and is released on every refusal. The
schema probe opens the canonical database read-only and does not establish missing metadata. Backup
creation is SQLite-engine based, independently restorable, mode `0600`, and leaves the source and
its sidecars unchanged. Failure paths are static, redacted `StartupError` values; callers should
inspect the action and preserve any retained artifact rather than deleting lease or backup files.

The approved architecture and sequencing are recorded in
[`docs/superpowers/specs/2026-09-01-swarm-code-cli-design.md`](superpowers/specs/2026-09-01-swarm-code-cli-design.md)
and [`docs/superpowers/plans/2026-09-01-foundation-safety-gate.md`](superpowers/plans/2026-09-01-foundation-safety-gate.md).
