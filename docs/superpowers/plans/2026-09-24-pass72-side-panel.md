# Pass 72: the side agent panel, the agent overlay and hint keys (2026-09-24)

The owner approved a redesign of the right-hand side agent panel after using pass 70 on a real swarm
("absolutely stunning side agent panel", "sidebar should be just visual representation of what's going
on in main chat", "operations should not be displayed on the sidebar", "no side chat split: open in a temp
view, Escape closes it", "robust hotkeys to select from the side panel", "user should be able to choose
between compact and full"). Four designers drew directions, a principal designer critiqued them, and the
owner approved the implementation; this pass builds **direction D, "Constellation with a pulse"**.

Design sources (read before coding; they are the spec for everything visual), all in
`docs/superpowers/specs/2026-09-23-side-panel/`:

- `D2.html` — the 19 mockups of D. Read the `<pre class="term">` blocks; span classes map to `UI.Theme`
  roles: tp text_primary, tm text_muted, tf text_faint, tg text_ghost, bd border, ac accent, ok success,
  wa warning, er error, in info, gl run_goal, sw run_swarm, wf run_workflow, rs run_research,
  cj run_consensus_judge, ul run_ultra, ua ultra_a, l1–l5 agent_lane_1–5, b bold; backgrounds card, surf
  (surface), hov (hover), pop (popover); chips c-ac/c-ok/c-wa/c-er/c-in (the chip roles); key = the hint
  badge (#111111 on the accent). Frames (`data-mode`/`data-view`/`data-frame`): chat, swarm ×3, workflow,
  goal, plan, research, consensus (full); swarm compact; heavy full/compact/hint; swarm hint; overlay ×3;
  whole terminal; narrow.
- `critique.md` — sections 5 and 6: the rules R1–R17 and K1–K6 and the D recipe D1–D10. Binding.
- `owner-notes.md` — the bugs the owner saw and the four requirements.
- `A2.html`, `B2.html`, `C2.html` — reference only.
- `tools/vt.py` (replays a GNU screen `-L` raw log into `.txt` + `.svg` with true glyphs and colours) and
  `tools/svg2png.py` (SVG → PNG you can Read): `python3 tools/vt.py raw.log 160 45 out && python3
  tools/svg2png.py out.svg out.png`.

Rules for every owner: pass-70 plan sections 2–3 (decisions, never the real DB, scratch project copies,
commit trailer `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`, never push, never
`scripts/install.sh`), UI facts in `AGENTS.md` (`Width.cells` under both ambiguous-width policies for every
glyph, `UI.Theme` roles only, bindings only in `Keymap.Bindings`, never Ctrl-K, nothing essential on Alt).
**Scratch and sandboxes live under `/Users/zaali/.cache/p70cli/`, not `/tmp`** (a reboot wiped `/private/tmp`
on 2026-09-24). Sandbox recipe: `N=p72-<X>; SB=/Users/zaali/.cache/p70cli/$N/home; mkdir -p
/Users/zaali/.cache/p70cli/$N; cp -c -R /Users/zaali/.cache/p70cli/sandbox-home "$SB"; chmod 700 "$SB"
"$SB/Library" "$SB/Library/Caches" "$SB/Library/Application Support" "$SB/Library/Application Support/SwarmCode"`,
then `HOME=$SB SWARM_ENV_FILE=/Users/zaali/.secrets <worktree>/_build/prod/rel/swarm_code_cli/bin/swarmcode
<scratch project>` after `scripts/dev/build_release.sh` (delete `_build/prod` before the full test suite:
`ui/renderer/locked_branch_test`). The sandbox DB is a copy of the real one at 57 migrations. Scratch
project: `cp -c -R ~/dev/ailogic /Users/zaali/.cache/p70cli/$N/ailogic`. At most 8 real prompts per owner.
Worktrees `/Users/zaali/dev/swarm-code-cli-wt/p72-<X>`, branches `p72/<X>`, notes in
`docs/superpowers/plans/pass72-notes/<X>.md`.

## Decisions (final)

- P1 The panel shows per agent only: who, state (glyph + word), now (one sentence with a verb), elapsed,
  tokens · cost, what it produced (finding with file:line, or files changed), whether it needs you (R1).
  No operations, tool chips, worktree/branch names or ids anywhere in the panel.
- P2 One needs-you band pinned under the panel header: the literal request (command, edit path, or
  question), the reason, a count, oldest first, `^N answer`; absent when nothing waits (R3).
- P3 One state set everywhere: ● working, ◐ thinking, ◌ waiting on others, ! needs you, ✓ done, ✗ failed,
  ○ queued, ⏸ paused, each with an ASCII twin and its word (R9). Run marks only from `Theme.run_mark/1`.
- P4 The pulse lane: per agent, a rolling 60-second window built from stored operations, 12 cells in full
  and 8 in compact, one cell = 5 s, cell kind by the dominant activity: `▂` think, `▅` tools, `█` write,
  `▒` waiting on you, `·` idle (R7). Done agents drop the lane; the finding takes the row.
- P5 Honesty (R5): no ETA, no per-agent percent, no tokens/s, no `~N`, no estimated diff sizes, no stance
  axes. Gauges only for known ratios.
- P6 Modes: full (2 rows per agent), compact (1 row per agent, 8-cell lane, short names ≤ 8 cells, runs not
  in chat fold to an orbit line when rows overflow), hidden, and under 120 columns a one-row strip ending in
  `! N needs you ^N` (R15, R17, D5, D10). `Ctrl-B` cycles full → compact → hidden (strip → off when narrow);
  `/panel full|compact|hidden` sets it; the choice persists in a CLI preferences file
  (`Path.join(SwarmCode.Domain.Paths.config_dir(), "cli.json")`, 0600, atomic same-directory write;
  a missing or unreadable file means full, never a crash).
- P7 Hint mode: `Ctrl-F` (and `Ctrl-Space` where the terminal delivers NUL) shows a badge before each
  agent's state glyph (the glyph stays); needs-you agents get the first letters, then `s d f g h j k l`,
  then `w e r t u i o p`, then two-letter labels; never `y a Y A d D n q ?`. Digits 1–9 pick runs (0 opens
  the runs dashboard). `Ctrl-F` again = `Ctrl-N`. Esc cancels. Hint keys never answer a request (K1–K4).
  `Ctrl-F` leaves the composer's Emacs map (record it in the keymap table; forward-char stays on →).
- P8 The agent overlay (D8): a full-screen layer over the main area (not a split). Header with breadcrumb,
  state, neighbour rail `[ ‹ prev ●◐✓! next › ]` and meta; the needs-you band with the real grammar
  (`y`/`a` once, `Y` this run, `A` always the family, `d` deny, `D` deny + stop, `n` next; letters answer
  only while the composer is empty); the whole-life story lane; left column brief + why it asks + numbered
  findings (severity, file:line) or, for writers, the diff summary (Enter opens the diff pager); middle
  column the grouped activity (reads, searches with hit counts, thoughts quoted, commands with their last
  output line, edits with +/−; `o` shows raw operations; the agent's own words marked "said"); right column
  where it sits (mini tree), files read/searched/changed, tokens, context, budget only when set; bottom a
  composer that steers only this agent. `Esc` restores the chat scroll and draft; `[`/`]` step through
  agents in panel order and wrap; `Tab` cycles band → activity → composer. Under 120 columns the columns
  become Tab pages.
- P9 Transcript (D9): one line per sub-agent inside the lead's block with the same glyph, word and sentence
  as the panel. The spawn row and the lane row are one row. No "isolated in swarm/…" text; no ids.
- P10 The panel is a view of the chat: the run the transcript shows gets the accent `▌` and "in chat" (R4);
  selecting a run in the panel (digit in hint mode) scrolls the transcript to it.

## Owners

### Owner S: the data (daemon, wire, data source)

Files: `apps/swarm_code_daemon/**` (synced domain files only through the provenance patch mechanism),
`apps/swarm_code_core/**`, `apps/swarm_code_cli/lib/swarm_code_cli/ui/data_source/**`,
`ui/data_source.ex`, their tests.

Publish the contract first (tag `p72-S-wire` when it compiles with fake-data-source parity; P and O read
new fields with `Map.get` defaults until they merge it):

- Agent summary: `state` (the P3 atom), `now` (≤ 80 bytes, server-derived plain words: "reading
  lib/x.ex", "searching \"Escape\" in 9 files", "running mix test test/…", "editing lib/y.ex", "waiting on
  3 reviewers", or the first sentence of the latest reasoning summary when that is the latest activity),
  `lane` (12 atoms for the last 60 s, newest last, from operation kinds and timestamps), `finding`
  (≤ 160 bytes: first sentence of the agent's result, else nil) and `finding_refs` (≤ 5 `path:line` parsed
  from the result), `files_changed`, `elapsed_ms`, `tokens`, `cost`, `model`, `role`, `parent`.
- Run summary: `needs_you` (oldest first: agent, kind approval|question, literal text, reason,
  requested_at), `reported`/`total` for swarms; workflow `phases` (name, state, step agents, retry
  count/at); goal (iteration, max, criteria with `met_in`, last verdict text); consensus (round, rounds,
  models with position letter and `moved_from`, judge verdict text, "k of n on X"); research (found, read,
  used, domains with counts, report sections with state). Include only what the domain really records;
  what it does not record is omitted, never invented.
- Agent detail (on demand, for the overlay): brief, why-it-asks (approval justification), findings list,
  activity groups (kind, title, items, started_at, duration, quoted thought or last output line), life lane
  (≤ 120 buckets over the agent's lifetime), files read/searched/changed, tokens in/out, context used and
  window, budget if set, neighbours in panel order.
- Steer an individual agent from the overlay (the existing steer/message path targeted at the node).

### Owner P: the panel (everything drawn in the panel and the transcript's agent lines)

Files: `apps/swarm_code_cli/lib/swarm_code_cli/ui/{projector/**,projector.ex,scene/**,scene.ex,
scene_slot.ex,paint/**,paint.ex,prose.ex,transcript.ex,theme.ex,safe_text.ex,safe_text/**,layout.ex,
layout/**,capabilities.ex,capabilities/**}` except the new `projector/overlay.ex` (owner O), `companion/**`,
`demo/**`, their tests, the cell gallery. May append `State` fields only in a block `# pass72-P fields`.

- Replace the inspector's agents tab with the D panel in full, compact, hidden and strip, for chat, swarm,
  workflow, goal, plan, research, consensus and mixed load, per D2.html frame by frame (glyphs, rows,
  priorities R2, folding D5/D6, name trimming R14, 2-level tree R16, 44 content columns R13).
- The needs-you band, the in-chat bar, the hint badges (P7 layout; state from O's reducer fields), the
  lane rendering (P4) with NO_COLOR/ASCII twins.
- Fix the owner's bugs: nothing drawn past the pane edge (clip at the pane boundary and add a regression
  test), the stray ▐ column, the colliding "active" pill, truncated names with free space.
- Transcript agent lines (P9): merge spawn and lane rows; drop isolation/branch text.
- Timeline and changes tabs stay reachable (they are not operations) but the default tab is the panel.
- Golden scenes and the gallery at 160x45, 120x36, 90x30, 80x24, NO_COLOR and the ASCII tier; render
  real screens with `tools/vt.py` and compare with D2.html.

### Owner O: the overlay and the keys

Files: `apps/swarm_code_cli/lib/swarm_code_cli/ui/{reducer/**,reducer.ex,keymap/**,keymap.ex,
editor/**,editor.ex,state.ex,layer_spec.ex,session_runtime.ex,intent.ex,action.ex,action_target.ex,
read_model.ex,watch_state.ex,destination.ex,effect.ex,effect_runner.ex,switcher.ex,slash_palette.ex,
library.ex,input.ex,scroll*.ex}`, new `ui/projector/overlay.ex` (the overlay's projector), `plain/**`,
`release.ex`, `release/headless.ex`, `docs/keybindings.md`, `README.md`, their tests.

- Hint mode state and badge assignment (P7), digits for runs, `Ctrl-F` twice = `Ctrl-N`, Esc; `Ctrl-F` and
  `Ctrl-Space` bindings (and the composer's Emacs map entry).
- The overlay layer (P8): open from a badge, from Enter on a selected agent in select mode, and from the
  needs-you band; its own scroll, focus ring (Tab), `[`/`]`, `o`, Enter to expand/send, the approval
  grammar only while its composer is empty, Esc restoring the chat scroll and the draft exactly.
- `Ctrl-B` cycle, `/panel`, the preferences file read at start and written on change (owned work, never
  file I/O inside a GenServer state callback).
- Regenerate `docs/keybindings.md`; README keys section.

### Unlisted files and cross-owner requests

`ui/width/**`, `ui/renderer/**`, `ui/activity.ex` and `ui/fixtures.ex` belong to P; `ui/draft*`, `ui/question.ex`,
`ui/request_resolver/**`, `ui/vim.ex` and `ui/init.ex` belong to O. Anything else, or a change in another owner's
file, goes in your notes file as a request with the exact change. The finisher applies it after the merge;
do not edit the file yourself. Merge order: S, then P, then O.

## Acceptance (finisher, then QA)

1. `mix precommit` green; `check_terminal_port.sh`; `mix swarm_code.keymap --check`; PTY suites.
2. Sandbox real swarm (4 read-only reviewers on a scratch project): the panel matches D2.html frames 1–3 in
   structure (states, sentences, lane, band, findings); nothing leaks past the pane; no operations; the
   transcript shows one line per agent without isolation text.
3. `Ctrl-F` shows badges; the badge letter opens the overlay; `[`/`]` step agents; `o` shows raw
   operations; typing in the overlay composer steers only that agent; Esc returns to the exact chat scroll
   and draft.
4. An approval raised by a worker appears in the band with the literal command; `y` from the overlay (empty
   composer) approves; `A` always-allows the family.
5. `Ctrl-B` cycles full → compact → hidden; `/panel compact` persists across a restart; a mixed load (two
   swarms, a goal, a workflow) in compact fits and stays readable at 160x45 and 120x36; under 120 columns
   the strip shows `! N needs you ^N`.
6. NO_COLOR and the ASCII tier render every state with its word.
