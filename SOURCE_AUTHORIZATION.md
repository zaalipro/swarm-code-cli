# Source authorization

**Authorization date:** 2026-09-01

The owner instructed that SwarmCode CLI be built and published as an
open-source project and authorized adaptation from the pinned SwarmCode
repository for that purpose.

The authorization covers SwarmCode source, tests, specifications, migrations,
and fixtures at upstream commit
`dbb8804b3d7293178e571fa7afdf6bd47d06a51c`. Each extracted file still requires
an entry in `provenance/extracted-files.json` that records its upstream path,
commit, classification, and SHA-256 digest.

- Copyright holder: ZaaliPro
- Chosen SPDX license: MIT
- Public source copying and modification: authorized
- Copyright terms: recorded
- License terms: recorded
- NOTICE terms: recorded


## Current runtime adaptation

On 2026-09-06 the owner explicitly requested filling the live CLI coding-harness
gaps after reviewing the desktop/runtime comparison. Local adaptation now also
uses the inspected desktop commit
`fb1b4ff82354ac8ff2e82d4f6516121fd55ff212` for providers, tools and runtime code.
The recorded copyright, MIT license and NOTICE terms remain in place. This work
does not publish or modify the desktop repository.

Version 2 of the extraction ledger records `upstream_sha256` for the source bytes
at the named commit and `sha256` for the adapted destination bytes. The verifier
retains version 1 legacy records and admits only the two explicitly pinned commits.
Upstream source digests are checked during extraction against the read-only Git
object; offline verification checks recorded fields and destination integrity.


## Addendum: desktop commit 6dd8d82e

**Authorization date:** 2026-09-28

The owner authorized publication, as part of this open-source project, of the
code derived from desktop commit
`6dd8d82ef29f9a6608b942259e1801846bb87ed9`, alongside the commits named above
(`dbb8804b3d7293178e571fa7afdf6bd47d06a51c` and
`fb1b4ff82354ac8ff2e82d4f6516121fd55ff212`). The provenance sync pins this
commit (`provenance/sync-rules.json`), and 247 of the 286 entries in
`provenance/extracted-files.json` record it as their upstream commit; the other
39 record `fb1b4ff82354ac8ff2e82d4f6516121fd55ff212`. Every entry is a version 2
record. The recorded copyright, MIT license and NOTICE terms remain in place.
The project is published as ncode from version 0.1.0; its internal names are
unchanged. This addendum does not publish or modify the desktop repository.

Three other 40-character hexadecimal strings that a scan of `provenance/` finds,
`d50d0cd8541d97e2033c1642b145db6309e13799`,
`a3e9e9dacc3abe4cbccd4e63e04fb70aa46feb52` and
`94712847e18af370dd0df74862cc9584fb30571c`, are not commits. Each is the first
40 characters of a 64-character SHA-256 file digest of the upstream
`chunks.ex`, `sse.ex` or `result.ex`, which the ledger records three times: as
the `upstream_sha256` of the file's two copies and as the `sha256` of the copy
that is unchanged.

The verifier (`apps/swarm_code_core/lib/swarm_code/governance/provenance.ex`)
admits version 1 records only at `dbb8804b3d7293178e571fa7afdf6bd47d06a51c` and
version 2 records at four adaptation pins: the three commits named above and
`ccb19732c7225a6bc88556f8f743bab7bda41a5b`. That list supersedes the sentence
above that the verifier admits "only the two explicitly pinned commits".
`ccb19732c7225a6bc88556f8f743bab7bda41a5b` is a desktop commit dated 2026-09-13
and an ancestor of `6dd8d82ef29f9a6608b942259e1801846bb87ed9`; no entry in
`provenance/extracted-files.json` cites it. It is used only for the schema
manifest `apps/swarm_code_daemon/priv/schema/desktop-ccb1973.json` and its
contract entry, and the 53 migration files that manifest records are
byte-identical at `6dd8d82ef29f9a6608b942259e1801846bb87ed9`, so the manifest
describes code this addendum covers.
