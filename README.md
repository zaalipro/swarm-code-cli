# SwarmCode CLI

This repository contains foundation infrastructure, runnable synthetic plain and
interactive terminal demos, and a passive cell preview gallery.
The plain session and renderer-neutral UI share scoped requests, questions, run controls,
process-local drafts, and bounded presentation data. Production provider execution, persistence,
a daemon launcher, and supported-platform renderer acceptance remain unfinished.

Run the fixed demo without starting a daemon or opening user data:

```sh
(cd apps/swarm_code_cli && MIX_QUIET=1 mise exec -- mix swarm_code.demo.plain --script complete)
```

It demonstrates conversation navigation, answering a question, failed-run Retry, agent Stop,
and detach. Output is append-only; the demo owns and cleans up its synthetic processes.

Build the guarded terminal candidate, then run the interactive demo in a terminal:

```sh
scripts/dev/check_terminal_port.sh
scripts/dev/run_terminal_demo.sh
```

The demo uses fixed synthetic conversations and the Carbon Navigator/Main/Composer
layout. Tab moves focus; Enter activates; Escape returns to content. Press `a`,
search for `Open question`, and press Enter to answer the pending question.
Question digits focus an option; Enter submits it. Outside the editor, `q`
detaches; an unsent draft shows Cancel/Confirm. Ctrl-Z remains editor undo.

Options are `--no-alt-screen`, `--ascii`, `--monochrome`,
`--ambiguous-width narrow|wide`, and `--reduced-motion`. `NO_COLOR` selects
monochrome. The launcher starts BEAM with `-noinput` so its user driver does not
compete with the native input owner. Non-TTY and `TERM=dumb` invocations reject
before terminal mode changes; use the plain demo in those environments.

The native writer has a separate restoration guard and supports resize and
external suspend/resume. Local macOS PTY checks cover cleanup after normal exit,
signals and writer failure. Full shell foreground-job control, native visual and
performance acceptance, and all four supported-target release gates remain open.
This demo does not connect to a daemon or load user data.

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
Its current schema contract describes all 46 migrations at desktop `fb1b4ff`;
the historical 43-migration contract remains available for validation. See the
[schema audit](docs/evidence/schema/desktop-fb1b4ff.json) for source and replay identities.

- [Approved CLI architecture](docs/superpowers/specs/2026-09-01-swarm-code-cli-design.md)
- [Foundation safety and macOS residual risk](docs/foundation-safety.md)
- [Current implementation and desktop parity audit](docs/research/2026-09-06-cli-parity-audit.md)
- [Renderer decision and verified source constraints](docs/decisions/tui-renderer.md)

Contributor checks: `mise exec -- mix precommit`. The Unicode terminal-width
source and generated tables can be checked offline with
`mise exec -- elixir scripts/dev/sync_unicode_width.exs --check` and
`python3 scripts/dev/sync_unicode_variants.py --check`. Both checks also run
as part of `precommit`. The native schema snapshot checks also run there, or
separately with `sh scripts/dev/check_schema_snapshot.sh`. Source builds require
a C11 compiler and Python 3 for these checks; the snapshot executable is bundled
under the daemon app’s `priv/native/` and never compiled at runtime.

The terminal Port candidate has a bounded Rust input parser, exact cell output,
credit-controlled wire protocol, restoration guard and Elixir terminal owner.
Run its separate checks with the pinned Rust toolchain, followed by the local
PTY suites (which create and clean up their own terminals and processes):

```sh
scripts/dev/check_terminal_port.sh
PYTHONDONTWRITEBYTECODE=1 python3 scripts/dev/test_terminal_port_pty.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/dev/test_terminal_demo_pty.py
```

The first command builds the debug executable, checks formatting, runs Rust tests,
and verifies the locked dependency license manifest. It keeps Cargo build/cache
output under `_build` and uses a repository-local
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
