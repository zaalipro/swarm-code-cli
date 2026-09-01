# Task 6 report — desktop schema compatibility manifest

## Result

Implemented the exact pinned desktop migration manifest, deterministic data-free SQL schema
fixtures, strict runtime decoding, a read-only SQLite probe, and the compatibility decision gate.
No Task 7 backup implementation was added.

## TDD evidence

- RED: `mise exec -- mix test apps/swarm_code_daemon/test/swarm_code/daemon/schema`
  failed while compiling the deliberately missing
  `SwarmCode.Daemon.Schema.MigrationManifest.Entry` struct.
- GREEN: the same focused command completed with **13 tests, 0 failures**.
- Full gate: `MIX_ENV=test mise exec -- mix precommit` completed with core **20 tests,
  0 failures**, daemon **54 tests, 0 failures**, no CLI tests, and `provenance verified`.

The bare dev-environment alias is intentionally not used: Mix requires this umbrella's nested
`mix test` alias to be invoked with `MIX_ENV=test`, matching the milestone plan's final command.

## Reproducibility and fixture safety

Regenerated with the required command against
`dbb8804b3d7293178e571fa7afdf6bd47d06a51c`, then compared:

- manifest `cmp`: identical;
- fixture directory `diff -ru`: identical;
- committed manifest file SHA-256:
  `2556e5b4b288321f2391dc30f61771b2531de5819386918f3ce1fc0d34b973de`;
- generated SQL inserts target only `schema_migrations`;
- no generated `.db`, absolute upstream path, user row, transaction payload, or backup artifact is
  tracked;
- `/Users/zaali/dev/swarm-code` remained clean.

The generator uses only read-only Git commands against the upstream checkout, writes migration
sources solely inside its random mode-`0700` temporary directory, applies all 43 migrations one at
a time through a generator-only temporary Repo, hashes corrected binary schema iodata, and removes
the temporary directory in `after`.

## Self-review

- Manifest and entry JSON key sets are exact; all required fixed sentinels, canonical semantic
  versions, lowercase SHA-256 values, 43 strictly increasing filename-matched migrations, and the
  migration-set digest are validated before structs are returned.
- Runtime decoding does not call any atom-creation API.
- `SqliteQuery.rows/3` owns prepare, bind, step, and release with `try/after`.
- `Probe.inspect/1` accepts only an existing regular file, opens it with `mode: :readonly`, verifies
  `query_only` and foreign keys on the connection, and closes it on every path.
- Schema hashing converts the nested iodata to a binary before `:crypto.hash/2`.
- `Gate.check/3` accepts only an exact nonempty leading migration prefix with its corresponding
  normalized schema hash and enforces quick-check, FK, application-ID, SQLite, and reader-version
  constraints. Its tests prove exact/current, prefix, unknown, gap, drift, malformed file, and
  application-ID paths leave the database byte-for-byte unchanged.

## Concerns

None within Task 6 scope.

## Fix round 1 — review findings

### RED evidence

All review regressions were added before their production changes and failed for the reviewed
reasons:

- `mise exec -- mix test .../migration_manifest_test.exs`: **6 tests, 1 failure** — alternate
  canonical `minimum_reader` SemVer loaded without raising.
- `mise exec -- mix test .../sqlite_query_test.exs`: **3 tests, 3 failures** — the requested
  reducing API did not exist. The tests cover statement release on success, row-limit rejection,
  and reducer failure; binding and stepping failure release checks were included in the completed
  suite as well.
- `mise exec -- mix test .../gate_test.exs`: **12 tests, 4 failures** — Probe accepted a 44th
  migration, more than 512 schema rows, more than 4,194,304 normalized bytes, and materialized both
  FK diagnostic rows.
- `mise exec -- mix test .../generate_manifest_test.exs`: **1 test, 1 failure** — direct and
  aliased upstream destinations reached pinned-object lookup instead of being rejected by output
  confinement.

### GREEN evidence

- `mise exec -- mix test apps/swarm_code_daemon/test/swarm_code/daemon/schema`: **24 tests,
  0 failures**.
- Pinned regeneration again produced byte-identical JSON and SQL fixtures; upstream porcelain was
  identical before and after.
- `MIX_ENV=test mise exec -- mix precommit`: core **20 tests, 0 failures**; daemon **65 tests,
  0 failures**; no CLI tests; `provenance verified`.

### Fix-round self-review

- Decoder validation now retains canonical SemVer syntax validation and separately pins reader,
  writer, and SQLite minimums to `0.1.0-dev`, `0.1.0-dev`, and `3.51.3`.
- `SqliteQuery.reduce/6` owns prepare/bind/step/release and enforces a nonnegative row ceiling.
  Its fake-adapter tests observe the same prepared statement being released on success, limit,
  reducer, bind, and step exits. `rows/3` remains compatible but is bounded by default.
- Migration collection executes `LIMIT 44`, materializes at most the 44-row sentinel, and rejects
  that sentinel rather than accepting more than the audited 43.
- Schema collection executes `LIMIT 513`, rejects the 513th row through the reducing API, masks an
  individually oversized SQL field inside SQLite, and incrementally hashes each unambiguous
  encoded field while enforcing the exact 4,194,304-byte aggregate ceiling. It never retains the
  schema row set or a full-schema encoding.
- FK probing asks only `SELECT 1 ... LIMIT 1`; every other probe query has an explicit bound, and
  quick-check is restricted to one diagnostic.
- Generator destinations and its temporary directory are resolved component-by-component through
  existing symlinks and normalized ancestors before any write. Any destination contained by the
  resolved upstream root is rejected. Successful generation records clean upstream porcelain and
  rechecks the exact value in `after`.
