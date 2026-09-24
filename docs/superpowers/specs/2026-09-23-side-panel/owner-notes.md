# Owner notes for the side-panel pass (2026-09-23, from screenshots 18:43–18:45)

Bugs seen live in the installed pass-70 build (swarm of 4 read-only reviewers on ~/dev/swarm-code):
- Transcript shows every sub-agent twice: a spawn row "▌ agent engine-lifecycle-review 59s" AND a lane row
  "✦ engine-lifecycle-review ▌ 59s · 20 tools". Keep one.
- Lane rows print internal isolation text: "isolated in swarm/2404157a/engine-lifecycle-review-bd868c6f"
  (branch/worktree name leaking as the agent's summary).
- Digits ("22", "23") drawn past the right edge of the side pane; a stray column of ▐ bars beside the
  sub-agent list (sparkline/gauge column mis-sized).
- Agent card: green "active" pill overlaps the text; hexagon glyph floats alone; tool chips as grey buttons;
  "Current task" gauge empty dashed bar; "◷ lanes ⌥ diff" cryptic; sub-agent names truncated to 14 cells
  with free space.
- "Operations · <agent> · 30 ops" list of read_file/thinking rows in the pane.

Owner requirements (binding for the redesign):
1. Side panel = visual representation of what happens in the main chat; NO operations in the panel.
2. No side-chat split: an agent overlay (temporary full view, Esc closes), where operations, the agent's
   transcript, result/diff and a steer composer live.
3. Hotkeys: a leader shows hint badges on every agent/run in the panel; the badge key opens the overlay.
   (Owner suggested double Shift/Option — impossible in a terminal; Ctrl-F, and Ctrl-Space where delivered.)
4. User-selectable compact vs full panel (Ctrl-B cycles full → compact → hidden, /panel, persisted);
   compact must handle many concurrent runs (multiple swarms, goal, consensus, workflow).

The owner approved implementing the redesign on 2026-09-23 ("this is approved from me lets implement once current
workflows will finish"); no direction was clicked in the gallery, so the build follows the orchestrator's stated
default, D ("Constellation with a pulse"), the synthesis of A, B and C.
