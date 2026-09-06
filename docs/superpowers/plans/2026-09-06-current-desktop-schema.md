# Current desktop schema implementation plan

> Use superpowers:subagent-driven-development for independent work and scoped
> review within the authorized CLI checkout. Continue without routine approval
> questions; the original full-parity goal and foundation architecture authorize
> this extension.

**Goal:** admit and back up the actual current desktop schema through the existing
foundation, with authenticated historical prefix hashes.
**Architecture:** two closed audited contracts, reproducible migration replay,
shared bounded schema limits, existing identity/lease/backup gates.
**Tech stack:** Elixir 1.18.4 / OTP 28.4.2, Ecto SQLite and Exqlite already pinned.
**Spec:** `docs/superpowers/specs/2026-09-06-current-desktop-schema-design.md`.

## Global constraints

- Edit only `/Users/zaali/dev/swarm-code-cli`; reference desktop read-only.
- Pin current source to `fb1b4ff82354ac8ff2e82d4f6516121fd55ff212` and retain
  `dbb8804b3d7293178e571fa7afdf6bd47d06a51c` metadata unchanged.
- Current count 46; source-set SHA-256
  `f04a55a27d1fee6a3192c6ff277993d4ab5a8f6414896e2be87dc3a41f48b75f`.
- Metadata input at most 262144 bytes; probe limit 47 rows; admitted count at most46.
- Preserve private mode0700 directories, mode0600 generated databases/backups,
  lease ownership, readonly unknown-schema refusal, no canonical migrations.
- Core/CLI never depend on daemon internals. No new dependency is required.
- Complete each behavioral RED/GREEN cycle before review. Do not weaken old tests
  by replacing a refusal assertion with shape-only acceptance.

## Task 1: Independently replay and attest the current schema

Files: `priv/schema/desktop-fb1b4ff.json`, new versioned SQL fixtures under the
daemon app; `docs/evidence/schema/desktop-fb1b4ff.json`; task-owned evidence under
`.superpowers/sdd/2026-09-06-current-desktop-schema/` and `_build`.

Consumes the exact source commit and existing 43-entry artifact. Produces all46
entries, final schema digest, semantic-lineage digest, fixture hashes and evidence
for Task2. Semantic digest encoding for each ordered entry is the concatenation
of five fields: decimal version, filename, lowercase source SHA-256, lowercase
schema SHA-256, and literal `true`; each UTF8 field is encoded as decimal byte
length, colon, exact bytes, LF. Hash the complete concatenation with SHA-256.

- [x] Create an isolated source clone under `_build`; check out the exact pin.
  Verify source clone clean and daily desktop porcelain unchanged before/after.
- [x] Inspect appended migration code, verify all43source identities unchanged,
  and independently compute the46source-set digest before executing migrations.
- [x] Replay the pinned migrations in a fresh private SQLite database using the
  existing generator's normalized-schema algorithm. Retain actual per-prefix
  schema hashes, not schema hashes predicted from hand-authored ALTER statements.
- [x] Verify first43generated entries equal the legacy artifact. Record immutable
  identities and exact prefix44/45/46 changes in the evidence file.
- [x] Write `desktop-fb1b4ff.json` with the existing exact manifest field shape.
  Retain legacy `desktop-dbb8804b.json`. Copy the old final fixture unchanged to
  `desktop-20260926000000.sql`; add27/28/29versioned fixtures and replace current
  with the46final fixture. Old23/24fixtures stay byte-for-byte unchanged.
- [x] Report SHA-256 values and actual replay output to root. Do not edit runtime
  code, test helpers, generator or Contract; these belong to Task2/3.

## Task 2: Authenticate closed contracts and make generation reproducible

Files: new `lib/swarm_code/daemon/schema/contract.ex`; change
`migration_manifest.ex`, `priv/schema/generate_manifest.exs`; tests
`schema/migration_manifest_test.exs` and `schema/generate_manifest_test.exs`.

Produces `Contract.current/0`, `Contract.fetch(commit)` returning `{:ok,map}` or
`:error`, and `Contract.maximum_migrations/0`. Metadata maps contain `commit`,
`name`, `migration_count`, `migration_set_sha256`, `final_schema_sha256`,
`lineage_sha256`, `last_version`, `last_filename`, `last_source_sha256`, and
`snapshot_versions`. Values come from the independently verified Task1 artifacts.

- [x] Add a failing regression which changes entry20's schema hash to another
  canonical64hex value and requires `MigrationManifest.load!` to reject it.
  Preserve the source-set digest so it reproduces the actual authentication gap:

```elixir
assert_invalid(fn decoded ->
  update_in(decoded, ["migrations", Access.at(20), "schema_sha256"], fn _ ->
    String.duplicate("a", 64)
  end)
end)
```

- [x] Add tests for current default46entries, explicit legacy43entry validation,
  unknown contract ID, cross-contract metadata/entry mixing, harmless JSON
  reformatting, wrong intermediate current-prefix hash and oversized input.
- [x] Implement fixed Contract records. Authenticate deterministic lineage fields
  in addition to existing source-set/shape constraints. Read bounded bytes from
  the opened regular descriptor; cap before JSON decoding.
- [x] Refactor the existing generator to use `Contract.fetch/1` for the two exact
  --commit choices. Retain path confinement, staged atomic publication, clean
  upstream requirement, independent source-set checks and all historical hashes.
  Current generation emits every listed snapshot including the43prefix plus final
  current; legacy generation preserves its previous byte output and filenames.
- [x] Run existing source-path alias regression tests plus unknowncommit rejection.
  Use the Task1 clone to generate current and legacy outputs into separate ignored
  directories; compare every output byte with the corresponding tracked artifact.
- [x] Request scoped review of contract admission/generator changes and artifacts.

## Task 3: Carry current schema through foundation and verified backup

Files: `schema/probe.ex`, `backup/gate.ex`, `backup/manifest.ex`, `platform/directory_protocol.ex`,
`foundation_gate.ex`; `test/support/schema_fixture.ex`; relevant schema, foundation,
backup and directory-protocol tests; read-only documentation updates.

Consumes Contract.current/maximum and current artifacts. Produces the same existing
Ready and Backup.Artifact APIs for actual46migration data.

- [x] Point `SchemaFixture.database!(:current)` at current46SQL and admit explicit
 26/27/28/29prefix selectors. Add a current fixture through `FoundationGate.prepare`
  that asserts live lease, exact newest migration/source-set metadata and noRepo.
- [x] Add current-schema Gate tests and exact suffix tests from26/27/28 prefixes;
  preserve byte digests. Add47thunknownmigration and wrongcurrentcolumnshape tests
  requiring `:schema_incompatible` and unchanged database/sidecar bytes.
- [x] Replace migration count constants in Probe/Backup.Manifest/DirectoryProtocol
  with Contract.maximum_migrations; use a fixed parameterized47row sentinel query.
  Update FoundationGate's compile-time audited manifest source to current.
- [x] Exercise real Backup.Gate on current46migration data with representative
  providers.fallbacks, nodes cache counts and settings.bench_layout values.
  Require46records through broker response, backup manifest and independent
  restore; prove values, quick/FKchecks and exact source-byte preservation.
  Accept the actual `:ready` decision with empty pending and applied equal to
  probe versions; retain migration-required admission and all lease/source checks.
  An inconsistent ready relabel with pending migrations still rejects. Do not
  relabel the current-ready fixture to manufacture migration-required evidence.
- [x] Preserve oldbackuprestoration coverage and verify old43prefix now requests
  exactlythethreeappendedmigrations under currentcontract. Foundationstillbacksup
  thenreturns its existing migration-not-installed refusal; no migrationexecuted.
- [x] Update existing tests' current-schema expectations while retaining explicitly
  named legacy-contract tests; run focused schema,backup,foundationandbroker suites.
- [x] Review the integrated artifact/count/admission/backup handoff.

## Task 3a: Close the reproduced SHM read-path defect

The original strict tests exposed writes by readonly SQLite to canonical SHM.
The [locked snapshot design](../specs/2026-09-06-locked-snapshot-design.md)
records the implemented approach and evidence bounds.

- [x] Verify ordinary SQLite-compatible native lock/copy feasibility with actual
  pinned Exqlite; reject the eight-reader-lock prototype that caused SQLITE_PROTOCOL.
- [x] Build a bounded native copy helper with independently validated identities,
  exact private modes, DMS state discrimination and no source-byte writes.
- [x] Add asynchronous ExternalCommand ownership and SourceSnapshot receipts,
  native/worker terminal observation, registered SQLite cancellation and cleanup.
- [x] Replace Probe aliases and prefix cleanup with complete snapshots; preserve
  original bindings and resolve symlink/.. physically. All24 Gate tests pass.
- [x] Review helper, build portability, owner and Probe; fix the DMS transition,
  source parent mode and cross-platform stale-artifact findings.
- [x] Integrate backup with separately broker-owned complete copies. Keep original
  source fingerprint/reprobe checks and no shared inode with the snapshot owner.
  This extra full copy deliberately removes external reader/deadline coupling.
- [x] Verify backup/sourcebyte/restore and cancellation tests; review the handoff.

## Task 4: Verify and commit

- [x] Update README/foundation/audit with exact new source pin and schema coverage.
  Historical test evidence remains dated; no provider or normalstartup claim.
- [x] Run `mise exec -- mix precommit` and
  `MIX_ENV=prod mise exec -- mix compile --warnings-as-errors`.
- [ ] Verify regenerated artifact equality, unchanged desktop status and no owned
  helper/fixture processes; commit explicit files and continue the persistent
  daemon query/command spine under the original full-parity objective.

## Self-review

Source/schema evidence is Task1; closed contracts, bounded input and generator
reproducibility are Task2; all schema-limit consumers and actual backups are Task3;
whole-repository checks and truthful reporting are Task4. Task1 owns artifact
files, Task2 owns generator/contract/decoder, Task3 owns service integration, so
independent work can avoid shared-file edits. The only unknown values are computed
artifacts explicitly produced by Task1, not guessed implementation constants.
