# Lane Y notes (truthful effort, quit summary, sparkline), CLI 0.2.2

Branch `cli022/Y` from CLI main `4fd44d18`, worktree `~/dev/swarm-code-cli-wt/cli022-Y`. Not merged.

## For lane X: the effective-effort fields (F4 seam)

Both `DTO.WorkspaceSnapshot` and `DTO.WorkspaceMetadata` (so `ReadModel`'s workspace snapshot,
`state.read_model.snapshots[:workspace]`) gain four fields. `effort` / `swarm_effort` keep their
meaning: the conversation's own stored value, nil while it follows a default.

| Field | Type | Meaning |
| --- | --- | --- |
| `effort_effective` | string or nil | the level the next chat turn uses: the conversation's `effort`, else the session's `NCODE_EFFORT`, else Settings' `default_effort`, else `"medium"` |
| `effort_source` | `:conversation` \| `:env` \| `:default` or nil | where `effort_effective` came from |
| `swarm_effort_effective` | string or nil | the level the next worker (swarm run) uses: the conversation's `swarm_effort`, else Settings' `default_swarm_effort`, else `"medium"` |
| `swarm_effort_source` | `:conversation` \| `:default` or nil | where `swarm_effort_effective` came from (the env never feeds the worker slot) |

X: mark `current?` from `effort_effective` / `swarm_effort_effective` (fall back to `effort` /
`swarm_effort` when nil, e.g. an older daemon or the live launcher before it sends them). The
`default` row is "current" when `effort_source` is not `:conversation` (the stored value is nil).
After `/effort default` the status line shows `effort_effective` (the default level), with no
client work: Y's status line already reads the effective field.

Fake (`ui/data_source/fake/session.ex`): Y fills the four fields from the fake's own `effort` /
`swarm_effort` (source `:conversation` when set, else `"medium"` / `:default`).

(Details of the root cause and the rest of the lane follow below as they land.)
