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
