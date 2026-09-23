# pass70 owner D notes

Owner D: everything that is drawn. Branch `p70/D`, worktree
`/Users/zaali/dev/swarm-code-cli-wt/p70-D`. `p70-C-wire` merged (b5942da).

## Landed

| task | what | commits |
| --- | --- | --- |
| D2 | paint budget scales with the terminal (`Budget.node_limit/2`), `Demo.Conversation` fixtures, scene budget test at 250x70 on the 5-run and 7d01acff-shaped conversations | fc4b09c |
| D1 | conversation-shaped transcript (`Workspace.Turns` rewrite) | b235397 |
| D3 | `Projector.Markdown` + `Projector.Syntax`, code card with language chip | b235397 |
| D4 | one title/tab row, one status line, no deck rows, no ids, colour-only cues | b235397 |
| D5 | approval card above the draft, growing into main; modal fallback uses the same decisions | b235397, 1ef4482 |

(Table kept current as tasks land; see the sections below for D6–D8.)

## Contracts published

- `Projector.ApprovalCard` (new): `decisions/2` → `[{decision, key, words, target}]` with keys
  `y` `:approve`, `Y` `:approve_run`, `A` `:always_prefix` (or legacy `:always_allow`, worded
  "for this run" because C1 says the service reads it as approve_run), `d` `:deny`, `D`
  `:deny_stop`; `n` next is drawn only when more than one approval waits. Allowed set: the
  item's / approval's `allowed_decisions` when non-empty, else `allowed_actions`.
  `facts/1`, `title/2`, `layout/2` (`%{rows, growth, window: {first, shown, total}}`).
- `Composer.slot_interaction/1`, `Composer.waiting_approvals/1` (opened layer first, E's
  `dismissed_interactions` `{id, expected_revision}` excluded), `Composer.opened_approval/1`,
  `Composer.approval_decisions/2` (delegates to ApprovalCard).
- The opened `{:approval, id}` layer is **not a modal** when the layout has a composer: the card's
  keys are on the activity row right above the composer, the title/body/where grow into the bottom
  of main (≤ half of it), the draft stays visible. Focus ids `approve`, `approve_run`,
  `always_prefix`/`always_allow`, `deny`, `deny_stop` put that decision on the on-warn chip.
  Paging: `selection["dialog_scroll"]`; `Dialog.project/3` answers `Reducer.Pages.scroll_dialog`
  with the card's own window, so PgUp/PgDn/End page the card exactly.
- `Workspace.keyboard_actions/2`: everything that used to be a deck row (run controls, plan gate,
  interaction openers, the slot approval's decisions, "Full arguments", full-text openers, seen,
  page retry/diagnostics) is in the action table without a drawn control; the palette lists them.
  The paint invariant is now "painted ⊆ table and table − painted ⊆ keyboard actions".
- `Workspace.Turns`: `order/1` is daemon order grouped by run (the old rank sort is gone; the
  companion keeps its own reading rank), `view_runs/1`, `view_order/1`, `context/2`, `rows/4`,
  `height/3` (0 for an item of a run out of view), `viewport/3`, `clock/1`, `duration_text/1`,
  `compact/1`, `margin/0` (2), `body_column/0` (4). A worker's lane expands by the id of the
  worker's first item. The selection rail/highlight shows only when `focus == "main"`.
- Status row: `Status.waiting_count/1` counts every pending interaction of a non-superseded run.

## Contracts consumed

- C1 (`p70-C-wire`): `Approval.{command,cwd,reason,command_family,classification,agent_name,
  allowed_decisions,arguments_detail_ref}`, `WorkspaceSnapshot.{approval_mode,trusted,
  context_used,context_window,cost_usd,chat_model,swarm_model,project}`.
- E (read via `Map.get`, not yet merged here): `state.quit_live_runs` (quit question title),
  `state.dismissed_interactions`.

## Requests for other owners

- **E**: `Reducer.Pages.scroll/3` pages main over `order[:workspace]`; the view is
  `Turns.view_order/1` (grouped by run, superseded runs hidden, their items measure 0). Paging the
  view order instead would keep line scroll exact when runs interleave.
- **E**: status hints read `Bindings.hinted/1`; in the composer the second hint today is
  "Esc back out" — your E1 labels ("Esc interrupt", "? keys") will show up automatically.
- **E**: the approval card's keys are drawn from `ApprovalCard.decisions/2`, which filters by
  `ActionTarget.validate/1`: `:approve_run`, `:always_prefix` and `:deny_stop` appear once your
  widened `Intent` is merged.
- **C**: the transcript text preview is 2048 bytes in snapshots; the answer is shown whole only via
  the detail. A larger preview (or the full answer for the newest run) would let the transcript
  show real answers without a detail round trip.
- **B**: light mode needs a light palette in `UI.Theme` keyed off a capability (terminal background
  detection); D reads `Capabilities` only.

## Manifest-listed files edited

None (checked every edited path against `provenance/extracted-files.json` destinations).

## Verification

- `mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli` after each step; last run before
  this note: 1208 tests, 5 properties, 0 failures after the D5 card commit.
- PNGs rendered through `Paint` → SVG → PNG (`/private/tmp/p70cli/p70-D/shots/`), read and
  iterated: before-*.png (main before pass 70), v2/v3 (transcript, chrome), v5/v6 (approval card).

## Left

- D6 (diffs, stop/model chips, error cards with retry, trust banner, rate-limit countdown,
  background chip), D7 (palette/picker visuals, hive strip, narrow layouts, light mode), D8
  (gallery and golden scenes, companion fields).
