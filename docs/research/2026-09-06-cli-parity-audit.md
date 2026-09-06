# CLI implementation and desktop parity audit

Audit date: 2026-09-06. CLI baseline: `2d2d5fc` on `feature/cli-working`.
Desktop reference: `c54f4fb802b32dfe1164012a98b0c5503928c31e` in
`/Users/zaali/dev/swarm-code`, inspected read-only. The desktop's untracked
`.specs/` directory was already present; its proposals are not proof of shipped
behavior. No desktop application, database, settings, or source was changed.

## Assessment

This repository is a foundation implementation, not a usable CLI. All three
application entry modules are empty. There is no command launcher, application
supervisor, running daemon, query/command service, provider execution, reducer,
projector, terminal adapter, or plain session. The number of contract modules
and passing unit tests must not be described as desktop feature coverage.

The foundations have useful safeguards: bounded protocol framing/JSON,
canonical path and identity checks, exclusive lease ownership, read-only schema
admission, independently restorable backups, closed UI intent/request types,
request/revision correlation, and renderer-neutral Scenes. The client already
has compile/test guards against importing daemon/database implementations.

The September 1 [feature inventory](2026-09-01/feature-inventory.md) remains the
detailed parity checklist, not a completion report. This audit rechecks its
main surfaces against the current desktop and the files actually present here.

## Feature coverage

| Desktop capability and authoritative source | CLI state | Required implementation/evidence |
|---|---|---|
| Startup, persistence and recovery: `application.ex`, `bootstrap.ex`, contexts | Pre-Repo checks only; `SwarmCodeDaemon` is empty | Owned supervision, compatible Repo startup, recovery, commands, daemon connection/reconnection tests |
| Chats/projects/sidebar: `router.ex`, `components/frame.ex`, `Projects`, `Conversations` | UI destination/request contracts only | CRUD/search/pins/projectless sessions, metadata queries and stable paging, actual persistence tests |
| Transcript/run cards: `components/chat.ex`, workspace template | Scene block definitions only | Ordered launches/messages/runs, bounded streaming, scroll anchors, fold/read state, fork/edit-resend/compact behavior |
| Build, Plan, Goal, Ultra, Workflow, Consensus: `Chat.modes/0`, `composer_mode/5` | Pure editor and draft stores; no composer/runtime | One selected mode, independent approvals/model/effort, mode-aware launch and plan approval paths |
| Agent/operation trees, Thread/Timeline/Changes: `swarm_pane.ex`, `side_chat.ex` | Scene block definitions only | Inspector views, nested ownership, Reply/Steer, scoped Stop/Retry/Resume and real event delivery |
| Needs-you questions and approvals: `Chat` interview/approval components | Closed intent/request definitions | Revisioned prompt state, visible activity inbox, answer/deny/approve handling and stale-action rejection |
| Workflows/library/journal/resume: `workflows_live.ex`, `SwarmCode.Workflows` | Absent | Isolated workflow execution and journal, library editor/check/launch, lifecycle and resume tests |
| Research/HTML reports/sources: `research_live.ex`, `Research.Levels` | A research Scene block only | Background jobs, four depths, report/source viewing and export, cancellation/ownership tests |
| Scheduling: `scheduled_live.ex`, scheduler runtime | Absent | Durable schedules/claims, timezones, agenda, manual launch, recovery and no-double-fire tests |
| Usage and settings: `history_live.ex`, `SettingsLive.sections/0` | Absent | Usage/budgets; all eleven settings sections, secret-store adapters, model/effort and provider/MCP diagnostics |
| Git/files/attachments/memory/commands | Absent | Confined service operations, diff/editor, recoverable mutations, metadata attachments and terminal command equivalents |
| Terminal navigation and desktop appearance | Contracts, safe text, Unicode width, Carbon styles, pure editor and pane geometry | Scene projection, keymap/focus, real renderer, terminal resize/restoration and visual evidence |
| Plain/headless and installable artifacts | Absent | Permanent bounded line/NDJSON commands, exit codes, bundled runtime, offline and supported-target smoke tests |

The current desktop router still exposes Chats, Scheduled, Workflows, Research,
Usage and Settings. The composer still exposes six modes; Swarm, Compact and
Deep Research must not become extra mutually exclusive modes. Research depths
remain Fastest 1x4, Medium 2x3, High 3x4 and Ultra 4x10. The settings sections
remain General, Deep research, Appearance, Providers & models, Pricing, MCP
servers, Memory, Storage, Commands, Limits and Budget.

The desktop now includes Ember, Fjord, Dusk and Paper themes in addition to
Carbon, Obsidian, Graphite and Aurora. Initial TUI Carbon support is a visual
milestone; it does not establish all-theme parity. Current desktop UI fixes
also preserve narrow pane titles, unify mode badges with command selection,
and defer storage measurement until its section is viewed. Carry these
outcomes into terminal behavior when the affected surfaces are implemented.

## Verified defects and integration gaps addressed

1. The working branch omitted existing commits `2276e2e` and `59d8565` from
   the TUI branch: stronger dependency/path guards and the attested Unicode
   17 width port. They were integrated into this checkout without editing
   other worktrees. The vendored-source attestation check passes.
2. `Width.take_cells/3` built and remeasured every growing prefix of the
   entire source, even for an eight-cell viewport. A 10,000-character tail
   took over 530 million reductions in the failing regression. The scanner
   now stops at the visible boundary. It still measures contextual prefixes
   so ligatures and emoji retain the upstream width semantics.
3. `Width.wrap/3` treated newlines as ordinary width-bearing content, losing
   paragraph/blank-line structure. It now handles LF and CRLF hard breaks,
   including empty and trailing lines. CRLF coverage was added after review.
4. Middle elision reversed and re-segmented text, which can regroup regional
   indicators and truncate flag suffixes incorrectly. It now selects suffixes
   from the original grapheme sequence and measures them in display order.
5. The lease-owner lifecycle test raced monitor registration against the
   linked caller's shutdown. The failure reproduced independently with seed
   900566. A same-sender GenServer call after monitor creation establishes
   delivery before shutdown; the original required shutdown reason is still
   asserted, and a successor still has to acquire the released lease.

## Implemented presentation and editing components

External terminal text now has bounded sanitization with named controls/bidi
markers, invalid-byte replacement, exact Unicode variation eligibility and
tab stops under the chosen width policy. Structs are revalidated when read;
successful sanitization must yield a stable safe value. The new Unicode data
and generator have offline checksum verification and license notices. Tests
include arbitrary bytes, split streams, pathological combining sequences,
emoji joins that contain escaped characters, registered IVS and forged values.

Pure capability selection checks input/output/controlling TTY separately,
handles plain/dumb/no-color modes and carries one ambiguous-width policy.
The Carbon theme provides exact truecolor/256/16/monochrome values, fixed state
words, seven run prefixes, five numbered lanes and structural focus/disabled
cues. These style values are renderer-neutral; they are not rendered evidence.

Responsive geometry now implements the seven terminal size classes, the
desktop's Navigator/Main/Inspector hierarchy on wide screens and one dock on
medium screens. Effective widths preserve at least 50 Main columns and never
overwrite requested preferences. Small layouts reduce composer/activity rows;
compressed and degenerate layouts expose no composer geometry or mutation
size permission. Rectangle tests cover all width/height boundary combinations
and both medium dock choices. Scene content, focus and keyboard routing still
need the projector/reducer; geometry alone is not a working TUI.

The pure editor supports committed fragments, paste, grapheme selections,
word/line/buffer/vertical motion, bounded inverse undo/redo and a source-bounded
viewport. Tests cover local resegmentation, regional-indicator pairing,
contextual ligatures, max-size edits and stale timer IDs. Vertical movement
accounts for temporarily wider partial ligatures. Reset keeps timer identity
so a late boundary cannot affect a fresh draft.

Draft stores retain exact editor and target/attachment/validation metadata per
conversation/thread/edit key. A successful response clears only its submitted
payload and exact request; later edits/newer submissions survive. Search,
filter and question fields have independent 16 KiB editors. Stores default to
32 entries (configurable through 128) and refuse capacity exhaustion without
evicting unsent work. These drafts remain process-local until durable runtime
integration provides persistence; no crash-survival claim is made.

## Architecture priorities

Keep domain ownership in the daemon, with the TUI and plain surface consuming
the same commands, queries and event streams. Terminal disconnect must not
terminate scheduled or background work. Do not transplant Phoenix assigns,
LiveView processes or HTML hooks into the CLI's runtime.

Complete the runnable fake interaction slice before binding the client to
user data. It needs bounded external text, capability detection, a grapheme
editor, DTOs/source, reducer, layout/projector, keymap and the plain session.
The existing native renderer rejection is still a constraint; adding a
native dependency does not prove terminal safety or supported-platform parity.

Keep visible work proportional to the viewport. Paginate histories, source
catalogs and operation lists; separate metadata from bodies; apply every
semantic event in order and coalesce only redraws. The width regression shows
why a bounds check on the final output alone is insufficient.

Use the desktop's information hierarchy: project/conversation navigation,
unboxed assistant prose, one boundary per prompt/run, a separate inspector,
a persistent Needs-you signal, and the composer below the transcript. Match
Carbon's near-black surfaces and orange focus/live accent. Preserve state
words, mode names, kind prefixes and numbered lanes in monochrome. At narrow
widths substitute drawers/tabs for simultaneous desktop columns.

The macOS foundation still intentionally refuses production startup without
the signed desktop detector. New-database creation, migration execution,
credential storage, real IPC, provider/tool ownership and release packaging
remain required. Nothing in the text/width/theme work satisfies those gates.

## Validation and continuing work

The original full suite ran 79 core, 195 daemon and 39 CLI tests; its only
failure was the reproduced lease-monitor race. Width changes have 14 passing
focused tests, including new failing-before-fix regressions. The lease suite
has 16 passing tests. Source attestation passes via
`mise exec -- elixir scripts/dev/sync_unicode_width.exs --check`.

Continue against the original full-parity objective. Completion requires real
runtime tests, supported-platform artifacts, a rendered terminal compared with
the desktop hierarchy, and coverage of each row above. A fake demo, theme
table or clean unit suite is progress, not proof that the CLI is complete.
