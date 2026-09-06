# TUI renderer decision

Status: **REJECTED — exact ExRatatui 0.13.0**. Verified 2026-09-06.

The CLI keeps its renderer-neutral Scene, reducer, input, theme, data-source and
session boundaries. Its stable synthetic plain demo remains available:

```sh
(cd apps/swarm_code_cli && MIX_QUIET=1 mise exec -- mix swarm_code.demo.plain --script complete)
```

A separately implemented guarded Port candidate now runs the synthetic workspace
through `scripts/dev/run_terminal_demo.sh`. Local macOS PTY checks and captured
ANSI replay establish limited implementation evidence; the full native campaign
and supported-target artifacts remain open. `Renderer.Decision` still cannot
adopt a candidate from arbitrary passing summaries.

A production renderer decision remains pending. The September 1 stack recommendation
was conditional and is superseded by this decision and the September 3
interaction contract. Rejecting this version does not adopt another renderer.

## Verified source identities

The [bounded evidence record](../evidence/tui-renderer/static-exratatui-013.json)
records four independent vetoes. The source inspection used downloaded package
bytes and ELF metadata; no native package was installed, compiled or loaded.

| Input | Verified identity |
|---|---|
| [Hex tarball](https://repo.hex.pm/tarballs/ex_ratatui-0.13.0.tar), outer SHA-256 | `0448833a5de5aed13fb480f57278deefe1ca3ff62af0d32e64515f4af674c030` |
| Hex inner SHA-256, recomputed from VERSION + metadata.config + contents.tar.gz | `5b9a488a8b895b06cef782ba47effd3a7e03a675d0f44d70277349ad70326671` |
| Annotated v0.13.0 tag object | `e47964edac37e776ee8c43bd53241083b0aa8813` |
| Tag source commit | `aa68bfc36016d90d6b1317f1f5edc8c4a6f9d045` |
| Crossterm 0.29.0 crate SHA-256 | `d8b9f2e4c67f833b660cdb0a3523065869fb35570177239812ed4c905aeff87b` |
| Crossterm crate .cargo_vcs_info.json commit | `36d95b26a26e64b0f8c12edfe11f410a6d56a812` |
| ratatui-core 0.1.2 crate SHA-256 | `cbb175c433c8e28a809d1f5773a2ae96e68c0ce40db865cbab1020bf33ae479c` |
| ratatui-core crate .cargo_vcs_info.json commit | `e665c36cb14752a61cd777fbd06dbef8474f2add` |

The Hex Cargo.lock pins Ratatui 0.30.2, ratatui-core 0.1.2 and Crossterm 0.29.0.
The package's terminal.rs, events.rs and native.ex bytes match their immutable
tag-commit counterparts. Package archives are inspection inputs, not repository
or release payloads; the package's unrelated erl_crash.dump was not extracted.

## Rejection reasons

| Code | Source evidence | Consequence |
|---|---|---|
| `unbounded_native_paste` | Crossterm's [Unix parser](https://github.com/crossterm-rs/crossterm/blob/36d95b26a26e64b0f8c12edfe11f410a6d56a812/src/event/source/unix/mio.rs#L198-L217) retains bytes until parsing succeeds. [Paste parsing](https://github.com/crossterm-rs/crossterm/blob/36d95b26a26e64b0f8c12edfe11f410a6d56a812/src/event/sys/unix/parse.rs#L813-L822) waits for the terminator then creates a String. ExRatatui [forwards Paste(String)](https://github.com/mcass19/ex_ratatui/blob/aa68bfc36016d90d6b1317f1f5edc8c4a6f9d045/native/ex_ratatui/src/events.rs#L21-L42). | A BEAM-side paste limit acts after native allocation. |
| `narrow_only_width` | The ordinary [cell-width path](https://github.com/ratatui/ratatui/blob/e665c36cb14752a61cd777fbd06dbef8474f2add/ratatui-core/src/buffer/cell_width.rs#L24-L43) uses UnicodeWidthStr::width. Exact ExRatatui exposes no selected-ambiguous-width or declared-width paint API. | Its text/Paragraph integration cannot honor the Scene's wide policy. |
| `no_public_no_alt` | [init_terminal](https://github.com/mcass19/ex_ratatui/blob/aa68bfc36016d90d6b1317f1f5edc8c4a6f9d045/native/ex_ratatui/src/terminal.rs#L88-L97) takes only focus and mouse flags, enables raw mode and enters the alternate screen. | Entering and immediately leaving is not a supported no-alt initialization path. |
| `arm64_jammy_abi` | Both published aarch64 GNU NIF variants import `pidfd_spawnp` and `pidfd_getpid` with version `GLIBC_2.39`; [Jammy's glibc source](https://launchpad.net/ubuntu/jammy/+source/glibc) is 2.35. | The published libraries exceed the Ubuntu 22.04 ABI floor. |

Ratatui itself has `CellDiffOption::ForcedWidth` at its low-level cell layer.
The width veto concerns the API exposed by this exact ExRatatui integration;
it is not evidence against a future project-owned declared-width paint path.

The arm64 checks decoded ELF64 section headers, `.dynsym`, `.gnu.version` and
`.gnu.version_r`. Both libraries report machine 183 (AArch64); the two named
symbols are undefined imports, rather than incidental strings in the binary.

| Published archive under [v0.13.0](https://github.com/mcass19/ex_ratatui/releases/tag/v0.13.0) | Archive SHA-256 | Extracted ELF SHA-256 |
|---|---|---|
| libex_ratatui-v0.13.0-nif-2.16-aarch64-unknown-linux-gnu.so.tar.gz | `0b79bb4c337c929dc2c7ad21ee61a35882450375a18096771b2c9e49c49fd65a` | `12e78853c3c08cdd561f3a86dcc57637b60e5576362d24293486167c964552fc` |
| libex_ratatui-v0.13.0-nif-2.17-aarch64-unknown-linux-gnu.so.tar.gz | `1eb8f5b52d774c71590451ada25fef6423ff2e0419e09736676ca97df05d5f0c` | `0a20e0b8a3e4f5572223ffc5929d20f145957ca386b6ee2029e97b560886eda0` |

## Decision behavior and remaining work

`Renderer.Decision.evaluate/2` validates closed, bounded evidence records and
returns rejection before checking missing target observations. Its result projected to `{status, candidate, reason_codes}` for the committed
record is:

```elixir
{:reject, :ex_ratatui_013,
 [:unbounded_native_paste, :narrow_only_width, :no_public_no_alt, :arm64_jammy_abi]}
```

DTO validation does not independently verify source claims.
Candidate-specific target failures reject their candidate; arbitrary pass
summaries cannot adopt one. No complete candidate campaign verification format
exists yet, so adoption is deliberately unavailable on this branch.

The current candidate is a guarded Ratatui/Crossterm Port with a bounded streaming
input parser and declared-width PaintPlan. It has exact-cell output, bounded
credits, a separate restoration guard, and a synthetic interactive demo; see its
[design](../superpowers/specs/2026-09-06-guarded-terminal-port-design.md).
The fallback candidate is a project-owned pure-Elixir
exact-cell renderer/input implementation. Each needs its own plan, bounded
queues, one terminal owner, restoration guard, width proof and four-target
evidence. Stock TermUI is prior art. Plain.Session is a presentation fallback,
not a full-screen renderer candidate.

Tasks 0–1 and 16–27 of the old interaction plan were not executed: their native
bootstrap, adapter, PTY/soak campaign, release, signing and publishing work cannot
remove these static vetoes. The future acceptance matrix of 87 exact cell/style/
cursor/focus/action frames remains in the interaction spec; the complete matrix
is not claimed as rendered evidence. The retained neutral Tasks 2–15 have implemented components
and a running demo, with [documented interaction gaps](../implementation/task13-keyboard-surfaces.md).
This is not full desktop parity, real daemon execution, durable UI state, or an
installable production client.

The design recorded the rejection on September 3, but the machine-readable
record was missing while the neutral slice was built. This change repairs that
omission with fresh source verification; it does not backdate observations.

Read-only GitHub checks on 2026-09-06 found zero repository releases, zero
workflows and zero workflow runs; the local evidence-tag list was empty.
Those observations are dated facts. They are not a permanent assertion about
future remote state. No remote mutation was performed.
