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

### Added after the tag (read with `Map.get` until merged)

| Field | Type, default | Meaning |
| --- | --- | --- |
| `panel_scroll` | integer ≥ 0, `0` | T9. Rows the wheel pushed the side panel's view down (see the finisher request F1). |

`deliveries` entries also carry `turn_id` (the chat turn live at send time, or nil) and `operation`
(`:send | :queue`).

## Requests for other owners

### V2 (port owner, wire): T2 live theme, T9 live mouse

The runtime sends `{:terminal_preferences, %{theme: :dark | :light}}` and/or
`{:terminal_preferences, %{mouse?: boolean}}` to the owner, then commits a new revision so the next
frame is asked for after the message (same sender, so it arrives after). The Rust port (K) accepts a new
command tag 8: `1, 8, generation:u64, token:u64, on:u8` (19 bytes; 0 off, 1 on). It needs no reply; it
updates the port's flags, so a later resume activates with them and the `ready` after it reports them.

`ui/renderer/ratatui_port/wire.ex`, beside `copy/3`:

```elixir
  @doc "pass73 T9: wheel reports on or off live: `1, 8, generation, token, on`."
  def mouse(generation, token, on?)
      when is_integer(generation) and generation >= 0 and generation <= @max_u64 and
             is_integer(token) and token >= 0 and token <= @max_u64 and is_boolean(on?),
      do: {:ok, <<19::32, 1, 8, generation::64, token::64, if(on?, do: 1, else: 0)>>}

  def mouse(_, _, _), do: invalid()
```

`ui/renderer/ratatui_port/owner.ex`, before the catch-all `defp dispatch(_, state)`:

```elixir
  # pass73-K (T2, T9): another theme, or wheel reports on/off, without a restart.
  defp dispatch({:terminal_preferences, preferences}, state) when is_map(preferences) do
    state =
      case Map.get(preferences, :theme) do
        mode when mode in [:dark, :light] -> %{state | theme: mode}
        _ -> state
      end

    state =
      case Map.get(preferences, :mouse?) do
        on? when is_boolean(on?) -> set_mouse(state, on?)
        _ -> state
      end

    {:noreply, state}
  end
```

and beside `copy_text/2`:

```elixir
  # The flags change with the command, so the `ready` of a later resume
  # (`record({:ready, …})` compares its bits with them) agrees.
  defp set_mouse(%{port: port} = state, on?) when port != nil do
    if Map.get(state.flags, :mouse?, false) == on? do
      state
    else
      token = state.counter + 1
      {:ok, bytes} = Wire.mouse(1, token, on?)

      if Port.command(port, bytes, [:nosuspend]),
        do: %{
          state
          | counter: token,
            flags: Map.put(state.flags, :mouse?, on?),
            caps: %{state.caps | mouse: feature(on?)}
        },
        else: state
    end
  end

  defp set_mouse(state, _on?), do: state
```

Anything else the owner caches per theme (a `last_plan` used by `degraded/3`) should be dropped on a
theme change. The palette itself is `Paint.build(scene, %Options{theme: state.theme})`, so the next frame
is already right.

### V2 (composer, status): T5, T6

- Enter's hint from `Composer.enter_action/1`; Esc's from `Composer.esc_action/1` (`{:stop, run}` names
  the run). The opt-out key is `:send_plain` (Ctrl-S, `KeyLabel` gives "^S"): the hint line above the
  composer is `WorkflowKeyword.hint("^S")` when the draft `routes?`.
- A refused send now sets `state.notice` to `"Not sent: <reason>. Your draft is kept; Enter tries
  again."` (K's `Reducer.Deliveries`); the status line's "The daemon refused that request" should give
  way to the notice (or read `hd(state.deliveries).reason` for a `:refused` one).
- A policy change sets `state.notice` to `"Approvals: auto → full access"` (the toast of T7).

### V1 (transcript): T1, T3/T8, T5, T7

- `state.show_diffs == false`: every tool row one line (verb, target, meta), no diff bodies, previews or
  "… N more lines" tails; Enter on the row still opens the pager.
- `state.deliveries`: under the user message whose `run_id` and trimmed text match a `:steered` delivery,
  "→ to the running turn"; a `:queued` delivery (not in the transcript yet) as a pending user line with
  "queued · sends after the running turn"; a `:sending` one dim until answered; a `:refused` one is not
  drawn (the draft is still in the composer).
- `state.policy_notices`: one line "Approvals: auto → full access" at `at` (ms), in the conversation
  `conversation_id`. Words: `:read_only` "read-only", `:auto` "auto", `:full_access` "full access".
- T5: highlight `WorkflowKeyword.segments(text)` `:keyword` parts in the sent user message (the daemon
  stores a routed message's text after `/create-workflow `).

### S (daemon, wire): T3/T8

- The client sends a plain message while the chat turn runs as `dispatch` `send` with the typed text,
  and `/compact` (or `/rewind`) during a turn also as `send`, as typed. Please steer or queue server-side.
- `Reducer.Deliveries` reads the outcome like this: accepted with feedback title `"Queue"` (or text
  starting "Queued") → queued; title `"Steer"` (or text starting "Steered" / "Sent to the running") →
  steered; accepted with the live chat turn's run id in `identifiers` → steered even without feedback;
  any other accepted → started (`run_id` = the first identifier that is a known run). If you choose other
  words, tell the finisher (one clause in `said?/3`).
- A refusal's words: `AdmissionError` messages are fixed per code and `Schema.relations?/1` forbids
  feedback on a non-accepted outcome, so the client maps codes: `:capacity_exceeded` "the daemon is busy",
  `:deadline_expired` "the daemon did not answer in time", `:source_unavailable` "the daemon connection is
  down", `:closed` "the daemon connection is closed", `:stale_revision` "the conversation changed
  meanwhile", `:not_allowed` "it is not allowed right now". A new typed reason (a new code) needs a clause
  in `Deliveries.admission_words/1`; a feedback text on refusals would need the relation relaxed (then
  add `defp reason(%{feedback: %{text: text}}) when text != "", do: text` first).
- `apps/swarm_code_core/lib/swarm_code/commands.ex`: `{"diff", "", "The files this conversation changed,
  with their diffs"}` no longer describes `/diff` (T1 made it the client's toggle). Please change it to
  `{"diff", "[on|off]", "Show or hide diffs and file previews under tool rows"}` and, if you like, add
  `{"theme", "[dark|light]", …}` and `{"mouse", "[on|off]", …}` to `@client`. The palette already shows
  the client's words for `diff`, `theme`, `mouse` and `approval` whatever the catalogue says.

### Finisher

- F1 (T9, `ui/projector/panel.ex`, unowned): the wheel over the panel sets `state.panel_scroll`; the panel
  only overflows in `cut/4`. There, drop the first `min(panel_scroll, overflow)` drawn rows that are not
  band rows (the band stays pinned, R3):

  ```elixir
    # in cut/4, before the reduce_while:
    drawn = Enum.count(rows, &(elem(&1, 0) != nil))
    skip = min(Map.get(ctx.state, :panel_scroll, 0), max(0, drawn - max(room - 1, 0)))
    rows = scrolled(rows, skip)

  defp scrolled(rows, 0), do: rows

  defp scrolled(rows, skip) do
    {kept, _} =
      Enum.flat_map_reduce(rows, skip, fn {block, _target, opts} = row, left ->
        if left == 0 or block == nil or Keyword.get(opts, :band, false),
          do: {[row], left},
          else: {[], left - 1}
      end)

    kept
  end
  ```

  and say "more above" in the cut's last row when `skip > 0`.
- F2 (T9, `ui/projector/dialog.ex` help sheet, unowned): when `Map.get(state, :mouse?, true)`, end the
  help sheet with `SwarmCodeCLI.UI.Keymap.Docs.mouse_note()` (the same sentence `docs/keybindings.md` has).
- F3 (`AGENTS.md`, "TUI facts"): replace "`SWARM_MOUSE=1` opts into SGR wheel reports (off by default:
  they disable the terminal's own selection)" with "Wheel reports are on by default (pass73 T9): the wheel
  scrolls the pane under the pointer; Shift-drag (Option-drag in Terminal.app/iTerm2) selects text;
  `/mouse off` (kept in cli.json) or `SWARM_MOUSE=0` turns them off." Also: "Enter on the `/` list takes
  the highlighted command (runs it when it takes no argument); a message naming a workflow goes as
  `/create-workflow`, Ctrl-S sends it plain."
- F4 (`scripts/dev/live_session.exs`, unowned): the dev launchers still start with `mouse?` unset (off)
  and `Theme.mode(SWARM_THEME, nil)`. `SwarmCodeCLI.Release.PersistedSession.start_preferences/3` gives
  the release's precedence; use it there if the dev sessions should match.
