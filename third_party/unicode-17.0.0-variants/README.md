# Unicode variation sequences

These unmodified Unicode data files supply attested base/selector pairs for
terminal SafeText. Standardized and emoji variants use Unicode 17.0.0; the
Ideographic Variation Database uses its 2025-07-14 registration snapshot.
`UPSTREAM.json` records exact source URLs, byte counts and SHA-256 hashes,
including the Unicode License V3 copied alongside the data.

Run `python3 scripts/dev/sync_unicode_variants.py` to generate the immutable
SafeText lookup; run the same command with `--check` to verify every source
hash and exact generated output offline. No network or OS probing occurs in
the CLI. The generated table contains sorted, fixed-width base/selector pairs;
binary search avoids per-call maps or any runtime Unicode-data dependency.

Pair validation does not select fonts or guarantee that the terminal has a
glyph for an attested variant. Invalid or unregistered pairs remain visible.
