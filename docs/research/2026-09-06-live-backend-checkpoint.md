# Live coding backend checkpoint

The full harness goal remains open. The real provider/tool/agent backend is now
implemented in this CLI checkout. The executable terminal demo still uses sample
data until service/persistence integration is complete.

## Implemented and exercised

- OpenAI-compatible and Anthropic HTTP streaming through Req 0.7.3, including tool
  calls, reasoning/continuation/cache usage, model listing, effort handling,
  retries, absolute deadlines, cancellation and bounded responses.
- Closed coding-tool registry: read_file, list_dir, grep, write_file, edit_file,
  run_command. Tests operate on actual temporary files and shell commands.
- Native POSIX command guardian: closed stdin for the shell, bounded head/tail
  output, four-packet flow control, deadline/cancellation, command-group cleanup,
  terminal acknowledgment and actual helper exit before a result.
- Supervised live Run: streamed model/tool loop, exact tool-result order,
  configurable step cap, bounded context, explicit write/execute approval,
  read-only policy, pause/continue/steer and cancellation. Usage is accumulated;
  persisted cost/budget enforcement remains future work.
- Bounded presentation delivery and snapshot recovery. Run's internal snapshot
  retains full accumulated text/reasoning under the provider response bound;
  the future wire service must page these fields into existing client bounds.

The integration test's actual HTTP provider requests read_file, edit_file and
run_command against a temporary repository, receives their real results and then
returns the final answer. It asserts changed file bytes and successful shell
verification. This is a fixture provider over real HTTP, not a paid external API
or proof that the TUI is connected.

## Defects found and fixed during adaptation

Provider tests/review exposed silently ignored malformed SSE, missing total
response bounds, deadlines resetting on chunks/fallbacks, credential leakage in
redirect logs and secrets split by error-body truncation. All have regressions.
Tool review exposed static symlink/.. confinement escape and a grep lookahead
prefilter mismatch. Command tests exposed unbounded consumer mailbox growth,
slow-consumer output loss and a terminal-control pipe race. Run tests exposed
paused approval execution, stale resumed status, truncated answer false success,
invalid-config owner crashes and loss of large partial/recovery text.

## Verification

`mise exec -- mix precommit`, seed 774991: **82 core + 376 daemon + 514 CLI = 972
tests**, **5 properties**, **12 native snapshot tests**, zero failures. Formatting,
warnings-as-errors compilation, dependency checks, provenance and both Unicode
checks pass. `MIX_ENV=prod mise exec -- mix compile --warnings-as-errors` passes.
Focused suites:53 provider, 77 tools, 14 live Run tests. Source/destination digests are
recorded for 31 adapted files, checked against the pinned read-only desktop Git
objects. No desktop implementation, user database or browser state was modified.

## Still required for the full harness

Durable run/session admission and recovery; guarded writable Repo and canonical
startup; local daemon service/IPC; real TUI DataSource and settings/bootstrap;
Git/worktrees/checkpoints; attachments, memory and MCP; all six execution modes,
subagents, workflows/research/scheduling; usage budgets; plain/headless production
commands; bundled releases and platform acceptance. No completion claim follows
from this backend checkpoint.

The command guardian owns ordinary POSIX process groups; deliberately escaped
sessions/groups are not a supported sandbox boundary. File tools preserve normal
physical-path confinement and atomic writes, not a hostile concurrent-rename
sandbox. Desktop checkpoint persistence is not yet wired to those atomic writes.
Linux/native release acceptance and paid live-provider smoke remain unverified.
