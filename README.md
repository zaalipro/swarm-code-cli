# SwarmCode CLI

This repository currently contains **pre-Repo foundation infrastructure**, not a usable CLI
release. The safety gate proves canonical-path, identity, private-directory, cross-application
lease, read-only schema, and verified-backup contracts before later plans add Repo supervision and
the terminal/runtime surfaces. Do not use this milestone as a normal startup path.

- [Approved CLI architecture](docs/superpowers/specs/2026-09-01-swarm-code-cli-design.md)
- [Foundation safety and macOS residual risk](docs/foundation-safety.md)

The 2026-09-01 source authorization, MIT license, and NOTICE terms are recorded in
[`SOURCE_AUTHORIZATION.md`](SOURCE_AUTHORIZATION.md), [`LICENSE`](LICENSE), and [`NOTICE`](NOTICE).
The current desktop does not honor the shared lease, so concurrent desktop/CLI operation is not
supported; follow the shutdown order in the safety note.
