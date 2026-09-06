# Runtime ownership, acknowledged events and live presentation checkpoint

The live backend now has daemon-owned provider capability state and a bounded
supervisor for temporary run children. A run survives its submitting process;
failed children are not automatically restarted and cannot implicitly replay
tools. Starting the daemon application alone opens no Repo or service listener.

Run's optional canonical sink is independent of its bounded presentation stream.
One monitored asynchronous append is pending at a time. Model/tool admissions,
full results, approval arguments/decisions, steering and terminal boundaries must
be acknowledged before dependent effects or successful completion are published.
Stop cancels owned work while an append is held; pause gates unstarted effects.
Failures fence the run with fixed diagnostics. Queued controls are revalidated
when they execute and cannot reopen a terminal run. Actual agent/operation IDs
preserve causal ownership across model turns and repeated provider call IDs.

The internal writer PID supports the future store's producer check. It is not a
wire DTO or persisted field. The real transactional sink still must enforce
writer claims, exact duplicate semantics, durable request identities, atomic
domain/event commits, and recovery after a lost acknowledgement. The private test
sink only exercises append ordering/backpressure; it is not production storage.

The client now supports actual tool approval details, a separate reasoning detail
reference, immutable payloads up to 16 MiB through bounded pages, and indeterminate
run progress. Approval arguments support PgUp/PgDn/Home/End without selecting an
approving action. Plain detail links are derived from retained content so a full
page cannot evict links it still advertises. Control-heavy argument previews keep
their sanitized contents through wrapping and paging.

Verified in this checkout on macOS:

- Full `mise exec -- mix precommit`, seed `259396`, exited zero: **92 core + 402
  daemon + 522 CLI = 1,016 tests**, five properties and twelve native snapshot
  checks. Formatting, compilation, dependencies, provenance and Unicode passed.
  Log: `_build/live-coding-harness-verify/precommit-canonical-sink-presentation.log`.
- Focused runtime verification with `--warnings-as-errors`: 38 tests passed,
  seed `694168` (22 sink, 14 original Run and two application tests). Meaningful
  cases include real HTTP/file/command execution, held/rejected commits, native
  cancellation, repeated call IDs, full UTF-8 tool output, signed Anthropic
  continuation/refusal, steering, timeout and post-terminal controls.
- `MIX_ENV=prod mise exec -- mix compile --warnings-as-errors` exited zero.
  An actual production boot probe confirmed provider/run supervisors exist,
  Repo is absent, and the fixture guard returns `native_guard_unavailable`.
- `PYTHONDONTWRITEBYTECODE=1 python3 scripts/dev/test_terminal_demo_pty.py`
  passed all eight checks, including terminal restoration and input lifecycle.
  This exercises the existing synthetic launcher, not a live daemon connection.
- Client regression tests include near-65.5 KB inline and escape-expanded
  arguments at 50×16 and 150×40, correct full-argument focus/activation, all 400
  text/reasoning references on a 200-item page, scoped lookups and unknown progress.

Independent scoped reviews closed the run concurrency/diagnostic and client
readability/focus/reference findings. Native performance and other supported
targets remain unverified. No remote paid API call, canonical user database
access, real production TUI launch, or complete harness release is claimed.

Remaining critical path: production guarded directory/lease/database ownership,
writable journal/WAL/SHM and guarded pools; certified additive persistence
migration and transactional store; local service and real DataSource adapter;
provider/project/session setup and reconnect; advanced desktop capabilities and
packaged supported-platform acceptance. The full harness goal remains open.
