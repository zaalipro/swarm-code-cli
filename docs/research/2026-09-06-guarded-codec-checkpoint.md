# Guarded SQLite fork and service codec checkpoint

The CLI dependency now selects `vendor/exqlite` version `0.39.0-swarm.1`, built
from pinned source. This checkpoint establishes the development/test-only
read-only exact-descriptor fixture API and preserves ordinary Ecto behavior.
It does not authorize opening the canonical user database. Writable journal,
WAL/SHM, shared-inode locking, guarded Repo connections, one-use Ready consumption,
migrations and production supervision remain required.

The core `ServiceRequest` codec validates twelve closed request operations,
scopes, identities, exact keys and bounds. It revalidates encoded structs and
rejects unsupported actions. Transport, membership checks, persistence and the
real TUI adapter are still to be implemented.

Verified in this checkout on macOS:

- `mise exec -- mix precommit`, seed `126450`, exited zero: 92 core tests,
  378 daemon tests, 514 CLI tests (984 total), five properties, and twelve native
  snapshot checks. Formatting, compilation, dependency, provenance and Unicode
  checks passed. Log: `_build/live-coding-harness-verify/precommit-guarded-service-codec.log`.
- `MIX_ENV=prod mise exec -- mix compile --warnings-as-errors` exited zero.
  Log: `_build/live-coding-harness-verify/guarded-codec-final-prod.log`.
- Earlier focused integration established ordinary schema/lease/snapshot behavior
  (54 tests), fork integration (two tests), production refusal and rejection of
  `EXQLITE_USE_SYSTEM=1`. The isolated vendor lifecycle/compatibility/refusal suite
  passed eight tests; see the fork's `SWARM_PATCHES.md` for exact scope.

The production build contains no native fixture API. The executable TUI still
uses synthetic data. No external paid provider call or supported-platform
release acceptance is claimed by these component results.
