# Visual companion: build plan and contract

Date: 2026-09-16. Implements section 10 of `2026-09-16-tui-north-star.md`.
The approved design is the static mockup `docs/superpowers/mockups/companion.html`.

## Goal

A saved or live TUI session serves a local web page that mirrors the session
live: header, run tabs, hive (agents), transcript stream, waiting-for-you,
timeline. Clicking in the page focuses the same thing in the TUI. No new hex
packages: the server is OTP `:inets` `httpd`. Bound to 127.0.0.1, random
port, one-time token in every path. Off with `SWARM_COMPANION=0`.

Sections the daemon cannot feed yet (changes, verdict, artefacts, cost) render
their designed empty state with the sentence "not reported by the daemon yet".

## Ownership (three agents in parallel, one shared tree)

| Agent | Owns | Must not touch |
| --- | --- | --- |
| F1 backend | `apps/swarm_code_cli/lib/swarm_code_cli/companion/**`, `apps/swarm_code_cli/lib/swarm_code_cli/companion.ex`, `ui/session_runtime.ex`, `release/persisted_session.ex`, `scripts/dev/persisted_session.exs`, `scripts/dev/live_session.exs`, `apps/swarm_code_cli/mix.exs` (extra_applications), root `mix.exs` release applications, `test/swarm_code_cli/companion/**` | reducer, action, switcher, priv/companion, README |
| F2 frontend | `apps/swarm_code_cli/priv/companion/**`, `scripts/dev/companion_screenshot.sh`, `docs/superpowers/mockups/**` | any `.ex`/`.exs` |
| O1 surface | `ui/action.ex`, `ui/reducer.ex`, `ui/reducer/**`, `ui/switcher.ex`, `ui/effect*.ex` (whatever validates effects), `ui/init.ex`, `README.md`, `scripts/dev/run_saved_session.sh` and `run_live_session.sh` help text, `docs/keybindings.md` if regenerated | session_runtime, companion/**, priv |

Nobody commits. The orchestrator integrates, runs the umbrella suite, commits.

## HTTP contract (F1 serves, F2 consumes)

Base: `http://127.0.0.1:<port>/c/<token>`. Any path without the exact token
answers 404 with an empty body. Token compare is constant time.

| Route | Answer |
| --- | --- |
| `GET /c/<token>/` | `text/html`, the file `priv/companion/index.html` |
| `GET /c/<token>/view` | `application/json`, the current view (below). Optional `?since=<revision>`: if unchanged, `204` |
| `GET /c/<token>/events` | `text/event-stream`. First message `event: view` with the JSON view as `data`, then one `event: view` per change, coalesced to at most 10 per second. `event: ping` every 15 s. If inets cannot stream, this route may answer 404 and the page falls back to polling `/view` |
| `POST /c/<token>/focus` | body `{"kind":"run"|"agent"|"item"|"conversation"|"composer","id":"…"}`. Injects the TUI action that focuses that thing. `204` |
| `POST /c/<token>/act` | body `{"action":"approve"|"deny"|"answer","id":"…","revision":N,"option":"…"}`. Injects the TUI intent. `204`, or `409` if the TUI rejects it. May answer `501` in v1 |

## View JSON (F1 builds from the reducer `State`; F2 renders)

Every field is always present; unknown values are `null`, unknown lists `[]`.

```json
{
  "revision": 123,
  "session": {"id": "8e5e507a", "started_at": 1789554968831, "now": 1789555100000},
  "header": {"project": "ailogic", "model": "deepseek-v4.1-flash", "mode": "build",
             "approval": "read-only", "keymap": "vim", "effort": "max",
             "cost": null, "context_tokens": null},
  "tabs": [{"id": "run-uuid", "title": "read only app analysis", "state": "running",
            "kind": "swarm", "agents": 3, "needs": 1, "started_at": 1789554968831,
            "finished_at": null, "active": true}],
  "run": {"id": "run-uuid", "title": "…", "state": "running", "kind": "swarm",
          "started_at": 1789554968831, "finished_at": null,
          "edges": [{"from": "agent-a", "to": "agent-b", "kind": "spawn"}]},
  "agents": [{"id": "agent-a", "name": "lead", "role": "lead", "state": "streaming",
              "step": "planning", "progress": 0.75, "tokens": null, "hue": 0,
              "waiting": false, "parent_id": null, "started_at": 1789554968831}],
  "transcript": [{"id": "item", "role": "assistant", "agent_id": "agent-a",
                  "state": "streaming", "kind": "text", "text": "…",
                  "reasoning": null, "at": 42}],
  "needs": [{"id": "interaction-id", "kind": "approval", "run_id": "…",
             "agent_id": "…", "title": "mix ecto.migrate", "command": "mix ecto.migrate",
             "cwd": null, "reason": null, "risk": null,
             "options": [{"id": "approve", "label": "allow"}, {"id": "deny", "label": "deny"}],
             "revision": 7}],
  "changes": {"files": [], "unavailable": "not reported by the daemon yet"},
  "timeline": {"events": [{"at": 42, "kind": "you"|"lead"|"agent"|"judge"|"wait", "agent_id": null}],
               "checkpoints": []},
  "verdict": null,
  "artifacts": [],
  "focus": {"kind": "composer"|"run"|"agent"|"item", "id": null},
  "notice": null
}
```

Rules for F1:

- `agents` come from the active run's `AgentSummary` list. The daemon sends
  only id and state today, so `name` is `agent-<first 4 hex>` and `role` is
  `"lead"` for the run's root node when identifiable, else `"worker"`;
  `step` is the state word; `progress` is 1.0 for terminal states, 0.0 for
  queued, 0.5 for running. When the DTOs gain real fields, use them.
- `hue` is the agent's index modulo 6, lead always 0.
- `edges` are `spawn` edges from the lead to every other agent.
- `transcript` is the active run's items, ordered by `created_sequence`,
  text capped at 4 000 characters each, at most 200 items (newest kept).
- `timeline.events`: one per transcript item: role user → `you`, the lead's
  items → `lead`, other agents → `agent`, an item in `waiting_*` → `wait`.
- `needs` come from pending interactions across all runs.
- `focus` mirrors `State.focus` and the current destination.

## TUI integration (F1)

- `SessionRuntime` gets `opts[:companion]` (pid or nil). After every
  `Reducer.update` and every delivery, it sends `{:companion_state, ui}` to
  that pid. Coalescing lives in the companion, not in the runtime.
- Focus and act requests enter through `SessionRuntime.action/2` with the
  existing Action shapes for navigating to a run / conversation / focusing
  the composer (F1 finds the exact actions in `ui/action.ex`; if none fits,
  add nothing to the reducer and answer `501`, then say so in the report).
- `SwarmCodeCLI.Companion` public API, used by O1:
  - `start_link(opts)` with `runtime: pid`; started under the session
    supervisor in `release/persisted_session.ex`, `scripts/dev/persisted_session.exs`
    and `scripts/dev/live_session.exs` unless `SWARM_COMPANION` is `"0"`.
  - `url/0 :: {:ok, String.t()} | :unavailable`
  - `open/0 :: :ok | {:error, term}` runs `open` (macOS) or `xdg-open`
    (Linux) with the URL, never blocking the caller for more than 1 s.
- Effect contract with O1: the reducer may emit the effect
  `{:companion, :open}`; `SessionRuntime` executes it by calling
  `SwarmCodeCLI.Companion.open/0` and then injecting the existing notice
  action with the URL (or "Companion is off (SWARM_COMPANION=0)").

## Surface (O1)

- Palette (switcher) entry "Open visual companion" → action `:open_companion`
  → effect `{:companion, :open}`. Add the action to `UI.Action` validation and
  the effect to whatever validates effects. No key binding (Ctrl-\ is
  SIGQUIT and Alt is unreliable on macOS).
- Status notice after opening shows the URL for 10 s so it can be copied.
- `Init` gains `companion_url: nil | String.t()` if the header should show
  it; optional.
- README: a "Visual companion" section (what it is, URL in the palette,
  `SWARM_COMPANION=0`), and the two launcher `--help` texts mention it.

## Frontend (F2)

- One file `priv/companion/index.html`, vanilla JS, no build step, no CDN.
  Same CSS as the mockup. Renders entirely from the view JSON.
- Connects with `EventSource` to `events`; on error falls back to polling
  `view?since=<revision>` every 500 ms. Shows a "reconnecting" pill when the
  stream drops.
- Hive graph: lead centred, others on a ring, radius from count; edges from
  `run.edges`; progress arc from `progress`; `waiting` gets the red halo;
  `streaming` breathes. Clicking posts `focus`.
- Lanes list under the graph, files/changes, needs card, timeline scrubber:
  scrubbing filters every element with `at` greater than the chosen
  sequence, exactly like the mockup's `data-at`.
- Empty states use the mockup's typography; the "DESIGN MOCKUP" pill
  becomes a "LIVE" pill (green) or "RECONNECTING" (amber).
- `?fixture=1` loads `priv/companion/fixture.json` instead of the network,
  so the page can be designed and screenshotted without a session.
- `scripts/dev/companion_screenshot.sh <url-or-file> <out.png>` renders with
  headless Chrome using a throwaway `--user-data-dir` under `/tmp` (never
  the user's profile), for verification.

## Verification the orchestrator runs before committing

1. `mise exec -- mix format --check-formatted` on every changed file.
2. `mise exec -- mix test` from the umbrella root: everything green except
   `locked_branch_test` (expected while `_build/prod` exists).
3. Saved session smoke: start `scripts/dev/run_saved_session.sh` under a
   pty or the plain launcher with the companion on, fetch `/view` with
   `curl`, confirm JSON with the active run, and fetch `/` for the page.
4. Screenshot of the live page via `scripts/dev/companion_screenshot.sh`.
