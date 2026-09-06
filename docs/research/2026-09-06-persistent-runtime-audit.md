# Next persistent runtime audit

Read-only audit following schema checkpoint `0cc1e5a`. Desktop HEAD checked as
`fb1b4ff82354ac8ff2e82d4f6516121fd55ff212`. Only source was read; no Mix command,
application, Repo, browser, provider or user database was started. This is a scoped
recommendation, not an implementation plan or an authorization to bypass the
remaining canonical-open gate.

## Recommendation

The next useful runtime slice is **browse persisted conversation/run history and
mark an existing conversation seen**, through one daemon-owned query/command
service consumed by the existing plain and terminal clients. First establish the
safe daemon/Repo lifetime described below. Project creation, provider settings,
message dispatch and agent execution should follow; they introduce more contracts
and side effects than the client already supports.

A strictly read-only preview of a private fixture can prove query translation and
client integration independently. It cannot be called a persistent command slice
or a production canonical runtime. Never implement a temporary production Repo
path opener to make that preview writable.

## Existing boundaries and concrete files

| Boundary | Actual state / useful API |
|---|---|
| `apps/swarm_code_daemon/lib/swarm_code_daemon.ex` | Empty module. No daemon application supervisor, Repo launcher, transport listener or persistent context exists. |
| `apps/swarm_code_daemon/mix.exs` | Ecto/SQLite dependencies are pinned; `application/0` declares only extra applications, with no application callback. Dependency availability is not runtime admission. |
| `daemon/foundation_gate.ex` | `prepare/1` returns `%Ready{paths, identity, lease, schema, backup, binding}`. The lease is live and linked to the caller, but Ready is an ordinary struct; its Binding describes previously verified source identities. It is not a one-use live Repo-open capability. Absent DB and migration-required paths still refuse implementation. |
| `apps/swarm_code_cli/lib/swarm_code_cli/ui/data_source.ex` | Existing client-owned behavior: `start_link`, correlated `bind_owner`, `watch/unwatch`, `query`, `command`, `cancel`, `close`. This is the adapter seam to retain. |
| `ui/data_source/fake.ex`, `fake/source.ex` | Separate adapter/canonical-source processes already model attach/detach, watches, request deadlines, owner loss and resync. Real persistence belongs in daemon; the client adapter should retain transport/correlation responsibility. |
| `ui/data_source/request.ex` | Closed scoped requests: shell/workspace/transcript/activity/inspector/pending, cursor direction, 1–200 rows and 1–1,048,576 bytes; detail pages 4–65,536 bytes; generation/request/response correlation. |
| `ui/intent.ex` | Existing `{:mark_seen, :conversation | :run | :activity, id, revision}` is the smallest current durable command. No project/conversation CRUD intent exists. Unsupported provider/run controls must return typed refusal and have no advertised actions. |
| `ui/data_source/dto/*` | Existing ShellSnapshot, WorkspaceSnapshot, RunSummary, TranscriptWindow/Item, DetailWindow and Outcome cover the first slice. ShellSnapshot is a runs page, not a real project/conversation catalogue: empty conversations and the project tree need an explicit later DTO/query extension. |
| `ui/data_source/data_bridge.ex`, `ui/session_runtime.ex`, `demo/plain.ex`, `demo/terminal.ex` | Delivery validates source epoch; SessionRuntime and plain sessions already consume a DataSource handle. Demos currently wire Fake/Source. A daemon adapter can feed both surfaces without a renderer rewrite. |
| `apps/swarm_code_core/lib/swarm_code/protocol/*` | Bounded frames, message/envelope/scope/JSON validation exist. No implemented daemon connection/listener or closed persistent service operation registry was found. Daemon must not import client UI DTO/Intent modules; shared wire/domain contracts belong in core, client maps them to presentation DTOs. |

## Desktop behavior to preserve, not transplant

All paths below are beneath the read-only desktop `lib/swarm_code/`.

- `projects.ex`: `list/0` excludes scratch projects and sorts last-opened then
  name. `scratch/0` is a read; `scratch!/0` creates both directory and DB row.
  `delete/1` also stops engines. These are not harmless metadata wrappers.
- `conversations.ex`: `list_for_project/1`, `list_visible/0`, `list_recent/1`,
  `list_pinned/0`, `list_without_project/0` define navigation behavior;
  `list_runs/1`, `list_messages_window/3` and `list_history_window/2` are history
  references. Preserve user-visible transcript vs compacted model-history rules;
  do not substitute one for the other or load entire histories before slicing.
- `Conversations.mark_seen/1` changes `last_seen_at` with `update_all` and
  intentionally does **not** bump `updated_at` or reorder the sidebar. Missing
  IDs return not_found. `mark_run_seen/1` persists `runs.seen_at` and broadcasts
  via the run update path. Start with conversation seen; add run seen after the
  same event/revision contract is explicit.
- `conversations/message.ex` and `run.ex` reveal mapping gaps: desktop message
  roles include swarm/error/workflow/compact; UI TranscriptItem admits only
  user/assistant/system/tool and requires node/attempt IDs absent from message
  rows. Desktop run kind `compact` is absent from UI RunSummary; statuses include
  `waiting_user` rather than question/approval-specific UI states. Persona also
  depends on goal/workflow/consensus/mode metadata. Define and test explicit
  presentation mapping and honest unsupported variants, not invented execution
  facts or direct atom conversion.
- `settings.ex:get/0` inserts a settings row when absent. `providers.ex` combines
  persistence with cache/PubSub, default seeding and model fetching. Neither is a
  safe first read-only context to transplant. The new fallbacks/cache counts/
  bench_layout schema support does not authorize provider/network execution.

## Required safety predecessor

Current schema admission and coherent snapshots do not close the writable
canonical Repo capability gap. Before any production persistent command:

1. Establish one supervised daemon/foundation owner that outlives client detach,
   preserves desktop detection, private paths and lease exclusion, and tears down
   Repo before releasing its live lease. Do not make the renderer or request
   worker the canonical owner.
2. Close the exact lease/database-open and one-use Ready-to-Repo handoff described
   by the existing residual-hardening design: actual admitted object consumption,
   initial pool attestation, guarded reconnect, revoked/stale/forged Ready refusal
   and shutdown ownership. Reopening `ready.paths.database` with Ecto would be the
   precise bypass that remains prohibited.
3. Retain typed refusal for old-schema/new-DB paths until separately implemented;
   retain the macOS signed detector requirement and no safe concurrent-desktop
   claim. The desktop does not yet reciprocally implement the whole shared lease
   protocol. Snapshot safety is not writable pool safety.

The residual design (`2026-09-03-foundation-residual-hardening-design.md`) contains
more predecessor work than this schema refresh, including C1/C2 and supervisor/
capability/receipt requirements. Reconcile its remaining obligations explicitly;
do not claim its entire promotion checklist was closed by the new native copier.

## First vertical slice and evidence

After the safety predecessor, use an admitted current46 fixture populated with
projects, conversations, messages and settled runs. Expose bounded daemon history
queries, translate them into the existing client data boundary, show actual titles
and transcript pages in the plain session, issue revisioned conversation seen,
then reconnect and restart the daemon and prove that persisted seen state remains.
A second client should receive the correlated update; closing either client must
leave daemon ownership intact. Reuse the same adapter in SessionRuntime afterward.

Define daemon source epoch/revision and cursor semantics before connecting data:
the desktop schema has timestamps and positions, not the fake source's durable
integer sequence/revision/attempt model. Reconnect can require a fresh snapshot
under a new epoch; UUIDs or timestamp casts must not masquerade as event revisions.
The first command needs exact scope/revision validation, idempotent retry/outcome
semantics and a transaction boundary. Prove not_found/stale requests leave bytes
unchanged and mark_seen preserves conversation updated_at/order. Full parity
still requires empty conversations/projects, CRUD, live run ownership and provider
execution afterward.

## Work that can proceed independently now

- Inventory a minimal closed core wire service vocabulary and explicitly map the
  desktop fields/variants to existing UI facts, including nulls, compacted and
  superseded history, large bodies and stable bounded keyset pagination.
- Build pure serializers/query planners and fixture-only reader tests against
  current46 private data; preserve the query path's no-write behavior and keep
  big content in bounded detail pages.
- Exercise a client transport adapter against a private fixture service using
  current request/watch/deadline/epoch validation; keep daemon dependencies out of
  CLI and prove detach/reconnect independently of rendering.
- Write the contract-level seen behavior tests against an explicitly isolated
  test store. Do not install a production writable Repo startup path while the
  capability predecessor is incomplete.

These can overlap the predecessor. Their completion is evidence for a future
history/seen slice, not canonical startup, all desktop parity, or renderer adoption.


## Carry-forward correction to the residual plan

The September 3 residual plan is not executable verbatim. Its old worktree path
and desktop-spec edit allowance are superseded by the user’s instruction to work
only in this CLI checkout. Its probe prescription of private SHM over live
main/WAL has been disproved: it loses checkpoint/WAL-reset coordination. Keep
the complete locked SourceSnapshot path for read-only admission while proving the
separate guarded writable-open capability. The existing native copier is a
bundled executable; it does not introduce a second SQLite library into BEAM.

The next feasibility gate remains the one-library, exact-descriptor Exqlite open
proof. The pinned Unix VFS `unixOpen` initializes more than a file descriptor:
unused-descriptor bookkeeping, inode locking state, filesystem flags and close
behavior must be retained. Calling `fillInUnixFile` alone is not a complete
production adapter. Ordinary direct Exqlite and Ecto behavior, source identity,
resource release and target-native compilation must be demonstrated before a
production Ready/Repo route is introduced. No implementation of that successor
has begun in this checkpoint.
