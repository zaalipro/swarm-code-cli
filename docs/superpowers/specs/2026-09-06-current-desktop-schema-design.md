# Current desktop schema contract

This extends the existing pre-Repo foundation for the user's current-desktop
parity goal. The previous terminal slice is committed at `4228d7d`. Scope is
schema admission and verified backup compatibility; persistent domain services
consume this contract next.

## Source and data model

Pin desktop `fb1b4ff82354ac8ff2e82d4f6516121fd55ff212`, observed read-only on
2026-09-06. It has 46 migrations. Its first 43 migration filenames, versions and
source SHA-256 values exactly match the retained `dbb8804b` contract.
The ordered migration-source-set digest is
`f04a55a27d1fee6a3192c6ff277993d4ab5a8f6414896e2be87dc3a41f48b75f`.

The appended migrations are:

| Version | Change | Source SHA-256 |
|---|---|---|
| 20260927000000 | `providers.fallbacks`, boolean, true, not null | `0482b215789eae12ad4044d3520582be4b80d7bad58f385d44aafd0b620fdff3` |
| 20260928000000 | `nodes.cache_read` and `nodes.cache_write`, integer, default 0 | `320d65d76cb08c54d6d12964a7fbfa5e474e08951b4897710454928bf316a681` |
| 20260929000000 | `settings.bench_layout`, string, `scales`, not null | `d2b8980ec14149a54a005d2cf91c6761897e209680acf6b215171be20828eba2` |

Generate normalized schema hashes by actually replaying all 46 pinned migrations
against a fresh private SQLite database. Independently compare the first 43
resulting schema hashes with the retained manifest. Preserve the old manifest and
its fixtures. Produce new fixtures for the 43-, 44-, 45- and 46-migration prefixes,
with `desktop-current.sql` representing the new final schema. No user database is
an input. Use a task-owned source clone beneath this checkout because the daily
desktop checkout contains pre-existing untracked specifications.

Migration names, hashes and generated SQL schema fixtures are compatibility
metadata, as in the original foundation plan. No desktop implementation module
is copied into the product. The original source-authorization/extraction ledger
continues to describe its existing baseline; this separately dated schema audit
does not rewrite that historical authorization.

## Closed contracts

A small `Schema.Contract` module owns the two admitted contract identities and
the largest supported migration count. It exposes fixed metadata for the legacy
and current pins, including source-set digest, final schema digest, snapshots and
a digest of every migration entry's semantic fields. `current/0` selects the new
pin; `fetch/1` accepts only the two exact commit strings. It accepts no runtime
module name, arbitrary registry entry or environment override.

`MigrationManifest.load!/0` loads the current artifact. Explicit `load!/1` can
validate either exact audited artifact, which keeps historical backup and
diagnostic inputs inspectable. Validation authenticates all entry fields, including
every intermediate schema hash and readability flag. The previous source-set
digest covered source identities but authenticated only the final schema hash;
an altered intermediate hash must now reject. Use an independently pinned digest
of deterministic length-prefixed entry fields, rather than JSON formatting, so
harmless JSON whitespace remains admissible.

The manifest reader opens a regular-file descriptor and reads at most 262145
bytes, accepting at most 262144. It closes the descriptor on every path. A
path-level size check followed by unbounded `File.read!` is insufficient. Existing
closed shape, digest, enum and atom-safety checks remain part of admission.

## Foundation and backup integration

`FoundationGate` embeds the current manifest and publishes its current epoch,
newest migration and source-set identity in lease metadata. `Schema.Probe`,
`Backup.Manifest`, and `DirectoryProtocol` use the shared maximum of 46; the probe
selects at most 47 migration rows so unknown newer schemas reject before unbounded
materialization. A genuine current fixture returns `:ready`. Exact older prefixes
return the precise pending suffix under the current contract. An unknown next
migration, gap, changed schema, or changed contract rejects without modifying the
database or its sidecars.

Backup verification must carry all 46 migration records through the real
directory broker, independent restore and manifest decoder. A backup of the
43-migration prefix remains restorable and preserves all source rows and values.
The current gate's migration-required path still produces a verified backup and
its existing implementation-not-installed outcome; this work does not execute
canonical migrations or start Repo.

## Verification and architecture

All work stays in `swarm-code-cli`. Use pinned `mise exec -- mix` and existing
private fixtures. Desktop source and data remain read-only. No source-policy
bypass, new database startup bypass, detector bypass, renderer adoption or provider
execution follows from schema admission.

Tests first reproduce intermediate-hash tampering and current-schema refusal.
Then prove current and legacy manifest admission, exact pending suffixes,
47-migration rejection, wrong current-column shape, backup/restore preservation,
foundation lease metadata, and unchanged refusal bytes. Re-run generation into a
second isolated output directory and compare every committed artifact exactly.
Independent review covers the source replay, contract authentication and the
schema/backup/foundation handoff. Finish with precommit and production compile.
