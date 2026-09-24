# Pass 72, owner O (agent overlay, hint keys): notes

Branch `p72/O`, worktree `/Users/zaali/dev/swarm-code-cli-wt/p72-O`. Merged into it: `p72-S-wire`,
`p72-P-order`, and S commit `1a9e8a5` (agent detail, single-agent steer).

## Contract (what P, S and the finisher read)

### State fields (`SwarmCodeCLI.UI.State`)

| field | values | meaning |
| --- | --- | --- |
| `panel_mode` | `:full \| :compact \| :hidden`, default `:full` | P6. `Layout.for_state/1` (P) reads it. Set with `{:panel_mode, mode \| :cycle}`. `Init.panel_mode` seeds it; the preferences file overrides it once it has been read. |
| `hint` | `nil \| %{labels: %{label => target}, typed: binary}` | hint mode is on while this is not nil. `target` = `{:run, run_id}` or `{:agent, run_id, node_id}`. |
| `overlay` | `nil \| %{run_id, node_id, draft_key, focus: :band \| :activity \| :composer, raw_ops?, page, cursor, expanded, restore: %{scroll, draft}, detail, detail_request, detail_at}` | the agent overlay (P8). `State.current_draft_key/1` returns the overlay's `{conv, {:agent, node_id}}` while it is open, so the overlay has its own draft. |

### Functions and actions

- `SwarmCodeCLI.UI.Hint.labels(entries) :: %{label => target}`: pure. `entries` is
  `PanelOrder.entries/1`'s list (`{:run, id}` / `{:agent, run, node, needs_you?}`). Runs get
  `1`–`9` in panel order. Agents get letters from `s f g h j k l w e r t u i o p`: needs-you agents
  first, each group stable in panel order. Past 15 agents the labels are prefix-free two-letter
  ones, at most 225. The letters `y a Y A d D n q ?` are never used (property tested).
  `Hint.match/2` returns `{:target, t} | :prefix | :none`. `Hint.label_for/2` returns the label of
  a target, so **P draws a badge by calling `Hint.label_for(state.hint.labels, {:agent, run, node})`
  while `state.hint` is set**.
- `{:overlay_open, run_id, node_id}` is the local action that opens an agent's overlay. P's panel
  rows or band can carry it as a target. Enter with `selection["inspector"]` = an agent id also opens it.
- `SwarmCodeCLI.UI.Projector.Overlay.project(state, layout)` returns `nil`, or
  `{[%Region{id: "agent-overlay", role: :main}], cursor}` covering the whole screen.
- Effect `{:save_preferences, %{panel_mode: m}}`: `SessionRuntime` runs it as owned work (a
  `Task.async`, the latest request queued while one write runs). The file is
  `SwarmCodeCLI.Release.preferences_path/0` = `Path.join(SwarmCode.Domain.Paths.config_dir(),
  "cli.json")`, `{"panel": "full|compact|hidden"}`, mode 0600, same-directory atomic write, unknown
  keys kept. It is read at start by owned work, and the read loses to a change the user already made.
- Query `{:agent_detail, run, node}` (S) is asked on open, then refreshed on run news for that run
  (throttled to 2 s, one in flight). Stale answers are dropped.

### Keys

- `Ctrl-F` / `Ctrl-Space` start hint mode. `Ctrl-F` therefore leaves the composer's Emacs map
  (forward-char stays on `→`). The Rust port already delivers Ctrl-Space as NUL (`Key::Null` → `:null`),
  so no Rust change was needed.
- In hint mode: a digit jumps to a run, `0` opens the runs dashboard, letters open an agent's
  overlay, `Ctrl-F` again = `Ctrl-N` (next needing you), Backspace removes a typed letter, and Esc
  or any other key cancels.
- In the overlay:
  - Esc closes it and restores the chat's scroll and draft exactly (tested).
  - `[` `]` step through agents.
  - Tab / Shift-Tab move the focus ring (band, activity, composer). Under 120 columns the ring
    runs over pages instead.
  - `o` shows the raw operations.
  - Enter steers when the composer has text; otherwise it expands a group or opens the detail.
  - `y a Y A d D n` form the approval grammar. They work only while the overlay composer is empty and
    a request waits (`n` = the next agent that needs you).
  - Ctrl-C closes the overlay.
- `Ctrl-B` / `Alt-I` cycle the panel. At 120 columns or more the cycle is full → compact →
  hidden; below that it is hidden ↔ full.
- `/panel full|compact|hidden` sets the mode; `off`, `hide` and `none` also mean hidden.
- `docs/keybindings.md` is regenerated and `mix swarm_code.keymap --check` passes. The README keys
  section is updated.

## Requests for others

1. **P, `ui/projector.ex`** (your file, not changed on this branch). Add the overlay before the
   shell, so the shell under a full-screen overlay is not projected at all. The live big session
   repaints much faster this way:
   ```elixir
   {regions, cursor} =
     case SwarmCodeCLI.UI.Projector.Overlay.project(state, layout) do
       nil -> Shell.project(state, layout)
       covered -> covered
     end
   ```
   Without this the overlay's state and keys work, but nothing is drawn.
2. **P, `projector/dialog.ex:506`**: map `{:local, {:panel_mode, :cycle}}` (the new Ctrl-B action) to
   `:toggle_inspector` (it maps `{:local, {:toggle_dock, :inspector}}` today, which Ctrl-B no longer sends).
3. **P, the model's P3 state**: let a pending approval or question for the agent override S's
   default `panel_state: :working`. Hints and `n` already check pending interactions
   (`Reducer.Hint.needs_you?/2`), but P's ordering trusts `panel_state` alone.
4. **P**: draw the hint badges with `Hint.label_for/2` while `state.hint` is set (K2). Until then,
   hint mode works blind.
5. **Finisher**:
   - `persisted_session.ex` and the dev scripts should pass
     `preferences_path: SwarmCodeCLI.Release.preferences_path()` to `SessionRuntime`. Today only
     `SWARM_RELEASE_TUI=1` reads the file.
   - `rel/overlays/bin/swarmcode` help's keys line should add `Ctrl-F agents` and `Ctrl-B panel`,
     as in `Release` usage.

## Deviations

- `d` is never a hint label: it is the deny key in the approval grammar. The D2 mockups show a `d`
  badge; that badge becomes the next free letter.
- Plain output has no panel concept, so nothing changed there. Headless and release output carry the
  same keys: `Release` usage mentions Ctrl-F and Ctrl-B.

## Verification

- Focused tests:
  - `pass72_hint_test.exs` (properties: forbidden letters, prefix-free labels, needs-you first)
  - `pass72_overlay_keys_test.exs` (21 tests)
  - `pass72_preferences_test.exs` and `pass72_preferences_runtime_test.exs`
  - `bindings_test.exs` and `keymap_test.exs`
- Live, in the sandbox (GNU screen, two real prompts):
  - Hint letters open the right agent, with S's detail.
  - `]` steps; `o` lists the operations; a steer reaches one reviewer, whose next thought quotes it.
  - Esc restores the chat.
  - Ctrl-B writes `cli.json` at mode 0600, and compact survives a restart.
  - `/panel full` writes the file; narrow pages work.
- Screens in `/Users/zaali/.cache/p70cli/p72-O/`:
  - `ov1`–`ov5.png`: rendered overlay frames (wide, narrow, ASCII, needs-you band).
  - `s24.png`: live narrow pages.
  - `s28.png`: live overlay after a steer.
  - `s31.png`: chat after Esc.
- Full umbrella `mix test` (no `_build/prod`), run once:
  - core: 147 tests, 0 failures.
  - daemon: 972 tests, 7 failures. They are in lease/OS timing, grep backtracking, schema gate and
    env provider tests; O changed no daemon file.
  - cli: 1531 tests, 52 failures.
    - All but one reproduce on the `p72-P-order` tag itself (layout, inspector cards, golden scenes,
      request conformance's stop target, demo cells): P's panel is still in progress.
    - The one exception, `Plain.SessionTest`'s reader timing, passes alone.
  - An earlier run of the whole cli app, before P's tag was merged, had 0 failures.
- `mix swarm_code.keymap --check` passes and `mix format --check-formatted` is clean.

## Leftovers

- In the big live session, repaints lag several seconds (Esc took about 10–20 s to show). Request 1
  helps. The rest is the shell projector's cost, which is outside O.
