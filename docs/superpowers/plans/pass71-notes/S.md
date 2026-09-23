# pass71 owner S notes

Owner S: service and runtime. Branch `p71/S`, worktree `/Users/zaali/dev/swarm-code-cli-wt/p71-S`,
from main `6e8dad1`.

## Contracts (published early)

### S5 queue count (for V's "N queued" indicator)

- Field **`queued`**, a non-negative integer (`:count`), on both
  `DTO.WorkspaceSnapshot` and `DTO.WorkspaceMetadata` (the `workspace_metadata` delta).
- Meaning: prompts of this conversation waiting behind its live turn
  (`length(conversations.queued)` of the open conversation). `0` when nothing waits.
- Wire default `0`: an older daemon, or a map without the key, decodes as `0`.
- Updated by the service whenever the queue changes (a prompt queued, a queued prompt started or
  put back): a `workspace_metadata` delta carries the new count.
- Fake parity: `Fake.Session` has the same field; conversation `a` starts at `0` and a `send`
  while its run is live queues (count up, toast), like the service.
- Read it in the projector as
  `Map.get(workspace_snapshot_or_metadata, :queued, 0)` until the merge.

## Landed

| Task | Commits | What |
| --- | --- | --- |
| S1 P0 | 2514b16 | Deadlines: one monotonic clock in `DataSource.Daemon`. |

## S1: request deadlines

`Request.deadline` is, and stays, the owner's wall-clock millisecond (`state.now + deadline_ms`):
every producer (reducer, library, plain session, one-shot) stamps it that way and the reducer
stays pure. `DataSource.Daemon` converts it exactly once, at admission, into the wire's
`timeout_ms` budget and a monotonic deadline; every later comparison (requests, controls,
receipts, partial frames) is monotonic. Before, the source compared the wall-clock deadline with
`System.monotonic_time/1`, so no request ever expired and the wire's `timeout_ms` was always the
600 s cap. New option `clock: (:system | :monotonic -> ms)` for tests. Regression test
`daemon_test.exs` "a deadline fires on the monotonic clock and a late reply is ignored" (also: a
wall-clock step alone expires nothing). Tests that stamped deadlines with the monotonic clock now
use the wall clock like production.
