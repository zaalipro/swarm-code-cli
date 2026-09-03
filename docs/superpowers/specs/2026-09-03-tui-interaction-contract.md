# SwarmCode CLI renderer-neutral TUI interaction contract

**Status:** Interaction-contract specification for the next UX milestone; architectural constraints inherit from the approved 2026-09-01 CLI design
**Date:** 2026-09-03
**Target repository:** `swarm-code-cli`
**Scope:** Terminal presentation contracts, a fake-backed interaction proof, renderer selection, and traceability to later full parity. This document does not authorize UI implementation against the canonical database.

## 1. Authority and decision order

This contract refines, but does not replace, these sources:

1. `docs/superpowers/specs/2026-09-01-swarm-code-cli-design.md`, especially sections 4, 7, 11, and 12;
2. `docs/research/2026-09-01/feature-inventory.md`;
3. `docs/research/2026-09-01/tui-stack.md`;
4. `docs/research/2026-09-01/tui-ux.md`.

The approved architecture wins when older research differs. In particular:

- the renderer spike pins ExRatatui **0.13.0 exactly**, not a floating `0.13.x` range;
- production packaging starts with target-native `mix release` archives with bundled ERTS, not Burrito;
- TUI, plain, and headless clients call the same daemon command, query, and subscription contracts;
- the client is disposable and never owns runs, workflows, research, schedules, MCP processes, Git work, or canonical persistence;
- renderer structs, NIF resources, framework event names, and terminal-library state never enter the core, wire protocol, UI reducer state, or persisted data.

The repository currently contains pre-Repo foundation infrastructure and generic bounded JSON framing. `swarm_code_cli` does not yet contain a usable UI or a daemon IPC adapter. Therefore the next UX milestone is a renderer-neutral, fake-backed interaction proof that cannot open the canonical database.

## 2. Claim boundary

### 2.1 What the initial fake-backed renderer spike proves

The spike proves only:

- the Scene, Input, Action, Reducer, Effect, DataSource, and Renderer boundaries;
- responsive shell composition with title, Navigator, Main, unified Inspector, Activity Center, composer, and status regions;
- keyboard routing, focus, modal, logical-scroll-anchor, and in-session draft preservation;
- three concurrent fake runs updating while the user navigates and answers a waiting question;
- terminal-output sanitization and an append-only plain presentation;
- exact cell/style/cursor testing, terminal lifecycle restoration, native packaging viability, and the ExRatatui go/no-go decision.

### 2.2 What the spike does not prove

The spike does not prove:

- daemon supervision, database persistence, IPC authentication, reconnect correctness, slow-client pressure, or command idempotency;
- provider streaming, tool execution, policy, queue draining, server-side approval/question compare-and-set, or durable launch semantics;
- complete project, conversation, mode, workflow, research, MCP, scheduling, storage, settings, or administrative behavior;
- cross-repository behavioral parity with the desktop implementation;
- public artifact signing, notarization, installation, upgrade, rollback, or uninstall;
- that the spike is a usable SwarmCode release.

The spike must be labeled fake/demo-only, must not start `FoundationGate`, Repo, migrations, scheduler, MCP, or IPC admission, and must not be described as Phase 2 or full TUI parity. Renderer selection is a feasibility decision, not a release milestone.

### 2.3 Draft durability claim

This contract requires exact draft preservation across asynchronous updates, page/conversation navigation, responsive layout changes, modal use, and data-source resynchronization within a client session. It does not claim that an unsent draft survives an OS process crash. If process-crash draft persistence is added later, it must use a same-directory atomic client-only state file, remain outside the canonical database, and receive its own privacy, cleanup, and recovery tests.

## 3. Architecture and ownership

The interaction pipeline is:

```text
ExRatatui event
  -> ExRatatui013.normalize_event/2
  -> renderer-neutral Input
  -> Keymap.resolve/3
  -> semantic Action
  -> Reducer.update/2
  -> new UI State plus declarative Effects

DataSource delivery
  -> DataBridge.normalize/2
  -> semantic Action
  -> Reducer.update/2

UI State
  -> Projector.project/1
  -> renderer-neutral Scene plus current ActionTable
  -> Renderer.draw/2
```

The client session has these explicit owners:

```text
SwarmCodeCLI.UISupervisor
|-- Fake.Source
|-- DataSource client (starts unbound)
|-- SessionRuntime (starts in :binding)
|   |-- pure Reducer state
|   |-- current Scene and ActionTable
|   `-- redraw coalescer
|-- TerminalOwner (starts last)
|   `-- selected full-screen Renderer adapter
`-- UI-local timer/request supervisor
```

`TerminalOwner` is the only process that changes raw/cooked mode, cursor visibility, alternate-screen state, bracketed paste, focus reporting, or mouse reporting. `SessionRuntime` applies every semantic event in order and coalesces paints only. The DataSource owns no terminal state. The renderer owns no domain or editor state.

Startup is an explicit two-phase binding protocol, not a constructor PID cycle:

1. `UISupervisor` starts the source and client DataSource with stable, session-scoped handles and no delivery owner.
2. It starts `SessionRuntime` in `:binding`; the runtime creates its protected Scene slot and binds itself as the DataSource owner with a unique binding reference.
3. It starts `TerminalOwner` last. After native initialization, the owner registers its stable handle, terminal generation, and complete capabilities with `SessionRuntime`; successful registration returns the Scene-slot handle.
4. `SessionRuntime` emits initial watches and the first draw only after both bind acknowledgements. Either acknowledgement may arrive first, but neither may cause partial startup effects.
5. A failed, duplicate, stale, or timed-out bind closes the client DataSource, cancels any admitted work, destroys the Scene slot, restores an initialized terminal, and terminates the zero-restart `:one_for_all` UI tree. No half-bound process remains available.

Session-scoped handles may resolve to PIDs internally, but circular constructor PIDs are forbidden. A bound DataSource monitors its runtime owner; a registered terminal owner monitors the runtime and supervisor. Close is idempotent from every binding state.

Every timer, subscription, request, monitor, terminal mode, and renderer resource has one owner and one settlement path. Closing the client cancels view-owned requests and subscriptions and detaches. It never synthesizes a domain Stop command.

## 4. Common types and invariants

The concrete namespace is `SwarmCodeCLI.UI`, corresponding to the approved design's logical `Cli.Ui.*` boundary.

### 4.1 Identifiers

- Domain entity, request, watch, action, timer, and scene IDs are binaries.
- Daemon-facing request IDs are canonical UUIDs.
- Human research numbers are presentation fields, not protocol scope IDs.
- Runtime or decoded input never creates an atom. Wire strings are matched against a closed compile-time table; unknown values are rejected or rendered as inert data.
- Renderer action IDs are opaque. Neither renderer nor future sidecar parses an ID to reconstruct a command.

### 4.2 Generations and correlation

The reducer tracks:

- a data-source epoch identifying the connected daemon instance or fake instance;
- one generation per visible watch slot, such as global shell, active workspace, and active Inspector detail;
- watch reference, snapshot revision, and last contiguous sequence per slot;
- request reference and originating draft or view for each outstanding request.

On scope replacement, the reducer increments the slot generation first, freezes the old slot, then emits cancel/unwatch effects. Deliveries with the wrong source epoch, watch reference, scope, generation, request reference, or sequence are ignored. Durable command responses remain correlated to their origin even when that origin is offscreen; navigation cancels view queries, not admitted mutations.

### 4.3 Bounded presentation state

Reducer state may retain page-limited normalized DTO windows and byte-bounded derived layout caches. It must not retain a full transcript, full tool logs, full workflow journals, complete research sources, Ecto structs, or copied provider history. Eviction causes exact demand recomputation. Canonical text, reasoning, tool arguments/results, and ordering are never truncated by the UI cache.

## 5. Scene contract

`SwarmCodeCLI.UI.Scene` is the full-screen renderer-neutral output. Its top-level contract is:

```elixir
%Scene{
  schema_version: 1,
  revision: non_neg_integer(),
  size: %Size{columns: pos_integer(), rows: pos_integer()},
  ambiguous_width: :narrow | :wide,
  layout_class: :xl | :wide | :medium | :narrow | :small | :too_small,
  regions: [Region.t()],
  overlay: Dialog.t() | nil,
  cursor: Cursor.t() | nil,
  announcements: [Announcement.t()]
}
```

A `Region` contains:

- a stable binary ID;
- a role from `:title`, `:navigator`, `:main`, `:inspector`, `:activity`, `:composer`, and `:status`;
- a resolved terminal-cell rectangle;
- a fixed accessible label;
- focus state `:inactive`, `:active`, or `:contains_focus`;
- a closed list of semantic blocks;
- optional scroll/follow metadata.

The initial Scene block union contains:

- text and rich spans;
- sanitized Markdown and code;
- virtual list/window;
- run card;
- agent tree/list;
- consensus ledger/ticker;
- research document/source list;
- progress;
- tabs;
- key/value rows;
- composer;
- notice and action deck.

Dialogs are top-level overlay data rather than renderer-owned popups. Diff, structured form, source editor, agenda/calendar, workflow journal, and additional data-heavy blocks are added as closed variants alongside the later surface that needs them. Adding a variant requires an exhaustive adapter mapping, structural tests, and cell goldens; arbitrary renderer widgets or untyped payload maps are not an extension mechanism.

Every block contains only stable IDs, bounded numbers, closed semantic style roles, `SafeText`, and opaque action references. A virtual list includes total count, first logical index, visible items, before/after cursors, and bounded overscan metadata. It never embeds complete history.

`Projector.project/1` returns:

```elixir
{Scene.t(), %{required(action_id()) => Action.t()}}
```

The second value is the current `ActionTable`. The renderer receives action IDs in the Scene, not the table's semantic values. Activation returns the action ID plus Scene revision. The runtime ignores stale, missing, or disabled activations.

The projector, not the renderer, decides:

- visible and enabled actions;
- region and responsive structure;
- status vocabulary and density;
- focus indicator and cursor placement;
- trusted labels and descriptions;
- how canonical DTO facts become semantic blocks.

Every cell-oriented operation uses `Scene.ambiguous_width`. The default is `:narrow`; `--ambiguous-width=narrow|wide` is the only override. Editor visual columns, wrapping, elision, cursor and selection geometry, renderer drawing, cell capture, and PTY cursor assertions must all consume the same value. No renderer may redetect or silently substitute another East Asian Ambiguous-width policy.

## 6. Renderer and Input contracts

The renderer behavior is:

```elixir
init(RendererOptions.t()) ::
  {:ok, renderer_state(), Capabilities.t()} | {:error, RendererError.t()}

normalize_event(renderer_event(), renderer_state()) ::
  {:ok, Input.t(), renderer_state()}
  | {:ignore, renderer_state()}
  | {:error, RendererError.t(), renderer_state()}

draw(Scene.t(), renderer_state()) ::
  {:ok, renderer_state()} | {:error, RendererError.t(), renderer_state()}

shutdown(renderer_state()) :: :ok
```

Only an adapter module may hold ExRatatui structs, NIF resources, or framework event names. The adapter draws the supplied Scene, translates renderer events to neutral Input, and restores its own renderer resources. It does not query the DataSource, interpret domain state, maintain authoritative textarea state, or decide action validity.

Neutral Input covers:

- key press, repeat, and release using closed generic key/modifier values;
- grapheme text input;
- bracketed paste as one bounded payload;
- resize;
- focus gained/lost;
- optional mouse press, release, drag, and wheel;
- terminal suspend/continue lifecycle notification.

Mouse is disabled by default. Every mouse result must have a visible keyboard and command/menu route.

## 7. Action contract

Actions express user or data meaning rather than renderer keys:

```elixir
@type t ::
        :boot
        | {:resize, Size.t()}
        | {:terminal_capabilities, terminal_generation(), Capabilities.t()}
        | {:terminal_lifecycle, :suspend_requested | :suspended | :resumed | :closing,
           terminal_generation(), :keyboard | :launcher | :runtime}
        | {:terminal_failed, terminal_generation(), terminal_error_code()}
        | {:draw_result, draw_token(), scene_revision(), :ok | {:error, terminal_error_code()}}
        | :back
        | {:focus_cycle, :next | :previous}
        | {:focus_region, region_id()}
        | {:move, :next | :previous | :first | :last}
        | {:expand, item_id(), boolean()}
        | {:activate, action_id(), scene_revision(), request_id()}
        | {:scroll, region_id(), scroll_operation()}
        | {:editor, DraftKey.t(), EditorOperation.t()}
        | {:field_editor, FieldKey.t(), EditorOperation.t()}
        | {:layout_adjust, :navigator | :inspector,
           :reset | {:preset, :compact | :balanced | :wide} | {:nudge, -8 | -2 | 2 | 8}}
        | {:composer_height, :reset | {:nudge, -1 | 1}}
        | {:presenter_handoff_requested, :plain}
        | {:navigate, Destination.t()}
        | {:open_layer, LayerSpec.t()}
        | :close_top_layer
        | {:data, DataSource.Delivery.t()}
        | {:timer_fired, timer_id()}
        | {:quit_requested, :detach | :daemon_shutdown}
```

`scroll_operation()` is one of line delta, page delta, first, last, follow, and detach. Editor operations are grapheme-based insert, paste, delete, cursor movement, selection extension, word movement/deletion, line/buffer Home/End, copy, cut, undo, redo, and explicit newline. Undo groups contiguous inserts/deletes until movement, selection, paste, or a 1,000 ms runtime-supplied boundary action; the editor itself reads no clock. ExRatatui textarea state cannot become authoritative because it would prevent renderer replacement.

`FieldKey` is separate from `DraftKey` and has only these forms:

```text
{:layer_query, layer_id, :switcher | :jump | :action_menu}
{:region_filter, region_id}
{:question_other, interaction_id, interaction_revision}
```

Field editors reuse the grapheme editor but are bounded transient UI state, never composer drafts. Closing their owning layer clears them. Paste, committed IME text, and text fragments route to the active `FieldKey` before a hidden composer. `:back` closes one drill-down page or returns from Activity to its exact saved destination/focus/selection/anchor context; it is distinct from Escape's one-layer cancellation.

Resize is an observed terminal input, not a program action that can resize the emulator. At survival sizes the visible action is therefore `Resize help`, which opens fixed instructions. `presenter_handoff_requested` performs an orderly terminal restore and exits with a fixed control-free `Rerun with --plain` instruction; the spike does not replace the full-screen renderer with the line presenter in-process.

Input resolution consumes at most one action and uses this priority:

1. modal/dialog;
2. switcher, palette, or other overlay;
3. composer/editor;
4. focused content region;
5. global keymap.

An input event must never both close one layer and activate the newly exposed layer.

Only `:press` may activate, submit, answer, approve, deny, stop, confirm, queue, detach, or invoke a shortcut. `:repeat` is accepted only for text insertion/deletion, cursor or selection movement, logical-row movement, and scrolling. `:release` is inert. An activation installs a correlated mutation state before emitting its command, so held Enter or a second input cannot enqueue the same mutation twice.

## 8. Reducer contract

The reducer API is pure:

```elixir
init(Init.t()) :: {State.t(), [Effect.t()]}
update(State.t(), Action.t()) :: {State.t(), [Effect.t()]}
```

It performs no clock, UUID, process, terminal, filesystem, Git, network, Repo, or daemon call. Runtime-provided clock and UUID seams enter as fixed initialization data or explicit Actions.

Reducer state owns only:

- bounded normalized read-model windows;
- data-source epoch, watch generations, revisions, sequences, and resync state;
- current destination and per-destination navigation history;
- focus, row selection, expansion, filters, and tabs;
- logical scroll anchors and follow state;
- composer drafts and later form/editor drafts;
- responsive layout preferences and terminal capabilities;
- transient `FieldKey` editors and per-mutation `idle | pending | settled` state;
- logical modal/drill-down stack;
- correlated outstanding requests and commands;
- visible-only UI animation state.

The reducer does not decide domain policy. DTOs provide a closed `allowed_actions` set and optional safe disabled reason. The UI may further remove an action because the terminal cannot represent it, but it may not add a domain action that the server did not authorize. The daemon validates every command again.

Every matching semantic data event is applied immediately. State revision becomes dirty, and `SessionRuntime` schedules at most one draw for the current frame interval. Coalescing paints must never coalesce, overwrite, or discard semantic text/tool events. Hidden panes retain facts without running animation timers or repeated layout work.

Mutation projection is closed and explicit. `pending` disables the originating action and names the operation. Settlement is exactly one of accepted, needs input, rejected, deadline exceeded, interrupted, revision conflict, or outcome unknown. Only durable acceptance clears the exact originating draft; every other outcome preserves its editor/dialog and exposes fixed corrective text. A compare-and-set conflict refreshes the interaction and never displays success.

## 9. Effect contract

Effects are a closed declarative union:

```elixir
@type t ::
        {:watch, DataSource.Watch.t()}
        | {:unwatch, watch_ref()}
        | {:query, DataSource.Request.t()}
        | {:command, DataSource.Request.t()}
        | {:cancel_request, request_id()}
        | {:start_timer, timer_id(), non_neg_integer(), Action.t()}
        | {:cancel_timer, timer_id()}
        | {:terminal_control, :suspend | :resume | :shutdown}
        | {:announce, SafeText.t()}
        | {:bell, :needs_you}
        | {:clipboard_write, ClipboardPayload.t()}
        | {:presenter_handoff, :plain}
        | {:detach, exit_status()}
```

Effects contain no anonymous functions or runtime-selected modules. Every request carries a request ID, originating scope/draft where applicable, absolute deadline, and expected response type. Every effect produces one settlement action or is canceled explicitly.

Filesystem, Git, process, network, MCP, external-open, reveal, download, and persistent-setting work are not local reducer effects. They are typed daemon commands evaluated through the permission system. Clipboard write is explicit, byte-bounded, opt-in, and terminal-capability-gated.

## 10. DataSource contract

`SwarmCodeCLI.UI.DataSource` is the client-owned boundary that allows the fake interaction lab to precede daemon IPC. Its behavior is:

```elixir
start_link(options: keyword()) :: GenServer.on_start()
bind_owner(server(), owner_handle(), binding_ref()) ::
  {:ok, binding_ref()} | {:error, :already_bound | :closed | :binding_failed}
watch(server(), Watch.t()) :: :ok | {:error, AdmissionError.t()}
unwatch(server(), watch_ref()) :: :ok
query(server(), Request.t()) :: :ok | {:error, AdmissionError.t()}
command(server(), Request.t()) :: :ok | {:error, AdmissionError.t()}
cancel(server(), request_id()) :: :ok
close(server()) :: :ok
```

Before `bind_owner/3` succeeds, watch/query/command/cancel calls fail with a closed admission error and no delivery can be emitted. Binding is single-assignment, reference-correlated, and monitors the owner. Duplicate/stale binding, owner death, or close settles every buffer and waiter without leaking deliveries to a replacement process.

These calls perform bounded local admission only. Results are delivered asynchronously:

```elixir
{:swarm_code_ui_data, source_epoch,
 %Delivery{
   kind: :watch_ready | :delta | :response | :resyncing | :error | :closed,
   watch_ref: binary() | nil,
   request_id: binary() | nil,
   scope: SwarmCode.Protocol.Scope.t() | nil,
   generation: non_neg_integer(),
   revision: non_neg_integer() | nil,
   sequence: non_neg_integer() | nil,
   body: typed_ui_dto()
 }}
```

### 10.1 Watch guarantees

1. `watch_ready` contains a page-limited snapshot and `through_sequence` before any delta is made visible.
2. Deltas after readiness are strictly contiguous.
3. Events received between daemon subscribe acknowledgement and snapshot response are buffered by the synchronization layer with count and byte bounds.
4. A gap, `snapshot_required`, buffer overflow, or daemon-instance replacement produces `resyncing`, retains current visible/draft/focus/scroll state, and installs a replacement snapshot.
5. Old source epoch, watch reference, scope generation, request, revision, or duplicate sequence is rejected.
6. Unwatch/close settles every local waiter, monitor, timer, and buffer.
7. Slow-client pressure may replace derived queued deltas with `snapshot_required`; it never discards canonical content.

### 10.2 Initial typed queries

The first real workspace needs closed query variants for:

- global shell and Navigator page;
- workspace snapshot by conversation and keyset cursor;
- older/newer transcript page;
- Activity Center page;
- pending interactions by scope;
- run detail by run and Inspector tab;
- explicit large detail by opaque `DetailRef` and page cursor.

Later surfaces add closed variants for workflows, research, schedules, usage, storage, settings, providers, search, and MCP. Untyped JSON paths and arbitrary operation strings are forbidden.

### 10.3 Initial typed commands

Closed command variants cover:

- dispatcher launch with stable request UUID, source, project/conversation, text, attachment/research references, explicit target, and queue intent;
- run Pause, Continue, Resume, Stop, and agent Stop;
- Steer;
- answer question with interaction revision;
- resolve approval with interaction revision;
- mark seen/read;
- scoped conversation/project actions introduced by their parity task.

The DataSource returns one of the approved outcomes:

- accepted with durable identifiers;
- needs input with a typed interaction schema;
- rejected with stable error code and corrective action;
- outcome unknown only for a dispatched external non-idempotent effect whose result cannot be established.

### 10.4 Presentation DTOs and deltas

Initial DTOs are explicit page-limited structures:

- `ShellSnapshot`;
- `WorkspaceSnapshot`;
- `TranscriptWindow`;
- `RunDetailSnapshot`;
- `ActivitySnapshot`;
- `PendingInteraction`.

Initial normalized delta variants are:

- transcript-item upsert/remove;
- stream append/reset by entity, channel, and attempt ID;
- run-summary update;
- pending-interaction upsert/remove;
- Activity item and aggregate-count update;
- connection/resync state.

Every page-limited list also carries `idle | loading_before | loading_after | error | closed | resyncing`, opaque page-request identity, and a retryable static-safe error when applicable. Reaching an unloaded edge emits one deduplicated page query and exposes a visible loading sentinel; repeated movement at that edge does not enqueue another query. A response, cancellation, or retry settles the sentinel exactly once.

Item presence is explicit. `off_window` means the item is outside the loaded keyset range and preserves selection/anchor identity; `removed` requires an explicit remove delta or a replacement snapshot whose declared covered range proves absence. On confirmed removal, focus/anchor repairs to the successor at the same visual bias, then the predecessor, then the list's empty-state focus. Prepending retains the existing anchor and visual bias.

Supersession is not removal. A superseded turn remains losslessly visible with the fixed `SUPERSEDED` word and muted role, hides live progress/Needs-you/Reply/Retry, and retains Inspect/Copy/Fork. A running child launched by it says `LAUNCHED BY SUPERSEDED TURN` and keeps server-authorized Stop. Approve/Revise keeps the planner containing the linked implementation visible.

The DataSource never exposes Ecto structs, complete GenServer state, secrets, raw wire maps, or dynamically atomized input. `swarm_code_cli` depends on stable core protocol types, not daemon implementation modules.

## 11. Responsive layout contract

Terminal columns and rows are capabilities. Class selection uses the highest class whose width and height minima are satisfied:

| Class | Minimum | Required structure |
|---|---:|---|
| XL | `170x34` | Navigator 24-32 columns, Main at least 50, Inspector 38-56; an additional pinned Inspector is optional and outside the initial spike. |
| Wide | `150x30` | Navigator, Main, and one Inspector. |
| Medium | `100x24` | Main plus exactly one docked Navigator or Inspector. Opening one hides but does not reset the other. |
| Narrow | `72x20` | One Main surface; Navigator, Inspector, Activity, and dialogs use full-height overlays. |
| Small | `50x16` | One-row title, Main, one-row live/Needs-you strip, compact composer, and status. |
| Compressed Small | at least 50 columns and 14-15 rows | Preserve resize/help/detach/plain access with a one-line editor or hidden editor drawer; retain all state. |
| Too small | fewer than 50 columns or fewer than 14 rows | Show current and required size plus Resize, Help, Detach, and `--plain`; do not expose destructive/send actions. |

This closes the height gap between the research table's `50x16` Small recommendation and the approved architecture's `<50x14` hard failure boundary. Width-qualified layouts that miss their height minimum fall to the highest lower class they satisfy; `50x14` is the final survival class.

Additional invariants:

- Main never falls below 50 columns when another region is docked.
- Navigator and Inspector widths persist as UI preferences but clamp on every resize.
- Below XL, Thread and Agents/Timeline/Changes are not simultaneous columns.
- Composer grows to at most eight rows.
- Needs-you uses at most two rows before becoming a count and Activity link.
- Expanded run logs use at most 45 percent of viewport height unless explicitly maximized.
- Overlay title and actions remain visible while its body scrolls.
- Whole-screen horizontal scrolling is forbidden. Only code, diff, raw JSON, and explicitly wide tables scroll horizontally.
- Tables collapse to labeled records, schedules default to agenda, consensus sides stack, research timeline moves to Inspector, workflows become list/detail navigation, and settings become searchable master/detail as width decreases.

Content density is deterministic and cell-budgeted:

| Class | Title and state budget | Secondary controls | Status help |
|---|---|---|---|
| XL/Wide | Full fake banner, project/branch, conversation/page, mode, running/waiting/Needs-you counts | Full model, effort, approval, target, attachment, queue, and live-run labels | Three to five bindings plus focus identity |
| Medium | `FAKE — NO USER DATA`, cell-elided project/branch and page, mode, exact state and counts | Model without effort first; chips collapse to labeled counts before Main loses 50 cells | Two or three bindings plus focus identity |
| Narrow | `FAKE — NO USER DATA`, cell-elided page, mode, exact state and Needs-you count | Target stays named; secondary model/approval and chips move to Inspector/action deck | Two bindings plus `?` and focus identity |
| Small | `FAKE — NO USER DATA`, mode, exact state and `NEEDS n`; project/page remain available in Inspector/help | One-line target/validation or labeled attachment/queue/run counts | One binding plus `?`; status names focused region/item |
| Compressed Small/Too small | `FAKE — NO USER DATA`, mode, exact error/size state | Only `Resize help`, Help, Detach, and `Exit; rerun with --plain`; no send/destructive action | `?` plus exact focus identity |

Mode, exact state word, Needs-you state/count, active target type, validation/error, and focus identity are never omitted from the overall Scene. Secondary model/effort/approval metadata, attachments, queue, and live runs collapse in that order to labeled counts or move to Inspector before being elided. Status hints reduce before semantic facts.

Cell-aware elision never splits a grapheme. Human names and model labels end-elide; paths, project/branch pairs, refs, and filenames middle-elide so both identity ends survive. The complete sanitized value is available through Inspector/action-menu detail. Wrapping and elision use the Scene's one ambiguous-width policy.

Projection follows an anti-box-soup rule: assistant prose is unboxed; one prompt-plus-run card has at most one boundary and one progress rule; Navigator and Inspector use separators/whitespace; overlays have the strongest border; orange marks current focus/live work only. Unicode/ASCII kind identity uses stable one-cell `G/S/W/R/C` prefixes and numbered agent lanes, never color alone.

Overlay title, breadcrumb, and action/footer rows are sticky. The body has an independent logical scroll anchor; moving focus auto-reveals the complete focused row with the smallest possible scroll, wraps options deterministically, and shows a compact `item x of y` overflow summary. Tab/Shift+Tab and arrow navigation remain trapped when the first or last control begins offscreen. Resize preserves focused control and body anchor. At `50x14`, an already-open mutation/destructive overlay becomes a read-only summary with Back/Close/Help only; its state is retained until the terminal grows.

## 12. Keyboard, focus, and modal contracts

### 12.1 Global keys

| Key | Action |
|---|---|
| `Ctrl+K` | Universal switcher. |
| `Ctrl+N` | New conversation while preserving the old conversation draft. |
| `Ctrl+B` | Toggle Navigator. |
| `Alt+I` | Toggle Inspector. |
| `Alt+1` through `Alt+4` | Thread, Agents, Timeline, Changes. |
| `Alt+M` or `/mode` | Mode selector. |
| `Alt+Shift+H` / `Alt+Shift+L` | Nudge the focused Navigator/Inspector width by -2/+2 cells; adding `Ctrl` uses -8/+8. |
| `Alt+Shift+0` | Reset the focused Navigator/Inspector width; compact/balanced/wide presets remain in the action menu. |
| `?` outside text entry | Contextual help. |
| `g c`, `g w`, `g r`, `g s`, `g u`, `g ,` | Chats, Workflows, Research, Scheduled, Usage, Settings. |
| `q` outside text entry | Detach request. |
| `Ctrl+C` outside text entry | Conventional interrupt/detach request; never implicit Stop-all. |

Every shortcut has a switcher, action-menu, or command route. macOS Command keys are not required.

### 12.2 Lists, trees, and documents

| Key | Action |
|---|---|
| arrows or `j`/`k` | Previous/next logical row. |
| `h`/`l` | Collapse/expand. |
| `Enter` | Activate/open. |
| `Space` | Toggle/select without navigation. |
| `g g` / `G` | First/last or follow latest. |
| `PageUp` / `PageDown` | Page viewport. |
| `/` | Filter/search current region. |
| `n` / `N` | Next/previous match. |
| `[` / `]` | Previous/next turn or round according to region. |
| `i` | Inspect focused item. |
| `a` | Action menu. |

### 12.3 Run cards

| Key | Action |
|---|---|
| `Enter` or `l` | Expand. |
| `r` | Reply; a failed run exposes Retry through its action menu to avoid ambiguity. |
| `s` | Steer. |
| `p` | Pause or Continue according to the server-provided action set. |
| `x` | Stop confirmation. |
| `t` | Thread Inspector. |
| `o` | Selected operation/detail. |
| `m` | Mark read. |

### 12.4 Composer

- `Enter` sends only when no palette, interview, confirmation, paste, or IME composition is active.
- Enhanced `Shift+Enter` inserts newline when the terminal distinguishes it.
- `Ctrl+O` is the guaranteed newline fallback.
- `Alt+Enter` queues; `/queue` is the portable fallback.
- `Ctrl+R` opens prompt history.
- Paste is one insert operation and can never submit.
- Backspace on an empty draft may remove an explicit Reply/Steer/Revise target; Escape does not silently remove command or target state.
- `Ctrl+Up`/`Ctrl+Down` adjust composer height by one row and `/composer-height reset` restores the automatic height; the value remains clamped to one through eight.
- Alt/Option word movement/deletion, line Home/End, Ctrl+Home/Ctrl+End buffer movement, and Shift+movement selection are neutral editor operations. Paste and cut form their own undo groups; contiguous typing/deletion uses the fixed grouping boundary.
- `Ctrl+C` copies a nonempty selection when bounded clipboard capability is available. When it is unavailable, the selection remains and a visible `COPY UNAVAILABLE` notice offers the action-menu/plain fallback. `Ctrl+X` follows the same rule and deletes only after a successful copy. With no selection or outside text entry, `Ctrl+C` requests detach.

### 12.5 Questions and approvals

- `1` through `9` choose numbered options.
- arrows move the option cursor.
- Space toggles multi-select.
- Enter advances or submits.
- `b` goes Back.
- `s` explicitly skips when Skip is allowed.
- `a`, `d`, and uppercase `A` mean Approve, Deny, and Always allow only while an approval is focused.
- Escape closes/leaves the current layer without answering, skipping, approving, or denying.

### 12.6 Focus and modal behavior

- The bottom status line always names the focused region and selected item.
- Tab and Shift+Tab cycle visible regions, never every small action.
- Breakpoint-driven hiding moves active focus deterministically to Main while retaining the hidden region's stored focus and selection.
- One visual overlay exists at a time. Nested flows are logical drill-down pages inside the same overlay with breadcrumbs.
- The background is inert while an overlay is open.
- Tab and Shift+Tab trap within the overlay.
- Initial focus is the safest enabled action.
- Destructive confirmation defaults to Cancel. Bare Enter cannot become destructive until the user explicitly focuses the destructive action.
- Escape closes exactly one logical layer and restores opener region, item, scroll, and selection.
- If another client resolves a visible interaction, the current dialog becomes a settled/read-only state instead of disappearing and stealing focus.
- Every operational breakpoint has an explicit focus graph. Traversal visits every enabled region/action-menu control exactly once, never reaches hidden or disabled actions, exposes a focused disabled reason in the action menu, and restores the prior legal focus after resize or layer close.
- Terminal `focus_lost` pauses visible-only animation and cursor emphasis without changing logical region/item focus; `focus_gained` resumes allowed animation and requests one redraw. Neither event activates, navigates, or resets selection.

### 12.7 Switcher, filters, and transient fields

The switcher and action menus use `FieldKey` editors. Prefixes are closed and literal: no prefix searches all visible fake destinations/actions, `>` commands, `@` conversations, `#` runs/interactions, and `/` current-region items. Ranking is exact prefix match, token-prefix match, then substring; ties use fixed kind precedence and stable display-label/ID ordering. Empty text shows the deterministic recent/default set and zero matches shows one inert `NO RESULTS` row.

Async patches rerank candidates but retain the selected stable ID when it remains; otherwise select the next result at the same index, then the predecessor, then the query field. Escape closes one layer and restores its opener. `:back` returns one drill-down level or the saved Activity return context. Paste/committed IME/text repeat edit only the active field; release events and activation repeats are inert.

## 13. Draft, scroll, and asynchronous preservation

### 13.1 Draft keys and contents

Drafts are keyed by:

```text
{conversation_id, :main}
{conversation_id, {:thread, run_id}}
{conversation_id, {:edit, message_id}}
```

A composer draft includes:

- exact text;
- grapheme cursor and selection;
- editor vertical/horizontal scroll;
- Reply, Steer, Revise, command, goal, and research target/chip state;
- attachment references and staged validation state;
- chosen editor height.

Transient `FieldKey` editors contain exact text, logical-grapheme cursor/selection, composition state, and bounded undo only. They are capped at 16,384 bytes and belong to their layer/region; they never alias, clear, or persist a conversation draft. RTL scripts edit in logical grapheme order. Cursor and selection fixtures assert the visible cell edges produced by the chosen ambiguous-width policy; visual bidi reordering is not inferred from codepoint indices.

Later `FormDraft` and `EditableBuffer` state use the same preservation rules and additionally track server baseline revision, dirty fields or content hash, validation results, and submit request.

Rules:

- navigation stores and restores exact draft state;
- background events never mutate a draft;
- accepted durable send/queue clears only its originating draft;
- needs-input, rejected, timeout, interrupted client connection, and outcome-unknown results preserve the draft and show an actionable notice;
- an admitted command response settles its offscreen originating draft after navigation;
- unrelated settings/status updates never overwrite dirty form fields;
- attachment bytes and base64 data never enter reducer state.

### 13.2 Logical scroll state

Each scrollable region/scope stores:

```text
anchor = {stable_item_id, intra_item_line, top_or_cursor_bias}
follow = true_or_false
unseen = ordered_set_of_stable_item_ids
before_cursor = opaque_keyset_cursor_or_nil
after_cursor = opaque_keyset_cursor_or_nil
```

Rules:

- user wheel, key, or page movement detaches immediately;
- async insertions and height changes do not move the logical anchor;
- multiple updates to the same stable item count once while detached;
- `End` or `G` rejoins and clears unseen state;
- Main and Inspector follow independently;
- prepending an older page retains the anchor;
- resize recomputes wrapping from the stable item and intra-item line rather than retaining a raw row offset;
- sending the user's own message rejoins once, after durable acceptance;
- offscreen canonical updates remain available through the next snapshot even when their watch was closed.
- moving or paging at an unloaded edge emits one correlated page request and focuses a visible loading sentinel; repeat keys cannot duplicate it;
- page failure replaces the sentinel with a focused retry action, while closed and resyncing states retain the last visible rows;
- an `off_window` focus/anchor remains logically stable until a page proves its position; only confirmed `removed` state repairs to successor, predecessor, then empty-state focus.

### 13.3 Async status behavior

- Long-running work never forces navigation.
- Global running/waiting counts and Activity rows update independently of the active page.
- Completion is a non-blocking Activity/notification event.
- A disconnect or resync marks content stale without replacing it with a blocking spinner.
- Hidden regions do not animate or continuously recompute.
- Visible elapsed text updates only when the displayed unit changes.
- Mutation state is visible as pending until one correlated outcome arrives; async data cannot make a second activation valid while it is pending.

## 14. Sanitization, trusted chrome, accessibility, and plain mode

### 14.1 Safe text

`SafeText` has separate constructors for fixed trusted UI chrome and external content. Only `SafeText` may enter Scene text or plain output.

External-content processing must:

- replace invalid UTF-8 with a visible replacement;
- retain structured newline boundaries and expand tabs to spaces;
- expose carriage return, backspace, delete, Escape, C0/C1, CSI, OSC, DCS, APC, and PM bytes/sequences visibly rather than executing them;
- expose bidi override/isolate controls by name;
- expose standalone deceptive zero-width characters;
- retain combining marks and emoji ZWJ/variation selectors only as part of a validated extended grapheme;
- wrap, truncate, cursor, and measure by grapheme/wcwidth rather than bytes or codepoints;
- cap any visible escaped representation before allocation according to the source field's bound.

Model, repository, Git, command, MCP, filename, URL, and log bytes cannot become action labels, terminal titles, cursor movement, trusted approval headers, or renderer control strings. Approval buttons use fixed labels; external tool/scope/target data is inert body text.

OSC 8 is generated only for a separately validated destination. OSC 52 clipboard write is explicit, bounded, opt-in, and disabled by default under SSH/tmux. The renderer does not emit an OSC terminal title from project or conversation content.

### 14.2 Status and color

Carbon dark is the only spike theme. These roles are exhaustive before the first golden is accepted; `ansi16` names the ordinary/bright ANSI color rather than assuming a numeric palette:

| Role | Truecolor | ANSI 256 | ANSI 16 | Monochrome contract |
|---|---:|---:|---|---|
| canvas | background `#141414` | bg 233 | black bg | terminal default background |
| surface | background `#191919` | bg 234 | black bg | spacing plus separator |
| card | background `#1e1e1e` | bg 235 | bright-black bg | one border where semantically grouped |
| border | `#2a2a2a` | 236 | bright black | ASCII/Unicode border, never color alone |
| text_primary | `#f3f2f0` | 255 | bright white | normal/bold by hierarchy |
| text_muted | `#8c8b88` | 245 | white | explicit label; dim optional |
| text_faint | `#5e5d5a` | 240 | bright black | explicit label; dim optional |
| focus | `#ff6a1a` | 208 | bright yellow | reverse/bold plus `FOCUS`/`>` marker |
| selection | fg `#f3f2f0`, bg `#262626` | fg 255, bg 236 | reverse | reverse plus `SELECTED`/`>` marker |
| disabled | `#5e5d5a` | 240 | bright black | `[DISABLED: reason]`; never dim alone |
| stale | `#f5b400` | 220 | bright yellow | `[STALE]` plus border |
| accent/assistant | `#ff6a1a` | 208 | bright yellow | `C`/`RUNNING` word or current-focus marker |
| success | `#3ddc5a` | 41 | bright green | `[DONE]`/`OK` |
| warning | `#f5b400` | 220 | bright yellow | `[WAITING]`, `[APPROVAL]`, or `!` plus word |
| error | `#ff4d4f` | 203 | bright red | `[FAILED]`/`ERROR` |
| info/workflow | `#4da3ff` | 75 | bright blue | `[INFO]` or `W` prefix |

Run-kind roles are Assistant `#ff6a1a`/208/bright-yellow/`C`, Goal `#b08cff`/141/bright-magenta/`G`, Swarm `#2fd0b8`/44/bright-cyan/`S`, Workflow `#4da3ff`/75/bright-blue/`W`, Research `#ff9f45`/215/yellow/`R`, Consensus-Judge `#b8e356`/149/bright-green/`C`, and Ultra `#9b5cff`/135/bright-magenta/`U`. Agent lanes 1-5 are respectively `#2dd4bf`/44/cyan, `#a78bfa`/141/magenta, `#f59e0b`/214/yellow, `#f472b6`/212/magenta, and `#38bdf8`/81/cyan; every lane also prints `A1` through `A5`.

Display labels and tones are separate closed tables:

| State | Required display label | Tone role |
|---|---|---|
| connecting | `CONNECTING` | info |
| empty | `EMPTY` | text_muted |
| loading | `LOADING` | info |
| running | `RUNNING` | accent |
| streaming | `STREAMING` | accent |
| queued | `QUEUED` | info |
| waiting_question | `NEEDS ANSWER` | warning |
| waiting_approval | `NEEDS APPROVAL` | warning |
| paused | `PAUSED` | warning |
| retrying | `RETRYING` | warning |
| done | `DONE` | success |
| failed | `FAILED — RETRY AVAILABLE` | error |
| stopped | `STOPPED` | text_muted |
| interrupted | `INTERRUPTED — RESUME AVAILABLE` | warning |
| stale | `STALE` | stale |
| resyncing | `RESYNCING` | info |
| disconnected | `DISCONNECTED` | error |
| superseded | `SUPERSEDED` | text_muted |
| mutation_pending | `PENDING` | info |

Color, bold, and dim are never the only signal. ASCII replaces box drawing and specialized glyphs without losing prefixes/state words. Reduced motion removes spinners, pulses, color cycling, and animated scrolling while retaining the exact state label and static progress value.

### 14.3 Plain presenter

Plain mode consumes the same normalized DataSource projection, not a serialized full-screen Scene. It is:

- selected explicitly by `--plain` and automatically when stdout is not a TTY or `TERM=dumb`;
- append-only and chronological, deduplicated by source epoch, scope, and sequence;
- composed of stable headings, exact state words, content, and explicit numbered/named prompts;
- free of alternate-screen entry, cursor rewriting, animation, terminal hyperlinks, and terminal-control bytes other than newline record separators;
- compatible with `--ascii`, `--no-color`, `NO_COLOR`, and reduced motion;
- the screen-reader acceptance surface and targeted path, pending the Phase 5 VoiceOver and Orca workflow.

Every supported question, approval, lifecycle control, workflow gate, research action, and administrative confirmation must have a deterministic line command or numbered prompt. Plain mode is not a passive log viewer. The full-screen TUI has no semantic accessibility tree and must not be described as screen-reader accessible.

One owned `Plain.Session` serializes DataSource deliveries, complete stdin lines, prompts, and stdout/stderr records. It never allows concurrent writers or partial-record interleaving. Content/events and prompt re-emission use stdout; static-safe parse/diagnostic messages use stderr. Async output is emitted in source sequence/order, then the still-current prompt is re-emitted. Simultaneous completion and question arrival follow the runtime's single ingress order.

Prompt grammar is stable and scoped: `PROMPT <scope>/<id>@<revision> ...`. Commands include `answer <id>@<revision> <option>`, `approve|deny <id>@<revision>`, `pause|continue|resume|stop <run-id>`, `back`, `help`, and `detach`; later parity tasks add their closed forms. A bare number is accepted only when exactly one current unresolved numbered prompt has been emitted and its revision still matches. Otherwise it prints a correction containing the full non-secret command and preserves the prompt/editor state.

Resolution by another client emits a settled record, invalidates that prompt, and re-emits the next prompt if one exists. Invalid/overlong input, rejected/deadline/interrupted/conflict/outcome-unknown settlement, and an unknown command preserve state and recover at a fresh prompt. EOF and Ctrl+C perform orderly client detach, never domain Stop. Input buffering, output records, prompt registry, and diagnostic strings are count/byte bounded without dropping canonical deliveries.

`--no-alt-screen` remains an interactive full-screen renderer option that preserves pre-existing main-screen scrollback and leaves the final/restoration frame there. It does not promise append-only history for every redraw and is distinct from plain mode.

## 15. Deterministic fake three-run scenario

The fake DataSource uses canonical fixed UUIDs, a fixed virtual clock, explicit barriers, deterministic keyset cursors, and no sleeps.

### 15.1 Initial state

Open a global Activity watch and conversation-A workspace watch. Their ready snapshots contain:

- A1, a chat run in conversation A, running;
- A2, a swarm run in conversation A, running;
- B1, a standalone research run associated with conversation B, running;
- Main at bottom;
- no open modal;
- zero unseen items.

### 15.2 Interaction script

1. In conversation A, type `Review authentication`, insert a newline with `Ctrl+O`, then type `and its tests`.
2. Move the editor cursor and create a nonempty selection.
3. Scroll Main to logical anchor `{message-A-2, line 3}`; Main detaches.
4. Advance the fake. A1 emits node update, assistant-text append, reasoning append, and run update in that order. A2 creates revision-7 question Q1 and becomes waiting. B1 appends report text and advances progress. Global counts become two running and one waiting.
5. Navigate to conversation B. The reducer increments A's view generation before emitting cancel/unwatch. Deliver a deliberately late A response and assert that it changes no state.
6. Open B1 in Inspector, move selection, scroll Inspector away from bottom, and record its independent anchor.
7. Open Activity Center and select Q1. While its dialog is focused, advance A1 and B1 again; modal focus, option selection, drafts, and both scroll anchors remain exact.
8. Choose option 2. Assert one command effect containing A2 run/node/interaction IDs, expected interaction revision 7, current command generation, and the fixed request UUID.
9. The fake returns accepted and then emits Q1-resolved and A2-running events. The dialog becomes settled, closes once on the next close action, and restores the Activity-row opener.
10. Create a separate draft in conversation B.
11. Resize `160x50` to `80x24`, then to `50x14`, then back to `160x50`. Inspector selection/anchor and both drafts remain exact; `50x14` exposes the compressed survival UI without destructive actions.
12. Return to conversation A. A new ready snapshot includes all intervening canonical events. Assert exact multiline text, cursor, selection, chips, attachments, and height; exact Main anchor; exact deduplicated unseen-item count; and correct A1, A2, and B1 states.
13. Press `End`. Main follow becomes true and unseen becomes empty. Inspector follow remains unchanged.
14. Close the client. Assert only view cancel, unwatch, timer cancellation, DataSource close, renderer shutdown, and detach effects occurred; no domain Stop command occurred.
15. Start a new client against the continuing fake source and recover all three run states from ready snapshots. No claim is made that the unsent process-local drafts survived this new process.

### 15.3 Required scenario assertions

- no stale response is applied;
- no event is lost or reordered;
- no async event changes focus, editor cursor, selection, draft, layout preference, or logical anchor;
- Q1 is resolved once using its expected revision;
- visible new-item count deduplicates repeated changes to the same stable item;
- responsive changes preserve state;
- detach does not imply run cancellation;
- Scene output contains only sanitized spans and opaque action IDs.

### 15.4 Curated state and Activity fixtures

A compact state-catalogue fixture covers connecting, empty, loading older, running, streaming, queued, waiting-question, waiting-approval, paused, retrying, done, failed-with-retry, stopped, interrupted-with-resume, stale, resyncing, disconnected, superseded, and mutation-pending using the exact display catalogue in section 14.2.

A separate Activity fixture contains at least three unresolved items across different conversations: two questions with distinct urgency/deadlines and one approval, plus running/paused work, one recent failure, and one completion. Needs-you is oldest-deadline then oldest-created then stable ID; later categories use the fixed section-12 ordering. Async updates retain the selected stable ID, Small collapses Needs-you to a count/action, and Back restores the exact prior destination, region/item focus, selection, and anchors.

## 16. ExRatatui 0.13.0 four-target go/no-go

The spike pins `{:ex_ratatui, "== 0.13.0"}` and records the resolved lock entry. It builds a fake-only target-native Mix release with bundled ERTS. It does not use Burrito as its production proof and does not touch user data.

### 16.1 Target matrix

| Gate | macOS 14 arm64 | macOS 14 x86_64 | Ubuntu 22.04 arm64 | Ubuntu 22.04 x86_64 |
|---|---|---|---|---|
| Exact dependency pin and adapter-only references | Pass required | Pass required | Pass required | Pass required |
| Native build and correct NIF architecture | Pass required | Pass required | Pass required | Pass required |
| `otool`/`ldd`, RPATH, and glibc/shared-library inspection | Pass required | Pass required | Pass required | Pass required |
| Clean offline release boot without Erlang, Elixir, Rust, compiler, or unrecorded system NIF library | Pass required | Pass required | Pass required | Pass required |
| Chat/composer, swarm, consensus, and research representative scenes | Pass required | Pass required | Pass required | Pass required |
| Sustained typing, repeated bracketed paste, Unicode editor, resize, focus, repeat, and optional mouse | Pass required | Pass required | Pass required | Pass required |
| PTY lifecycle restoration and suspend/continue | Pass required | Pass required | Pass required | Pass required |
| Property/fuzz corpus and source-built sanitizer run | Pass required | Pass required | Pass required | Pass required |
| Deterministic three-run scenario and 30-minute resource soak | Pass required | Pass required | Pass required | Pass required |
| Frame latency, input latency, idle CPU, and bounded caches/mailboxes | Pass required | Pass required | Pass required | Pass required |

Acceptance uses native hardware or a native VM for the target architecture. Rosetta and QEMU may provide diagnostics but cannot supply a passing target result.

### 16.2 Input and Unicode gates

- No lost or duplicated bytes across 10,000 normalized key events and 100 repeated bounded bracketed-paste fixtures.
- Composer cursor and selection remain correct after every paste and resize.
- Fixtures cover composed/decomposed accents, Georgian, Arabic/Hebrew, CJK, ambiguous-width symbols, skin-tone emoji, flags, family/occupation ZWJ sequences, and VS15/VS16. The same ambiguous fixture passes editor, projector, Scene, cell capture, and PTY cursor assertions under both explicit policies; RTL editing remains logical-grapheme order and asserts visible caret/selection cell edges.
- Option/Alt, Shift+Tab, key repeat, focus events, and enhanced-key fallback behave deterministically.
- Mouse is disabled by default; when enabled, click/drag/wheel work without removing keyboard equivalents.

### 16.3 Lifecycle gates

On each target, execute a 1,000-cycle PTY suite: 200 normal exits, 200 renderer callback errors, 200 SIGINT exits, 200 SIGTERM exits, and 200 SIGTSTP/SIGCONT cycles followed by exit. Assert exact `stty -g`, cursor visibility, alternate-screen exit, bracketed-paste/focus/mouse disablement, and a sentinel on the restored main screen.

The external launcher owns HUP/INT/TERM/TSTP/CONT/SIGUSR1 traps. The child traps only supported SIGUSR2 for launcher control and never installs unsupported child SIGINT/SIGCONT or a TSTP trap. A child suspend request is a bounded validated FIFO record followed by SIGUSR1 to the exact launcher. Child request and external TSTP enter the same non-recursive control path: ordinary `suspend` record, matching `restored`, SIGSTOP exact child, then SIGSTOP exact launcher. After external SIGCONT resumes the launcher, it sends SIGCONT to the exact child, then `resume`, and waits for `ready`. This never forwards TSTP, resets a disposition to self-signal, or relies on orphan-group job control in an isolated `setsid` PTY.

Also verify initialization failure after every terminal-mode transition, non-TTY automatic plain selection without a hang, no TUI logs on stdout, a single terminal owner, SIGHUP client-only closure, and settlement of every timer/request/subscription. SIGKILL cannot be repaired by an in-process renderer and must be documented with `reset`/`stty sane` recovery rather than falsely claimed as restorable.

### 16.4 Performance and resource gates

- Representative `120x40` frame render is at most 16 ms p95 on the recorded pinned baseline hardware.
- Input-to-painted-frame is at most 50 ms p95 while all three fake runs update.
- Idle CPU is at most two percent of one core after warm-up.
- There is no unconditional 60 FPS redraw; active motion is capped near 15-30 FPS and absent in reduced-motion mode.
- A resize/event storm remains responsive and within bounded queues.
- A 30-minute soak has no monotonic mailbox, heap, ETS, timer, monitor, or native-resource growth after warm-up and GC.
- A 10,000-message fixture encodes only the visible window and bounded overscan; cache use remains within the configured byte limit and eviction causes exact recomputation.
- Exact final content hashes match the fake source; performance is never obtained by dropping semantic content.

### 16.5 Terminal coverage

- tmux and SSH-launched shells on all targets;
- Terminal.app, iTerm2, Ghostty, and Kitty on macOS;
- GNOME Terminal and Kitty on Ubuntu;
- truecolor, 256-color, 16-color, monochrome, ASCII, reduced-motion, alternate-screen, and no-alt-screen paths.

### 16.6 Rejection rules

Reject ExRatatui rather than rationalizing any of these:

- one reproducible BEAM crash, native memory-safety failure, abort, or non-cancellable NIF hang from valid bounded input;
- a supported target requiring an end-user compiler or unrecorded shared library;
- persistent lost/duplicated input, paste loss, or terminal corruption after one focused fix cycle;
- inability to edit the complete Unicode fixture set correctly;
- p95 frame/input failure after visible-windowing and redraw coalescing;
- inability to test exact cells, styles, focus, and cursor;
- renderer types or state leaking outside the adapter;
- upstream/API churn that cannot be contained by the adapter and exact pin.

A three-of-four target result is rejection, not partial adoption.

The default fallback for native policy, packaging, or BEAM-safety failure is TermUI after its Unicode-width and paste/focus gate. A supervised Ratatui OS-process sidecar is chosen only when in-process NIF isolation is the sole failed dimension and the Ratatui rendering/input proof passed every other gate. Both reuse the same Scene, Input, Action, Reducer, Effect, and DataSource contracts.

Missing Apple credentials leave signing/notarization pending; they cannot be recorded as passed or used for production Mac wording. A renderer-specific nested-signing incompatibility is a packaging failure.

## 17. Exact test contract

### 17.1 Golden cells

Goldens record every cell's character, foreground, background, modifiers, wide-cell continuation state, cursor row/column/visibility, focused region, and action IDs. Text-only snapshots are insufficient.

The minimum renderer-spike set is:

- four representative scenes multiplied by `80x24`, `120x40`, and `160x50`, multiplied by truecolor, 256-color, 16-color, and monochrome: 48 frames;
- workspace shell at `170x34`, `50x16`, and `50x14`, multiplied by the four color modes: 12 frames;
- `49x13` Too-small monochrome/ASCII: one frame;
- every representative scene at `80x24` monochrome/ASCII: four frames;
- question dialog and destructive confirmation at `120x40` in truecolor and monochrome: four frames.
- eighteen curated high-risk frames, without Cartesian expansion:
  - `workspace--50x14--monochrome--ascii` and `workspace--120x40--truecolor--reduced-motion-active`;
  - question and destructive-confirmation at `80x24`, plus both at `50x16` monochrome/ASCII;
  - Medium `100x24` with Navigator docked and with Inspector docked;
  - Narrow long ASCII/CJK/RTL project, branch, conversation, model, target, and filename elision;
  - the same `80x24` workspace with Main focus and Composer focus;
  - resync/retry, mutation-pending, mutation-conflict, disabled-reason, and Small Needs-you-overflow scenes;
  - one ambiguous-character cursor scene under `:narrow` and the same scene under `:wide`.

The total is exactly 87 frames. Each manifest entry includes a closed semantic intent and required assertion tags such as `no_send`, `focus_visible`, `sticky_footer`, `static_progress`, `full_value_in_inspector`, or `pending_disables_action`; stable but semantically wrong output is rejected. Component-cell fixtures and structural tests cover additional permutations without multiplying full frames.

All IDs, clocks, elapsed labels, prices, stream chunks, selections, and cursors are fixed fixtures. Boundary property tests cover one cell above and below every width and height threshold.

### 17.2 Reducer tests

Required reducer tests cover:

- subscribe acknowledgement, ready snapshot, and contiguous delta ordering;
- bounded pre-snapshot buffering;
- a sequence gap emits one resync and preserves presentation state;
- stale source epoch, watch, generation, revision, request, and duplicate sequence rejection;
- navigation invalidates before cancellation;
- an offscreen durable command response settles only its originating draft;
- async changes cannot alter focus, draft, selection, or logical anchors;
- independent Main/Inspector follow, detach, deduplicated unseen count, and rejoin;
- prepended page and resize anchor preservation;
- one deduplicated edge-page request, loading/error/retry/closed/resync sentinels, and no repeat-key request duplication;
- off-window versus confirmed-removal handling and successor/predecessor/empty focus-anchor repair;
- focus hiding/restoration at every breakpoint;
- complete focus-graph traversal, terminal focus loss/gain semantics, modal trap, safest default, single Escape, Back, and opener restoration;
- no double activation across input-context priority;
- activation on press only, bounded edit/move/scroll repeats, inert releases, and duplicate-disabled pending mutation;
- paste never submits;
- Ctrl+O always inserts newline;
- Shift+Enter follows enhanced-key capability;
- Alt+Enter and `/queue` produce identical queue intent;
- accepted clears only the originating draft and all other outcomes preserve it;
- server compare-and-set conflict refreshes instead of claiming local success;
- switcher/filter/Other `FieldKey` isolation, paste/IME routing, deterministic ranking/no-results, and selection repair under async patches;
- exact layout nudge/reset/preset and composer-height actions at every clamp;
- hidden and reduced-motion scenes own no animation timer;
- the complete deterministic three-run scenario.

### 17.3 Sanitization and plain tests

Required fixtures cover complete and partial CSI/OSC/DCS/APC/PM sequences, CR/backspace spoofing, bidi and zero-width filename spoofing, invalid UTF-8, the Unicode editor corpus, URL credentials, and terminal-title text. Every plain stdout/stderr fixture is scanned to ensure no terminal control survives other than newline record separators.

Plain tests verify chronological deduplication by epoch/scope/sequence, serialized complete records, scoped prompt ID/revision grammar, bare-number ambiguity rejection, prompt re-emission after async output, simultaneous completion/question order, other-client settlement, invalid/overlong recovery, EOF/Ctrl+C detach, stdout/stderr ordering, ASCII, `NO_COLOR`, reduced motion, non-TTY selection, and identical typed command outcomes.

### 17.4 Lifecycle and architecture tests

- Only renderer adapter paths may reference ExRatatui, Ratatui, or Rustler resource types.
- Neutral UI modules may depend on `swarm_code_core` protocol contracts but not `swarm_code_daemon` modules.
- Renderer callback failure restores the terminal before propagating a safe error.
- Terminal output and logs use separate destinations.
- Client close emits no run Stop unless the user explicitly chose Stop.
- Tests synchronize through PTY readiness messages, monitors, barriers, and virtual clocks, never sleeps or liveness polling.

## 18. Full-parity missing-surface traceability matrix

The matrix distinguishes evidence supplied by the initial spike from work required before a full release. Phase numbers match the approved architecture.

| ID | Approved parity surface | Initial spike evidence | Required release representation and behavior | Phase and objective gate |
|---|---|---|---|---|
| TUI-01 | Global shell and primary destinations | Responsive shell, switcher, Activity fixture | Chats, Scheduled, Workflows, Research, Usage, and Settings; aggregate counts; stable title/status; every destination reachable in at most three actions | Phase 2 shell gate, completed across keyboard and plain navigation |
| TUI-02 | Projects and No project | Static Navigator rows | Add/edit/delete project, validated path, No-project scratch scope, move conversation when safe, pin/fold/search/status, branch/path, instructions and memory entry points | Phase 2 project/query gate; project operations persist and drafts survive switching |
| TUI-03 | Conversations and transcript | Fake conversation switch and representative cards | New/rename/delete/pin/search/seen; persistent chronological transcript; user prompt and launched run as one card; nested follow-ups once; exact stream/reasoning/tool order; keyset history | Phase 2 cross-repository transcript and ordering goldens |
| TUI-04 | Queue, prompt history, targeting, fork, edit/resend | Fake draft and command outcome | Ordered editable/removable queue rows, automatic headless drain, Ctrl+R history, explicit Reply/Steer/Revise, plain message never steers, faithful Fork, in-place supersession edit/resend | Phase 2 queue/target core followed by Phase 3 fork/edit parity fixtures |
| TUI-05 | Commands and custom workflows/commands | Static palette interaction | Built-ins, saved workflows, and project/global custom commands; exact prefix/word ranking; built-in before workflow before custom; scope labels; command-specific prompt hints | Phase 2 command-dispatch conformance; no UI-local precedence policy |
| TUI-06 | Six exclusive modes and one-shot actions | Visible fake mode and key route | Build, Plan, Goal, Ultra workflow orchestration, Workflow authoring, Consensus; Swarm, Review, Compact as actions; Deep Research as a separate background object; mode transitions and naming exact | Phase 2 exhaustive transition table; no action silently becomes a mode |
| TUI-07 | Models, efforts, approval mode, providers, search, and attachments | Compact control-strip and attachment metadata fixtures | Chat/swarm models and efforts, Consensus Planner/Judge/optional Implementer models/efforts/rounds/checks, provider/search status and forms, Read-only/Auto/Full Access, four PNG/JPEG/GIF/WebP images at six MB each, image-only send | Phase 2 composer/attachment gate and Phase 3 provider/search settings gate |
| TUI-08 | Questions, approvals, Needs you, and lifecycle controls | One fake revisioned question, Activity, Stop confirmation | One-to-four questions, recommended options, multi-select, Other, Back, Skip, Next/Submit, deadlines; Approve/Deny/Always with exact scope; Pause/Continue/Resume/Stop/Stop-agent/Retry; global Needs-you | Phase 2 real-daemon three-run/CAS gate; controls match server `allowed_actions` |
| TUI-09 | Goals, Plan, and Compact | Plan and neutral compact representative blocks only | Multiple scoped goals and Ask/Steer; finished Plan Approve to Assistant/Swarm, Revise, Decline, settled implementation link; visible compact history floor and measured token change | Phase 3 persisted goal/plan/compact cross-repository fixtures |
| TUI-10 | Swarm agents, operations, Timeline, and Changes | Fake agent tree and operation row | Recursive tree and queue, Tree/Flat and Full/Compact, prompts/results/errors, Timeline All/run plus filters/zoom/Inspector, per-agent file tree/diff, changed-file chips | Phase 3 viewport/detail goldens; every full detail demand-loaded without loss |
| TUI-11 | Files, Git, checkpoints, worktrees, branches, merge/discard/PR | Sanitized file/diff fixtures | Exact tool status and approval scope, checkpoint/rewind, owned worktree/branch state, commit, merge, discard, Create PR, scoped revert/open/copy; no client-side Git execution | Phase 3 server-authorized security and ownership suite |
| TUI-12 | Consensus | Static Docket/Ticker/ledger across widths | Planner/Judge/optional Implementer, one-to-three rounds, all configured checks, plan/verdict/findings/disposition, code-grounded judging, user gate, Spec/Implement/Changes, post-change judge | Phase 3 engine-to-Docket/Ticker/ledger fact-equivalence suite |
| TUI-13 | Workflows and Ultra | Static pipeline scene | Runs and Library; built-in/project/user scope; args; Pipeline/Script/Journal/Result; phase/panel/agent budget; structured output; logs/gates/pause/resume/stop/replay; source edit/check/shape/run/duplicate/save/delete; built-ins; Ultra continuation | Phase 3 journal/replay and keyboard/plain end-to-end suite |
| TUI-14 | Standalone Deep Research | Static report/source scene and fake B1 | Launch question/project/model/effort; Fastest `1x4`, Medium `2x3`, High `3x4`, Ultra `4x10`; filters/pin; rounds/agents/sources/stats/state/report/TOC/notes; Stop/Retry/model retry/Copy/Open/Download/Continue/Reveal | Phase 3 research persistence/report/action suite; background navigation never cancels work |
| TUI-15 | MCP | Sanitized status fixture | stdio/HTTP CRUD, env/header secret masking, trust after import/change, scope, discovery, tool list, calls, reconnect, typed deadlines/errors | Phase 3 MCP protocol, redaction, and reconnect suite; untrusted annotations never create permission |
| TUI-16 | Scheduled automation | Activity row concept | Chat/Swarm/Workflow task CRUD, project, Build/Plan, model/effort, prompt/workflow args, once/daily/weekly/monthly/cron, timezone/DST, catch-up, run now/pause/edit/delete, occurrence history, month and agenda | Phase 4 exactly-once occurrence/restart gate; agenda default at narrow width |
| TUI-17 | Usage, pricing, budget | Title cost fixture | Periods, spend/budget headline, full Date/Project/Conversation/Model/Kind/Tokens/Cost records, pricing configuration, informational budget | Phase 4 fixed-database total and responsive-record goldens |
| TUI-18 | Settings, storage, memory, commands, and administration | Theme/capability and draft primitives | General, Deep research, Appearance, Providers & models, Pricing, MCP servers, Memory, Storage, Commands, Limits, Budget; validation/dirty merge/save notices; cleanup preview/progress/skips/retention/VACUUM | Phase 4 all-eleven-section dirty-form and reversible/destructive-action suite |
| TUI-19 | Notifications and service onboarding | Activity and opt-in bell effect | Durable in-app events, optional Needs-you bell, native waiting/finished/scheduled/error notifications, explicit launchd/systemd-user enable/disable/remove preserving data | Phase 4 service/restart and notification-preference gate |
| TUI-20 | Screen-reader-targeted/degraded and headless surfaces | Plain, ASCII, no-color, reduced-motion contract | Complete line-command coverage, no-alt-screen, stable human output, versioned NDJSON, detail fetching, diagnostics on stderr, detach/wait, distinct rejected/failed/interrupted/outcome-unknown exits | Phase 2 plain vertical slice, completed through Phases 3-5; VoiceOver/Orca acceptance |
| TUI-21 | Terminal visual identity and responsiveness | Carbon semantic palette and five operational density bands | Every extracted theme/light-dark catalogue entry, status word/glyph/color, page-specific collapse rules, no whole-screen horizontal scroll, exact focus at all supported sizes | Full-release golden and focus-graph matrix |
| TUI-22 | Public distribution | Four-target fake release viability only | Four immutable runtime archives, bundled ERTS, link/RPATH/glibc inspection, signatures/provenance/SBOM, Mac signing/notarization, installer/update/rollback/uninstall/offline tests | Phase 5 artifact gate; renderer feasibility alone gives no release claim |

Full parity is reached only when every row has implementation evidence and automated acceptance. GUI-specific mechanisms such as hover, SVG scales, drag/drop plumbing, native folder-picker pixels, CSS motion, web calendar geometry, and embedded designed HTML are replaced by the documented terminal-native action menu, textual ledger, path completion, agenda, and explicit open/download behavior rather than silently omitted.

## 19. Prioritized UI/UX improvements beyond the initial slice

### Priority 1: trust, continuity, and discoverability

1. **Activity Center with return context.** Opening an interaction from another conversation records destination, focus, selection, and anchor. After settlement, Back returns exactly there.
2. **Server-explained actions.** Hide impossible actions. Temporarily disabled actions display the server-provided safe reason, such as a current indivisible step or an active run preventing project movement.
3. **Scoped recovery banners.** Disconnect/resync marks affected content stale, preserves it and all editing, and offers Retry/Diagnostics without replacing the screen with a spinner.
4. **Contextual keyboard help.** Wide/XL status shows the most relevant three-to-five bindings and narrower classes follow section 11's smaller budget. `?` opens the complete region/action map. Action menus expose every mnemonic.
5. **Mode clarity.** The one-of-six mode is visible in title and composer. Research depth is labeled `Research: Ultra (4x10)`, never merely `Ultra`.

### Priority 2: efficient dense-data navigation

6. **Progressive run-card disclosure.** Folded cards retain exact state, Needs-you, error, unread, and progress. Lower-priority metadata moves to Inspector before truncation.
7. **Unified search and jump language.** Switcher prefixes, transcript turn/run/error jumps, Timeline errors, workflow phases, research sources, and settings search share consistent navigation and Back behavior.
8. **Inspector continuity.** Thread, Agents, Timeline, and Changes retain independent tab, filter, selection, follow, and anchor state.
9. **Explicit detail loading.** A detail row shows available size/type, Loading, retryable failure, and exact truncation/source state. Full text remains searchable and copyable after demand loading.
10. **Quiet live status.** Update only changed regions and displayed time units. Completion enters Activity without focus theft or forced navigation.

### Priority 3: safe editing and forms

11. **Dirty-form merge discipline.** Settings, schedules, workflow source, and research launch forms accept unrelated server patches while retaining dirty values; revision conflicts show baseline/current/user values rather than choosing silently.
12. **Safe mutation feedback.** Mutations visibly progress through pending and an approved outcome. Destructive dialogs retain Cancel as default. Outcome unknown is never displayed as success.
13. **Attachment staging.** Show type, dimensions, size, validation, upload/admission, and removal as metadata chips. File bytes stay outside reducer state.
14. **External editor handoff.** Workflow, memory, command, and instruction editing may use a full-screen renderer buffer or explicit `$EDITOR` handoff through an owned, capability-gated process; return performs baseline/hash conflict detection.

### Priority 4: surface-specific responsive quality

15. **Consensus density equivalence.** Docket, Ticker, and ledger expose the same round/check/stage facts rather than independent approximations.
16. **Research reading order.** Narrow layouts show state, report/notes, then sources; timeline becomes Inspector rather than squeezing text.
17. **Workflow list/detail/editor modes.** Narrow terminals show one purposeful surface at a time with breadcrumbs and preserved selection.
18. **Settings master/detail.** Searchable section list and one detail form replace a long card dashboard; dirty state is visible beside section names.
19. **Agenda-first schedules.** Below the calendar threshold, preserve every schedule field and occurrence through an agenda rather than a compressed seven-column grid.
20. **Labeled usage records.** Narrow usage views retain every table field as labeled rows instead of horizontal scrolling.

### Priority 5: degraded-mode equivalence

21. **Plain command parity.** Questions, approvals, run control, workflow gates, research controls, schedule confirmation, storage review, and settings save all have deterministic text routes.
22. **No-color focus.** Focus remains visible through reverse/underline/borders and explicit `FOCUS`/selection cues where terminal attributes are unavailable.
23. **Notification restraint.** Bell is limited to Needs-you and is opt-in; all completions/errors remain in the durable Activity list.

These improvements adapt the existing product intent. They do not introduce new autonomous behavior, hidden policy, automatic compaction, implicit steering, or additional persistent modes.

## 20. Daemon prerequisites for a real IPC DataSource

The fake-backed contract and renderer spike may proceed without these items. A real workspace may not claim readiness until the daemon provides:

1. owner-only Unix-socket listener/client lifecycle, peer UID authentication, nonce handshake, compatibility negotiation, and reconnect behavior;
2. strict versioned body schemas for every request, response, event, and error operation; the current generic envelope/body bound is not sufficient;
3. `CommandDispatcher` and `ConversationCoordinator` with headless queue draining;
4. stable idempotent command UUIDs and all four approved outcomes;
5. server-scoped Pause, Continue, Resume, Stop, Stop-agent, Steer, Answer, and Approval commands with interaction-revision compare-and-set;
6. page-limited shell, project, conversation, workspace, transcript, run-detail, Activity, and pending-interaction DTOs with stable keyset cursors;
7. explicit detail queries for large text, reasoning, logs, tool results, diffs, workflow source/journal, reports, and sources;
8. subscribe acknowledgement, snapshot `through_sequence`, per-scope revision/sequence, unsubscribe, and `snapshot_required` semantics;
9. global Activity/pending-interaction subscription alongside current conversation and run subscriptions;
10. exact stream attempt/reset and node-to-text-to-reasoning-to-run terminal ordering;
11. typed static-safe errors containing code, affected scope, retryability, and corrective action;
12. bounded request/event queues, cancellation settlement, and pressure behavior that never drops canonical content;
13. server-provided `allowed_actions` and safe disabled reasons;
14. proof that secret values cannot enter any presentation DTO, event, error, log, or terminal field.

The IPC DataSource must pass the same conformance suite as the fake implementation. The UI does not compensate for a missing daemon guarantee with polling or local policy.

## 21. Delivery sequence and objective gates

### 21.1 Contract and fake interaction plan

1. Establish neutral types, renderer/DataSource behaviors, and architecture guards.
2. Implement SafeText, terminal capabilities, semantic palette, and adversarial fixtures.
3. Implement the virtual-clock fake DataSource and watch synchronization contract.
4. Implement reducer state, generations, effects, editor, drafts, focus, modals, and scroll anchors through tests.
5. Implement Scene projection and all responsive shell classes.
6. Complete switcher, Activity Center, question dialog, and deterministic three-run scenario.
7. Implement the permanent owned, serialized plain line session and presenter.

This sequence produces no canonical-data or real-daemon UI.

### 21.2 Renderer selection gate

1. Add the exact ExRatatui 0.13.0 adapter within its isolated boundary.
2. Produce the full golden-cell set.
3. Pass input, Unicode, lifecycle, fuzz/sanitizer, performance, soak, and terminal coverage.
4. Build and boot native Mix releases on all four targets.
5. Record one outcome: adopt ExRatatui, select TermUI fallback, or select the Ratatui sidecar under its narrow condition.

No renderer is promoted on incomplete target evidence.

### 21.3 Phase 1 daemon/headless readiness gate

- Strict operation/body schemas exist for every required command/query/event.
- Subscribe-before-snapshot, contiguous sequences, gap resync, and slow-client behavior pass.
- Command outcomes and typed errors are complete.
- Initial DTOs are page-limited and secret-free.
- Three daemon-owned deterministic runs survive client disconnect/reconnect.
- Queue drains with no client.
- Client close leaves no client-owned waiters and does not stop runs.

### 21.4 Phase 2 real terminal workspace gate

- Run the three-concurrent-run scenario against daemon IPC, SQLite, and deterministic fake providers rather than `UI.DataSource.Fake`.
- Kill and reconnect the TUI; all three run states and exact final bytes recover.
- Project/No project, conversation navigation, transcript, composer, six modes, commands, queue, attachments, questions, approvals, and lifecycle controls work.
- Every primary destination is keyboard-reachable in at most three actions.
- Navigation, async patches, resync, and resize preserve drafts, focus, selection, expansion, and logical anchors.
- Native macOS and Ubuntu PTY suites, reducer tests, cell goldens, plain tests, and performance limits pass.
- No renderer or daemon implementation type appears in neutral modules.

### 21.5 Phase 3 complex-parity gate

- Cross-repository goldens cover goals, edit/resend, fork, rewind, compact, Plan gate, Consensus, workflows, research, MCP, Timeline/Changes, checkpoints, and worktrees.
- Normalized provider requests, persisted rows, event order, workflow journals, research reports, and final visible bytes match their approved fixtures.
- Consensus exposes every role, check, round, disposition, gate, and implementation stage at every density.
- Workflow Script/Journal/Result and all gates work in TUI and plain mode.
- Research exposes every level, statistic, source, round, report action, and attach/continue path.
- Every large detail remains lossless and searchable through demand loading.
- Security tests prove external content cannot create terminal controls or trusted approval chrome.
- Stop/cancel/crash leaves no UI- or domain-owned descendant.

### 21.6 Phase 4 durable-background and administration gate

- Schedules fire exactly once across restart, catch-up, and paused/waiting workflow states.
- launchd/systemd-user onboarding and removal are explicit and preserve data.
- All eleven settings sections pass dirty-form, conflict, validation, save, and credential-lock tests.
- Usage/pricing/budget totals match fixed database fixtures.
- Storage preview, progress, skip reasons, cleanup equations, retention, and VACUUM safeguards pass.
- Notifications remain supplementary to durable Activity/plain visibility.

### 21.7 Phase 5 full-release gate

- Every row in the full-parity traceability matrix has implementation and automated-test evidence; no non-GUI row remains unsupported.
- Every GUI-specific behavior has an explicit terminal-native adaptation.
- Each primary surface has XL, Wide, Medium, Narrow, and Small truecolor and monochrome goldens; critical surfaces also cover 256-color, 16-color, ASCII, and reduced motion.
- Automated focus traversal proves every enabled action keyboard-reachable and proves hidden controls cannot receive input.
- VoiceOver and Orca pass the complete plain workflow suite.
- `--plain`, `--no-alt-screen`, ASCII, `NO_COLOR`, reduced motion, tmux, SSH, and supported emulator smoke matrices pass.
- All four runtime-only artifacts boot offline without developer runtimes or downloads.
- Installer, update, rollback, uninstall, signature/provenance, and Mac signing/notarization gates pass.

Full parity is a closed traceability and behavioral-testing claim. Selecting ExRatatui or producing attractive fake goldens does not satisfy it.

## 22. Contract consistency rules

- Scene and Action are renderer-neutral; DataSource and DTOs are daemon-implementation-neutral.
- The renderer draws and normalizes input only.
- The reducer owns presentation state only and is pure.
- Effects are declarative, owned, bounded, and settled.
- Domain commands are server-authorized and server-validated.
- Subscribe-before-snapshot and generation checks prevent stale cross-scope updates.
- Draft, focus, and logical scroll preservation are independent of canonical data updates.
- Rendering and plain output share sanitization but not cursor-oriented presentation.
- Plain mode is the screen-reader acceptance surface/targeted path; a proven accessibility claim waits for the Phase 5 VoiceOver and Orca workflow. The full-screen cell UI has no such claim.
- The exact renderer pin and native release matrix are feasibility gates; full release parity requires all later surfaces and daemon guarantees.
- No requirement in this document permits dropping canonical content, increasing polling to hide an ownership problem, creating atoms from input, or executing domain work inside the TUI.
