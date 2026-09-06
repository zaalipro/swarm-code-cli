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
