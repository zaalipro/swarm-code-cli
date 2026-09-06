# SwarmCode CLI

This repository contains foundation infrastructure, a runnable synthetic interaction demo,
and a passive cell preview gallery.
The plain session and renderer-neutral UI share scoped requests, questions, run controls,
process-local drafts, and bounded presentation data. Production provider execution, persistence,
a daemon launcher, and a real terminal renderer remain unfinished.

Run the fixed demo without starting a daemon or opening user data:

```sh
(cd apps/swarm_code_cli && MIX_QUIET=1 mise exec -- mix swarm_code.demo.plain --script complete)
```

It demonstrates conversation navigation, answering a question, failed-run Retry, agent Stop,
and detach. Output is append-only; the demo owns and cleans up its synthetic processes.

Export the synthetic UI as a cell preview gallery:

```sh
(cd apps/swarm_code_cli && mise exec -- mix swarm_code.demo.cells)
```

Open `index.html` in the printed directory under `_build/cell-previews/`. The command
creates 17 SVGs covering chat, swarm, consensus, research, narrow dialogs, and the
minimum-size fallback. These passive previews show the cell layout and Carbon colors;
they do not run a terminal, daemon, or provider. Each export gets a fresh directory.

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

The terminal Port candidate currently has a pure Rust input parser and a draw-frame
decoder. It does not yet open a terminal. Run its separate tests with the pinned
Rust toolchain:

```sh
scripts/dev/check_terminal_port.sh
```

The check keeps Cargo build/cache output under `_build` and uses a repository-local
compiler if present, otherwise the pinned installed Rust toolchain. It installs nothing.
The parser bounds paste while reading, preserves packet boundaries and UTF-8, and
discards control strings. Legacy Alt punctuation from `!` through `/` and CSI-u
alternate-key/text extensions are currently unsupported. See the
[candidate design](docs/superpowers/specs/2026-09-06-guarded-terminal-port-design.md)
and [draw wire contract](docs/implementation/terminal-port-wire-v1.md).

The 2026-09-01 source authorization, MIT license, and NOTICE terms are recorded in
[`SOURCE_AUTHORIZATION.md`](SOURCE_AUTHORIZATION.md), [`LICENSE`](LICENSE), and [`NOTICE`](NOTICE).
The current desktop does not honor the shared lease, so concurrent desktop/CLI operation is not
supported; follow the shutdown order in the safety note.
