# Pass 73 notes: owner K (keys, input, commands, state)

## Published interface (tag `p73-K-keyword`)

Merge with `git merge --no-edit p73-K-keyword`. Until then read the fields with `Map.get(state, :field, default)`.

### `SwarmCodeCLI.UI.WorkflowKeyword` (T5, pure, `ui/workflow_keyword.ex`)

- `spans(text) :: [{byte_offset, byte_length}]`: every whole-word `workflow`/`workflows` (any case) outside
  backticks. `[]` for a slash command (leading whitespace ignored), invalid UTF-8 or a non-binary.
  "Whole word": nothing that continues an identifier or a path touches it (`create-workflow`,
  `workflow_id`, `priv/workflows/`, `workflow.ex`, `@workflow`), while sentence punctuation does not
  stop a match ("a workflow.", "workflow: …", "the workflow's"). A run of N backticks opens code that the
  next run of exactly N closes (inline and fenced alike); an unmatched run is literal.
- `grapheme_spans(text)`: the same in grapheme indices `{first, count}` (the editor's cursor unit).
- `segments(text) :: [{:text | :keyword, binary}]`: the text cut in order (concatenation == text).
  This is the easiest one for a renderer: style `:keyword` parts with Theme `run_workflow` + bold.
- `routes?(text)`: Enter sends it as `/create-workflow <text>`.
- `command(text)`: `"/create-workflow " <> String.trim(text)`.
- `hint(key_label)`: `"workflow · sends as /create-workflow · <key> plain message"`. The opt-out key
  is **Ctrl-S** (binding id `:send_plain`, label via `KeyLabel`, "^S"); draw the hint line above the
  composer when `Composer.enter_action(state) == :run_command and WorkflowKeyword.routes?(draft)`.

### `SwarmCodeCLI.UI.Composer` (T4/T6/T3, `ui/composer.ex`)

- `enter_action(state) :: :send | :steer | :queue | :run_command | :complete | :none`
  - `:none`: blank draft, a layer is open, or select mode (focus not "composer").
  - `:complete`: the slash palette is open on a command whose argument is its point; Enter writes
    `/<name> ` and waits (`/consens` → `/consensus `).
  - `:run_command`: an exact slash command; the palette's highlighted command that runs bare
    (`/com` → runs `/compact`); a "workflow" message (goes as `/create-workflow`).
  - `:steer`: a plain message while this conversation's top-level `:chat` run is running/streaming/
    waiting/retrying; also any text in the agent overlay's composer.
  - `:queue`: a plain message while the chat turn is `:queued`/`:paused`, or `/compact`/`/rewind`
    while a chat turn is live.
  - `:send`: otherwise (a swarm or workflow running beside does not make it a steer).
  - T6 wording suggestion: send → "Enter send", steer → "Enter steer", queue → "Enter queue",
    run_command → "Enter run", complete → "Enter complete". Show nothing for `:none`.
- `esc_action(state) :: {:stop, run_summary} | :close_layer | :close_overlay | :dismiss_completion | :none`
  (`{:stop, run}` carries the RunSummary so the hint can name it: "Esc stop Workflow author").
- `chat_turn(state)`: the live chat turn of the conversation in view, or nil.

### State fields (`ui/state.ex`)

| Field | Type, default | Meaning |
| --- | --- | --- |
| `show_diffs` | boolean, `true` | T1. `false`: every tool row is one line (verb, target, meta); no inline diff bodies, previews or "… N more lines" tails. Enter on a row still opens the pager. |
| `theme_mode` | `:dark \| :light`, `:dark` | T2. The theme being painted. The reducer emits `{:terminal_preferences, %{theme: mode}}` on a change (see below). |
| `theme_env` | `nil \| :dark \| :light` | T2. `SWARM_THEME` named this at launch (it wins at the next launch). |
| `mouse?` | boolean, `true` | T9. Wheel reports are on. Help/status may say "Shift/Option-drag selects text" when true. |
| `deliveries` | list, `[]` | T3/T8. Newest first, ≤ 50: `%{id, conversation_id, run_id, text, status, at, reason}`; `status` is `:sending \| :steered \| :queued \| :started \| :refused`. `text` is the trimmed text the user sent (for a routed "workflow" message, the text without `/create-workflow`). V1: under the matching user message draw "→ to the running turn" for `:steered` (match `run_id` + text like `steers`), a pending line "queued · sends after the running turn" for `:queued` (it is not in the transcript yet), a dim pending line for `:sending`. `reason` (binary or nil) says why a `:refused` one was not sent. |
| `policy_notices` | list, `[]` | T7. Newest first, ≤ 20: `%{conversation_id, from, to, at}` with `from`/`to` in `:read_only \| :auto \| :full_access` (from may be nil). V1: a transcript notice "Approvals: auto → full access" at time `at` (ms, the state clock). The reducer also sets the toast. |

## Effects to the port owner (V2)

The session runtime sends `{:terminal_preferences, %{theme: :dark | :light}}` and/or
`{:terminal_preferences, %{mouse?: boolean}}` to the terminal owner pid
(`Renderer.RatatuiPort.Owner`, its `dispatch/2` catch-all ignores it until handled). See the request
below for the exact owner change.

## Requests for other owners

(filled in below as the work lands)
