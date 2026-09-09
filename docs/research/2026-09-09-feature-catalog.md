# Domain feature catalog

Implemented `SwarmCode.Domain.FeatureCatalog` in `apps/swarm_code_daemon/lib/swarm_code/domain/feature_catalog.ex` as the daemon's bounded feature service façade.

## Query API

`query(feature, %SwarmCode.Protocol.Scope{}, opts)` accepts `:workflows`, `:research`, `:schedules`, `:settings`, `:usage`, `:changes`, `:checkpoints`, and `:mcp`. Options are strict keyword lists: `:id`, `:cursor` (numeric offset), `:limit` (1..200), and `:byte_limit` (4096..1 MiB). It returns a page with `title`, `description`, `items`, and `next_cursor`; every item has string `id/title/subtitle/status/detail` and a closed action list.

Scopes resolve through the actual project, conversation, run/workflow, research, and schedule records. Project and conversation scopes filter all project-bound data; changes require a project scope, checkpoints require a conversation scope, and MCP rows are filtered to global/project-visible servers. Invalid IDs, scope kinds, options, cursor values, and repository roots return fixed error atoms.

## Command APIs

- Workflows: `list_workflows/1`, `workflow_detail/2`, `start_workflow/1`, `control_workflow/3`.
- Research: `list_research/1`, `research_detail/1`, `start_research/1`, `control_research/2` (`:stop`, `:retry`, `:report`, `:pin`).
- Schedules: `list_schedules/0`, `schedule_detail/1`, `save_schedule/1`, `delete_schedule/1`, `toggle_schedule/1`, `run_schedule_now/1`.
- Settings and usage: `settings/0`, `update_settings/1`, `usage/1`.
- Git/checkpoints: `git_status/1`, `git_diff/2`, `checkpoints/1`, `restore_checkpoint/2`, `restore_checkpoint_run/2`.

All commands delegate to `Domain.Workflows`, `Domain.Research`, `Domain.Scheduled`, `Domain.Settings`, `Domain.Conversations`, `Domain.Git`, `Domain.Checkpoints`, and `Domain.MCP`; no alternate Repo, in-memory persistence, or transient fake was introduced. Settings and MCP projections use explicit allowlists and never expose API keys, headers, environment maps, or pricing secrets. Inputs are bounded and recursively checked before context calls; output maps are explicitly projected and clipped.

## Verification

`mix test apps/swarm_code_daemon/test/swarm_code/domain/feature_catalog_test.exs` passed: 9 tests, 0 failures. The suite uses the existing domain fixture Repo/migrations and verifies settings validation/secrecy, schedule persistence, workflow project discovery and ID filtering, project-scoped Git status, checkpoint reads, cross-project pagination, and ownership-safe checkpoint restoration, narrow research/schedule scopes, and a real no-model workflow run that persists completion.

Known integration boundary: model-using workflow/research starts need their configured providers and supervised runtime; the catalog returns underlying context errors when those are unavailable and does not claim startup itself.

## Scope and protocol notes

`query/3` accepts both atom and wire feature names, and accepts the wire `page_size` alias for its bounded `limit`. Returned `detail` is always a clipped UTF-8 string (not a map), matching the CLI LibraryItem DTO; action atoms are limited to the protocol allowlist. Numeric cursors are bounded offsets. Feature command validation rejects arbitrary keys, malformed UUIDs, invalid provider IDs, out-of-range limits, invalid Git revisions/paths, and oversized or non-UTF8 values before calling a context.
