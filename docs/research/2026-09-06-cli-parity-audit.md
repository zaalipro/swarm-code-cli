# CLI implementation and desktop parity audit

Audit date: 2026-09-06. CLI baseline: `2d2d5fc` on `feature/cli-working`.
Desktop reference: `c54f4fb802b32dfe1164012a98b0c5503928c31e` in
`/Users/zaali/dev/swarm-code`, inspected read-only. The desktop's untracked
`.specs/` directory was already present; its proposals are not proof of shipped
behavior. No desktop application, database, settings, or source was changed.

## Assessment

The repository now has a runnable synthetic plain demo, a pure reducer/projector,
keyboard routing, a cell painter and passive preview gallery, a renderer-neutral
session runtime, and a locally runnable guarded terminal demo. It is still not a CLI
for real user work: the application entry modules are empty, with no production
launcher, running daemon, provider execution, persistent query/command service,
or supported-platform renderer acceptance. Passing synthetic interaction tests do not establish
desktop feature coverage.

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
| Chats/projects/sidebar: `router.ex`, `components/frame.ex`, `Projects`, `Conversations` | Scoped synthetic pages, Navigator and plain navigation | CRUD/search/pins/projectless sessions, real metadata queries and persistence tests |
| Transcript/run cards: `components/chat.ex`, workspace template | Projected run cards, bounded stream windows and logical scroll anchors | Real launches/messages/runs, bounded streaming, scroll anchors, fold/read state, fork/edit-resend/compact behavior |
| Build, Plan, Goal, Ultra, Workflow, Consensus: `Chat.modes/0`, `composer_mode/5` | Synthetic composer/editor and process-local drafts; no mode-aware runtime | One selected mode, independent approvals/model/effort, mode-aware launch and plan approval paths |
| Agent/operation trees, Thread/Timeline/Changes: `swarm_pane.ex`, `side_chat.ex` | Projected synthetic Inspector, distinct run/agent controls and plain tabs | Inspector views, nested ownership, Reply/Steer, scoped Stop/Retry/Resume and real event delivery |
| Needs-you questions and approvals: `Chat` interview/approval components | Typed synthetic interactions, Activity, safe question/approval modals, keyboard/plain resolution | Real interaction service, visible activity inbox, modal/projector integration |
| Workflows/library/journal/resume: `workflows_live.ex`, `SwarmCode.Workflows` | Absent | Isolated workflow execution and journal, library editor/check/launch, lifecycle and resume tests |
| Research/HTML reports/sources: `research_live.ex`, `Research.Levels` | A research Scene block only | Background jobs, four depths, report/source viewing and export, cancellation/ownership tests |
| Scheduling: `scheduled_live.ex`, scheduler runtime | Absent | Durable schedules/claims, timezones, agenda, manual launch, recovery and no-double-fire tests |
| Usage and settings: `history_live.ex`, `SettingsLive.sections/0` | Absent | Usage/budgets; all eleven settings sections, secret-store adapters, model/effort and provider/MCP diagnostics |
| Git/files/attachments/memory/commands | Absent | Confined service operations, diff/editor, recoverable mutations, metadata attachments and terminal command equivalents |
| Terminal navigation and desktop appearance | Carbon Scenes, responsive panes, reducer/keymap and guarded interactive terminal demo; local input/resize/restoration PTY checks | Full native visual/input/lifecycle/performance campaign and supported-target artifacts |
| Plain/headless and installable artifacts | Bounded plain line session and executable synthetic Mix demo | Real service adapter, production commands/exit codes, bundled runtime, offline and supported-target smoke tests |

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
6. A later full-suite run exposed a real fast-command race: a short-lived
   child could close its Port before PID lookup, so successful output was
   reported as `command_start_failed`. A deterministic regression reproduces
   this with real Port events. ExternalCommand now retains the Port with EOF
   mode, closes after both EOF and exit status, and awaits monitored DOWN.
   Once exit is known, delayed EOF cannot trigger TERM/KILL against a stale PID.
   Both event orders and pending-reaper completion are covered by focused tests.

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
cues. The Projector now uses these renderer-neutral styles in valid Scenes;
the guarded demo now renders them locally; native visual acceptance remains open.

Responsive geometry now implements the seven terminal size classes, the
desktop's Navigator/Main/Inspector hierarchy on wide screens and one dock on
medium screens. Effective widths preserve at least 50 Main columns and never
overwrite requested preferences. Small layouts reduce composer/activity rows;
compressed and degenerate layouts expose no composer geometry or mutation
size permission. Rectangle tests cover all width/height boundary combinations
and both medium dock choices. Reducer, Projector and Keymap now connect scene
content, focus and keyboard routing; the guarded adapter binds these to real input/output.

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

The separately owned fake Source now supplies typed, scoped, paginated data
for three scripted runs. Client detach does not destroy its canonical facts.
It supports revisioned questions/approvals, run controls, failed-run Retry and
distinct agent Stop. Its validators reject malformed field sets and mismatched
scope metadata. Scripted progress derives current revisions; stopping a run
settles its interactions; paused/stopped branches remain unchanged while other
branches progress. Oversized text updates reject the entire transition without
losing source content or publishing a partial sequence. Fixed fixtures cover
status/Activity catalogues, keyset windows and a deliberate sequence gap.
This is synthetic data for interaction development, not user-data execution.

## Architecture priorities

Keep domain ownership in the daemon, with the TUI and plain surface consuming
the same commands, queries and event streams. Terminal disconnect must not
terminate scheduled or background work. Do not transplant Phoenix assigns,
LiveView processes or HTML hooks into the CLI's runtime.

The runnable fake interaction slice connects bounded text, capability selection,
editor, DTOs/source, reducer, layout/projector, keymap and plain session. Complete
its documented interaction gaps before binding user data. The existing native
renderer rejection is still a constraint; adding a native dependency does not
prove terminal safety or supported-platform parity.

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

The source-to-Scene state vocabulary is unified on `done`, `stopped`, `retrying`,
`interrupted` and `superseded`. Fake dispatch/queue/Steer and revisioned seen
commands now execute synthetic transitions. Oversized admitted text stays in
bounded canonical detail storage, queried through UTF-8 boundary-safe pages.
Explicit source Inspector-tab queries and real Changes facts remain absent;
plain tabs select among admitted snapshot records and state that limitation.

## Runnable synthetic interaction slice

From this checkout, run:

```sh
(cd apps/swarm_code_cli && MIX_QUIET=1 mise exec -- mix swarm_code.demo.plain --script complete)
```

The fixed demo starts only the CLI's declared application closure. It owns a
temporary source/client/input/session/driver tree, advances named barriers,
answers Q1, switches A/B/A, retries one authorized failed revision, stops one
authorized agent, and detaches without changing unrelated canonical work.
A golden transcript and isolated process/application audit cover its output
and teardown. It does not start a daemon, open a database, execute a provider,
read attachments, enter terminal raw mode, or access user runtime paths.

The permanent plain components share the TUI's Intent and RequestResolver.
They provide quoted line commands, bounded Unicode input, exact revisions in
output, reasoning channel records, current prompts, scoped navigation, Inspector
tabs and detail next/retry. Startup learns the conversation catalogue; recovery
holds input until a correlated fresh snapshot arrives. EOF waits for admitted
outcomes and detaches. Dead/unresponsive output is bounded and closes the client.
The parser/TUI conformance fixture checks independently committed request bytes.

The renderer-neutral runtime binds source and terminal in two phases, applies
semantic input in order, coalesces paints, and publishes a protected SceneSlot.
Draw results require current tokens/revisions; dirty detach requires explicit
confirmation and a final draw/restoration acknowledgement. Its deterministic
three-run scenario covers conversation drafts, questions, stale deliveries and
resizes through a test renderer. No rendered visual or accessibility claim follows
from those tests. See [keyboard scope](../implementation/task13-keyboard-surfaces.md)
for destinations, mode/history/fork, filters, Other/Skip and notification gaps.

Integration review reproduced and addressed newer-content rollback from stale
pages, shared-watch chunk erasure, Navigator/Main focus confusion, empty-chunk
retention, clipped long-option actions, missing Inspector Enter activation,
settled plain prompts remaining actionable, omitted revisions/reasoning,
Unicode output corruption, unbounded output waiting and incorrect response-kind
settlement. Further review fixed superseded-attempt chunk retention, page jumps
that skipped rows, failed recovery requests that blocked retry, final-draw
ordering, and demo startup/deadline cleanup. Narrow regressions establish each
trigger and resulting behavior. Real-source command integration also aligned Steer with
run permissions and enabled exact Activity-only question/approval context without
inventing a cached run.

## Renderer decision and cell previews

Fresh source verification now backs the [renderer decision](../decisions/tui-renderer.md).
Exact ExRatatui 0.13.0 is rejected for native paste allocation, the exposed width
API, missing public no-alt initialization, and the published arm64 GNU ABI.
The low-level Ratatui ForcedWidth facility is acknowledged; these facts do not
reject or adopt a separately implemented Port candidate. The bounded decision
module cannot turn arbitrary pass summaries into adoption.

The local locked-branch tests verify neutral dependencies, the nine-app runtime
closure, unchanged runtime/release/test-helper files, absence of conditional
native campaign outputs, and the real plain demo's process/application/runtime-
file baseline. Review added regressions against executable uses of supposedly
inert candidate names and symlinks concealing inspected output directories.
The historical September 1 recommendation now points to this decision.

The [cell paint design](../superpowers/specs/2026-09-06-cell-paint-plan-design.md)
and [work breakdown](../superpowers/plans/2026-09-06-cell-paint-plan.md) now have a
pure implementation. `Paint.build/2` paints all fifteen Scene block variants
into a bounded row-major Plan. Shared styled text handles cross-span graphemes,
contextual widths, both ambiguous-width policies, clipping, and color admission.
Canvas overwrite/fill operations clear complete wide glyphs and their action
ownership. Modal painting excludes background actions; visible action rectangles,
cursor, focus, and clipped-action diagnostics accompany the cells.

The fixed `mix swarm_code.demo.cells` command exports seventeen passive SVGs and
an HTML gallery in a fresh `_build/cell-previews/` directory. The twelve core
frames cover four run kinds at 80×24, 120×40, and 160×50; the remaining frames
cover question/confirmation dialogs at 80×24 and 50×16 in monochrome ASCII,
and the 49×13 survival surface. Export does not start a daemon or read user data.
SVG uses fixed 10×20 pixel cells, with preview-only fallback colors for terminal
defaults and no scripts or external resources.

Ego-lite visual review checked the responsive Navigator/Main/Inspector hierarchy,
Carbon surfaces and orange accents, default Cancel focus, narrow option focus,
and the resize/help/detach fallback. It exposed duplicate status/default metadata,
unnecessary zero-needs rows, missing focused-control cues, broken word wrapping,
and gallery upscaling; these were corrected. Integration review also exposed
combining-mark word breaks, crashes beyond the Paint size limits, Markdown
source-line versus rendered-row mismatches, and follow mode hiding the newest
message behind an older long message. Shared transcript row layout addresses
the scroll/paint mismatch without placing full history into a frame. The gallery loaded all seventeen
images. The task space and local HTTP server were closed after final verification;
daily sessions and cookies were untouched. This is synthetic cell/browser evidence, not terminal font shaping,
input/lifecycle evidence, or the native 87-frame acceptance matrix.

A second full verification exposed a backup-concurrency test deadline mismatch.
OTP's randomized global-lock retries can sleep up to eight seconds per retry,
while the test independently awaited each serialized caller for ten seconds.
A controlled slow-contention probe reproduced the timeout and then completed
with all four identical artifacts under the enclosing watchdog. The corrected
test uses an explicit 60-second ExUnit deadline and retains supervised teardown;
production backup behavior is unchanged.

## Validation and continuing work

The guarded Rust Port candidate now has a std-only input parser and a bounded
Draw-v1 codec shared by Elixir and Rust. Parser limits are enforced while bytes
are consumed, including paste overflow, split UTF-8, control-string discard and
one-event prefix consumption. Independent review found and fixed missing SOS
control-string handling. Legacy Alt punctuation and CSI-u extended forms remain
explicitly unsupported; this is not full terminal-input acceptance.

The native diagnostic checks the length header before allocating a body; its borrowed
decoder validates palette, cursor and complete declared-width cell coverage, and
exposes no text in diagnostic output. Twelve actual Elixir-generated representative frames passed through the
compiled Rust diagnostic across three dimensions/modes and both width policies.
The project-owned codec keeps action/focus metadata in BEAM. The adapter directory
admits its own namespace while retaining the existing daemon/database/dynamic-code
coupling checks. No runtime dependency or application startup changed.

Source review determined that the stock ratatui-crossterm backend enables the
unbounded event reader transitively and can consume input for cursor queries.
The implemented candidate therefore uses ratatui-core 0.1.2 cells, a project-owned
writer and crossterm 0.29.0 commands with all Crossterm features disabled.
Cargo.lock pins the graph; an offline verifier checks 58 locked crate identities
and 108 retained license texts. The executable, restoration guard, credit
transport, terminal owner and interactive synthetic demo are now implemented in
the [candidate plan](../superpowers/plans/2026-09-06-guarded-terminal-port.md).

The original full suite ran 79 core, 195 daemon and 39 CLI tests; its only
failure was the reproduced lease-monitor race. Width changes have 14 passing
focused tests, including new failing-before-fix regressions. The lease suite
has 16 passing tests. Source attestation passes via
`mise exec -- elixir scripts/dev/sync_unicode_width.exs --check`.

After the presentation, editor, drafts, geometry and initial typed source
implementation, `mise exec -- mix precommit` passed with seed 381891:
79 core, 195 daemon, 133 CLI tests and 4 properties; formatting, warnings-as-errors
compilation, dependency checks, source provenance and both Unicode verifiers
passed. Source review then added regression coverage for revision rollback,
stopped-run resurrection, malformed DTO field sets, over-limit append admission,
cross-scope delta metadata and question reopening across barrier orders.
The corrected Source/neutral suite passed 52 tests at seed 0; its Source-only
suite passed 30 tests at seed 4901. A subsequent complete CLI run passed
143 tests and 4 properties. That run exposed the separate fast-child Port
lifecycle race described above; its fix passed independent code review.

Foundation verification before this interaction slice: `mise exec -- mix precommit`, seed
579062, passed **79 core + 197 daemon + 143 CLI tests and 4 properties**.
Formatting, warnings-as-errors compilation, dependency checks, source provenance
and both offline Unicode verifiers passed. A separate
`MIX_ENV=prod mise exec -- mix compile --warnings-as-errors` passed, and a
production-mode invocation confirmed the test-only Port hook is rejected.
The desktop still has only its pre-existing untracked `.specs/` directory;
its source and user data were not modified. No rendered TUI/browser smoke test
is claimed: there is no runnable renderer or browser surface in this checkout.

Interaction-slice verification on 2026-09-06: `mise exec -- mix precommit`,
seed **728722**, passed **79 core + 197 daemon + 361 CLI tests and 4 properties**
(**637 tests**). Formatting, warnings-as-errors compilation, dependency checks,
source provenance and both offline Unicode verifiers passed. Production compile
also passed with `MIX_ENV=prod mise exec -- mix compile --warnings-as-errors`.
The actual contributor command exited 0 and matched the 5,372-byte golden output
exactly, with empty stderr and no output control bytes other than LF. The isolated
command test also verified the declared nine-app closure, application baseline
restoration, no surviving demo children, and unchanged temporary HOME/XDG paths.
No real renderer/browser smoke test is claimed. Desktop status remains only its
pre-existing untracked `.specs/` directory.

Renderer-decision checkpoint verification: two consecutive clean precommits,
seeds **279839** and **298750**, each passed **79 core + 197 daemon + 382 CLI
tests and 4 properties** (**658 tests**). Production compilation passed with
warnings treated as errors. The combined Decision/architecture/locked-branch
suite passed 26 tests under child `--no-start`, including the actual plain
command and unchanged isolated runtime-file hashes. No new terminal or browser
surface was exercised in this decision-only change.

Cell-paint checkpoint verification: final `mise exec -- mix precommit`, seed
**3159**, passed **79 core + 197 daemon + 489 CLI tests and 5 properties**
(**765 tests**). Formatting, warnings-as-errors compilation, dependency checks,
source provenance, and both offline Unicode verifiers passed. The final
`MIX_ENV=prod mise exec -- mix compile --warnings-as-errors` also passed.
Independent scoped reviews approved cell/span ownership, color and byte admission,
the canvas optimization, SVG/export boundaries, and the final transcript fixes.
The final focused integration suite passed 93 tests before the full run.

The actual preview command exported eighteen files to
`_build/cell-previews/preview-1788691377745019-1/`. All eighteen exactly matched
the visually checked gallery, and ego-lite loaded all seventeen final SVGs.
The original plain demo and its golden/process/application checks remained in
the passing umbrella suite. Desktop status remains only its pre-existing
untracked `.specs/` directory. No desktop source or user data was modified.

Terminal-input/codec checkpoint: `mise exec -- mix precommit`, seed **328227**,
passed **79 core + 197 daemon + 495 CLI tests and 5 properties** (**771 tests**).
Production compilation passed. `scripts/dev/check_terminal_port.sh` passed
rustfmt and **24 Rust tests** (20 parser, 4 frame decoder) with the pinned
Rust 1.97.1 compiler isolated under repository `_build`. The check script does not
install toolchains. Twelve actual Elixir draw frames decoded through the native
diagnostic; oversize, zero-length, truncated and trailing-byte inputs rejected.
Both scoped component reviews and the architecture/script follow-up are approved.
No live terminal, PTY, browser, provider, or canonical-data path was exercised by
this checkpoint. The desktop retains only its pre-existing untracked `.specs/`.

## Guarded interactive terminal checkpoint

`scripts/dev/run_terminal_demo.sh` now runs the existing three-run fixture through
SessionRuntime, a BEAM terminal owner, and the native guarded writer. It exercises
actual keyboard navigation, question selection/submission, bracketed paste,
composer focus, dirty Cancel/Confirm and clean detach. The launcher requires
`-noinput` because BEAM's user driver otherwise competes for terminal input.
Non-TTY and dumb terminals reject before mode changes and print the working plain
demo command. The demo is fixed synthetic data; it starts no Repo or provider.

The owner retains bounded wire state and correlation tokens, fetches exact Scene
revisions, permits one pending draw and one credit, and uses `Port.command/3` with
`:nosuspend`. The native writer validates complete declared-width spans, clears
dirty rows and commits its prior cell buffer only after a successful flush. An
explicit-flush 8 KiB buffer avoids a syscall for every command without Drop output.
One local 120×40 full-change sample improved from 123 ms to 12 ms; these isolated
samples are not p95 or renderer-adoption performance evidence.

Review and real PTY execution reproduced and corrected these integration defects:

- OTP28's Port detachment removes `/dev/tty`. The closed BEAM handoff verifies
  inherited fd0/fd1 identify the same terminal, opens an independent kernel-named
  descriptor, and reserves fd3/fd4 for protocol. Parent file-status flags stay exact.
- Delayed input credit expired a pending Escape before reading its queued CSI or
  paste suffix. Expiry now follows parser state and consumes queued suffixes first.
- Parent EOF could leak a writer stopped by SIGSTOP and its guard. The guard now
  observes parent closure independently and reaps the exact writer before restoring.
- External resume could race old credit or paint. ResumeNeeded establishes a FIFO
  barrier; Ready starts a fresh UI generation and full paint after a new Resume.
- Blocking `Port.command` stalled owner callbacks. Nonblocking admission closes
  the failed renderer within a bounded deadline; new credit waits for pending paint.
- A restoration retry could write through flags reset to blocking after an earlier
  output timeout. Every attempt now reestablishes nonblocking mode and still resets
  termios on failure. An undrained sink exits with restoration error and no children;
  successful escape-mode cleanup is not claimed when the sink stays blocked.

Native verification passed **44 Rust tests** and **14 owned-PTY tests**, plus
formatting and offline license verification. The live BEAM demo passed **8 PTY
tests**; the final fallback-message and lifecycle follow-up passed **3 focused
tests**. Tests cover exact termios, no-alt initialization, writer SIGKILL, signals,
resize-before-paint rejection, suspend/resume, bounded blocked-sink exit and no
surviving descendants. A resize during a multi-write paint is not atomic. Full
foreground shell job control remains unimplemented; Ctrl-Z retains editor undo.

Final `mise exec -- mix precommit`, seed **832090**, passed **79 core + 197 daemon
+ 513 CLI tests and 5 properties** (**789 tests**). Formatting, warnings-as-errors
compilation, dependency checks, provenance and both offline Unicode checks passed.
Final production compilation also passed with warnings treated as errors. Scoped
reviews approved the painter, codecs, owner, guard and restoration retry fix.
The desktop retains only its pre-existing untracked `.specs/` directory.

Ego-lite replayed actual native ANSI captures in pinned xterm.js 5.5.0 at 120×40,
in truecolor and monochrome. The final inspection covered workspace hierarchy,
Carbon surfaces and status accents, question options, composer draft and default
Cancel focus. The eight captures and hashed manifest remain under ignored
`_build/terminal-demo-captures/`. The task space and exact local HTTP server were
closed; daily browser sessions and cookies were untouched. This is native byte
output viewed through a browser emulator, not a substitute for native font shaping
or the complete 87-frame/four-target acceptance campaign.

Continue against the original full-parity objective. Completion requires real
runtime tests, supported-platform artifacts, a rendered terminal compared with
the desktop hierarchy, and coverage of each row above. A fake demo, theme
table or clean unit suite is progress, not proof that the CLI is complete.
