# Pass 73: the owner's eleven notes after using pass 72 on real work (2026-09-24)

The owner used the installed pass-72 CLI (`swarmcode` in ~/dev/ailogic, real DB) with a `/swarm`, a
`/create-workflow` and an approval at once, and reported eleven problems (screenshots described below).
This pass fixes all of them. Rules: pass-70 plan sections 2-3 and the pass-72 plan's working rules (never
the real DB, sandboxes under `/Users/zaali/.cache/p70cli/`, scratch ailogic copies, commit trailer
`Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`, never push, never
`scripts/install.sh`), the design language of `docs/superpowers/specs/2026-09-23-side-panel/`
(critique.md rules R1-R17, D2.html frames) and AGENTS.md (Width.cells under both ambiguous-width
policies, Theme roles only, bindings only in Keymap.Bindings, never Ctrl-K, nothing essential on Alt).

## The notes and the decisions (final)

- **T1 `/diff`** (screenshot: a `git diff` tool row expands into a 12-line red diff block inside the
  Lead's block). `/diff` toggles, `/diff on|off` sets. Hidden: every tool row stays one line — verb,
  target, meta ("edited lib/x.ex +3 −1", "read README.md · 21 lines", "git diff · +0 −53") — no inline diff
  bodies, file previews or "… N more lines" tails; Enter on a row still opens the full pager. Shown =
  today. Persisted in cli.json (`show_diffs`, default true); a one-line confirmation ("Diffs hidden ·
  /diff shows them").
- **T2 `/theme`** toggles dark/light, `/theme dark|light` sets. Applies live (no restart: re-send the
  palette to the port owner and repaint), persisted in cli.json (`theme`). Start precedence:
  `SWARM_THEME` > cli.json > the desktop settings' mode > dark. When `SWARM_THEME` is set, the
  confirmation says it still wins at the next launch.
- **T3 / T8 Nothing is refused while work runs** (screenshots: typing `/compact`, and later
  `/plan …`, while a `/create-workflow` turn and a swarm were live → footer "The daemon refused that
  request"; the owner: "the whole point of SwarmCode is that everything you send happens asynchronously,
  with full monitoring in the panel and the chat"). Rules:
  - Run-launching commands (`/swarm`, `/plan`, `/consensus`, `/research`, `/create-workflow`, workflow
    runs, goals) start a new run at once, concurrently with the live ones, and appear in the panel and
    the chat immediately.
  - A plain message while this conversation's chat turn runs is delivered to that running turn as a steer
    (the way Claude Code surfaces mid-turn messages), shown in the transcript as the user's message with a
    small "→ to the running turn" mark; when the domain cannot steer at that moment it is queued ("queued ·
    sends after the running turn"), never dropped.
  - `/compact` and other conversation-level commands during a turn are queued with visible feedback.
  - Any refusal that remains says why and what to do, in words, never "The daemon refused that request".
  - Mirror what the desktop domain allows (read `~/dev/swarm-code` read-only: Engine, the conversation
    queue, steer); if the daemon's admission rules are stricter than the desktop's, relax them to match.
- **T4 Enter completes** (screenshot: `/com` with the palette showing `/compact`; `/consens` with
  `/consensus`). While the slash palette is open, Enter accepts the highlighted command like Tab; a
  command that takes no argument then runs at once (Claude Code behaviour); one that takes an argument
  gets `/<name> ` and the cursor waits. An exact match runs as today.
- **T5 The word "workflow"** (screenshot of Claude Code highlighting "ultracode" in the prompt). Whole
  word `workflow`/`workflows`, case-insensitive, outside backticks, in a message that does not start with
  `/`: highlighted in the composer and in the sent user message (Theme `run_workflow` role, bold), with a
  one-line hint above the composer "workflow · sends as /create-workflow · <key> plain message", and on
  send the message runs as `/create-workflow <text>`. The opt-out key (a free binding in Keymap.Bindings,
  documented) sends that one message as a plain message.
- **T6 Footer hints are true** (screenshot: after sending, the right footer still says "Esc interrupt ·
  Enter send"). Show only actions that work now: Enter's hint only when the composer has text, and it says
  what Enter does now (send / steer / queue / run); Esc's hint only when Esc does something now, naming it
  (e.g. "Esc stop Workflow author", or "Esc clear" with a draft).
- **T7 The approval card** (screenshots: "! review-deletion-impact wants to run a command" then a 4-line
  `cd … && echo … | head -5; …` wall of text, "in the project · dangerous", "y once Y this run d deny D
  deny & stop"; the owner: "super ugly, looks like I ran /approval and it changed the policy without any
  feedback"). Redesign in the D2 language: a framed card with a header (glyph, agent, verb, risk word in
  its colour, reason on its own line), the command in a code block wrapped at shell-token boundaries,
  at most 6 lines then "… N more lines · Enter shows all", a key row of real chips with even spacing
  (`y once · Y this run · A always "<prefix>" · d deny · D deny & stop`), one blank row between the card
  and the composer — the card never touches or overlaps the composer. `/approval` with no argument
  opens a small picker of the three modes with the current one marked; every policy change, however it
  happens, prints a transcript notice ("Approvals: auto → full access") and a toast.
- **T9 Trackpad scrolling** in the main chat. Mouse wheel reports are opt-in today (pass70 B10,
  `FLAG_MOUSE`). Turn wheel reporting on by default; the wheel scrolls the pane under the pointer
  (transcript, panel, overlay, pager) by 3 lines per notch with the existing scroll model;
  `/mouse on|off` persisted in cli.json restores native selection; the help line and README say that
  Shift/Option-drag selects text while mouse reports are on. Check it in the terminal the owner uses
  (Ghostty-like true colour; also iTerm2 and Terminal.app sequences).
- **T10 The broken layout** (screenshot 11, a `/create-workflow` turn and a swarm with a pending
  approval): the approval card's multi-line command runs into the composer with no separation (the draft
  `/plan … appyyy` sits directly under "y once Y this run …"); the panel's NEEDS YOU band prints the raw
  multi-line `curl … | python3 -c " import json,sys …` across 3-4 rows; the same agent is named
  "review-angular-plan" (card), "angular-plan" (band) and "angular" (panel row); the in-chat run shows
  "Assistant" for the Workflow author. Fix: one display-name function for an agent everywhere; the band
  flattens a command to one line with "…" (the overlay and the card show it whole); the in-chat run
  names its agent by its role label.
- **T11 The session died** (screenshot 12: after running several commands "The session closed because
  the daemon connection closed"; cli.log only says `SwarmCode: the daemon closed the connection` then
  `session closed: :source_unavailable`). P0: reproduce with 2-3 concurrent runs + an approval + sends
  (the pass-72 S owner saw the same once), find why the daemon closes the connection (suspects: the
  outbound queue/overflow policy under several live runs — pass-72 QA Q7 "overflow resyncs" —, a reply
  over a size limit, a crash in Connection), fix it so overflow resyncs instead of closing, and log the
  close reason on both sides (redacted) so the next report is diagnosable.

## Owners (disjoint files; the finisher merges S, K, V1, V2 in that order)

- **S — daemon and wire** (`apps/swarm_code_daemon/**` through the provenance rules, `apps/swarm_code_core/**`,
  `ui/data_source/**`, `ui/effect_runner.ex`): T11 first, then T3/T8 (admission, steer, queue, typed
  refusal reasons on the wire), the approval-policy-changed event for T7 if the client cannot observe it.
- **K — keys, input, commands, state** (`ui/reducer/**`, `reducer.ex`, `keymap/**`, `editor/**`,
  `slash_palette.ex`, `state.ex`, `input.ex`, `scroll*.ex`, `hint.ex`, `init/**` incl. preferences,
  `release.ex`, `release/**`, `plain/**`, `native/terminal_port/**`, `docs/keybindings.md`, README): T9,
  T4, the commands and state of T1/T2/T7 (`/diff`, `/theme`, `/mouse`, `/approval` picker + notice), T5's
  keyword detection + routing (`SwarmCodeCLI.UI.WorkflowKeyword.spans/1`, pure, published early with tag
  `p73-K-keyword`), T3/T8 client side (what Enter does while runs are live, queued/steered marks in state).
  State fields (fixed now): `show_diffs` (boolean, default true), `theme_mode` (:dark | :light),
  `mouse?` (boolean, default true), `enter_action` derivable by `SwarmCodeCLI.UI.Composer.enter_action(state)`
  (:send | :steer | :queue | :run_command | :complete | :none), owned by K and published with the keyword tag.
- **V1 — transcript and cards** (`ui/projector/workspace/**`, `projector/approval_card.ex`,
  `projector/inspector/**`, `transcript.ex`, `prose.ex`, `projector/markdown.ex`, `projector/syntax.ex`,
  `projector/run_row.ex`, `projector/overlay.ex`): T1 rendering, T7 card, T10 (names, band flattening,
  card/composer separation, role labels), the transcript side of T5 (highlight in the sent message) and
  T3/T8 marks (steered/queued).
- **V2 — chrome** (`ui/theme.ex`, `ui/renderer/**`, `ui/projector/composer.ex`, `projector/status.ex`,
  `projector/shell.ex`, `projector/mode.ex`, `projector/key_label.ex`, `ui/capabilities*`, `ui/layout*`,
  `ui/scene/**`, `ui/paint/**`): T2 live switch (palette to the port owner, every cached colour),
  T5 composer highlight + hint line, T6 hints, the toast wording for T3/T7.
- A change in another owner's file goes in `docs/superpowers/plans/pass73-notes/<X>.md` as a request with
  the exact change; the finisher applies it. Read other owners' fields with `Map.get` defaults until merged.

## Acceptance (finisher, then QA)

1. `mix precommit` green; `check_terminal_port.sh`; `mix swarm_code.keymap --check`; PTY suites.
2. Sandbox (real deepseek prompts, scratch ailogic copy): a `/swarm` of 4 + a `/create-workflow` + an
   approval pending, then `/plan …`, `/compact` and a plain message: none is refused, each shows where
   it went; 10 minutes with 3 live runs without the session closing; the cli.log lines on a forced close
   name the reason.
3. `/diff` off → one-line rows, on → diffs back, persisted across a restart. `/theme` flips live and
   persists; `SWARM_THEME` precedence as stated.
4. `/com` + Enter runs `/compact`; `/consens` + Enter leaves `/consensus ` for the argument.
5. "workflow" highlighted in the composer and the sent message; the send runs `/create-workflow`; the
   opt-out key sends a plain message.
6. Footer hints match reality in: empty composer idle, draft idle, empty composer with a live turn, draft
   with a live turn, palette open, approval pending.
7. The approval card at 160x45 and 120x36 with a long multi-line command: framed, ≤ 6 command lines, chips,
   a blank row above the composer; `/approval` picker; a policy change prints the notice.
8. Wheel scroll in the transcript, the panel and the overlay (sent as SGR reports through screen/the PTY
   harness); `/mouse off` restores selection.
9. Screenshot-11 scenario renders cleanly (names consistent, band one line, role label).
