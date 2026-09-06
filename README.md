# SwarmCode CLI

This repository contains foundation infrastructure and a runnable synthetic interaction demo.
The plain session and renderer-neutral UI share scoped requests, questions, run controls,
process-local drafts, and bounded presentation data. Production provider execution, persistence,
a daemon launcher, and a real terminal renderer remain unfinished.

Run the fixed demo without starting a daemon or opening user data:

```sh
(cd apps/swarm_code_cli && MIX_QUIET=1 mise exec -- mix swarm_code.demo.plain --script complete)
```

It demonstrates conversation navigation, answering a question, failed-run Retry, agent Stop,
and detach. Output is append-only; the demo owns and cleans up its synthetic processes.
The existing foundation gate covers canonical paths, identity, private directories, leases,
read-only schema admission, and verified backups. It is not a normal startup path.

- [Approved CLI architecture](docs/superpowers/specs/2026-09-01-swarm-code-cli-design.md)
- [Foundation safety and macOS residual risk](docs/foundation-safety.md)
- [Current implementation and desktop parity audit](docs/research/2026-09-06-cli-parity-audit.md)
- [Renderer decision and verified source constraints](docs/decisions/tui-renderer.md)

Contributor checks: `mise exec -- mix precommit`. The Unicode terminal-width
source and generated tables can be checked offline with
`mise exec -- elixir scripts/dev/sync_unicode_width.exs --check` and
`python3 scripts/dev/sync_unicode_variants.py --check`. Both checks also run
as part of `precommit`.

The 2026-09-01 source authorization, MIT license, and NOTICE terms are recorded in
[`SOURCE_AUTHORIZATION.md`](SOURCE_AUTHORIZATION.md), [`LICENSE`](LICENSE), and [`NOTICE`](NOTICE).
The current desktop does not honor the shared lease, so concurrent desktop/CLI operation is not
supported; follow the shutdown order in the safety note.
