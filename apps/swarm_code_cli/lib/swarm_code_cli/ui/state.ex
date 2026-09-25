defmodule SwarmCodeCLI.UI.State do
  @moduledoc "Immutable UI state. Inspection intentionally excludes all user and source content."
  alias SwarmCodeCLI.UI.{Drafts, FieldEditors, Scroll, ReadModel, Vim}
  alias SwarmCodeCLI.UI.Layout.Preferences
  @derive {Inspect, only: [:revision, :terminal_generation, :lifecycle]}
  defstruct [
    :size,
    :capabilities,
    :source_epoch,
    :activity_return,
    :hidden_focus,
    :exit_pending,
    :notice,
    :detail,
    :slash_palette,
    command_report: nil,
    # pass70-E fields: the composer-first keyboard, approvals and history.
    # The id of the running "press Ctrl-C again to quit" timer, nil when unarmed.
    quit_armed: nil,
    # Live runs the quit confirmation is about; the dialog says "Stop N live
    # runs and quit?" when this is above zero.
    quit_live_runs: 0,
    # While an approval or question has just opened by itself, keys keep typing
    # into the draft until the user pauses; this is that pause's timer id.
    interaction_grace: nil,
    # pass70 Q2: when the current notice appeared (the owner's clock), so a
    # feedback line on the status bar can fade; nil without a notice.
    notice_at: nil,
    # The pending interaction the reducer opened by itself, so Esc can dismiss
    # it without it popping straight back up.
    auto_opened: nil,
    dismissed_interactions: [],
    # Sent prompts per conversation, newest first, for Up on an empty draft.
    prompt_history: %{},
    # {draft key, index into that conversation's history, the draft it replaced}.
    history_cursor: nil,
    # The project's conversations as the last `conversation_list` answered
    # (a `DTO.ConversationList`), for the palette and `/resume`.
    conversations: nil,
    # The composer's `@path` list (`Reducer.PathCompletion`), nil when the
    # caret ends no `@` token.
    path_completion: nil,
    # pass71-I fields: Enter before the workspace is ready, and a Ctrl-C (or
    # Esc) that races the send it follows.
    # {draft key, text}: an Enter typed while the workspace watch was still
    # loading, replayed once it is ready (one at most).
    deferred_send: nil,
    # {conversation id, run id}: the run the newest accepted send started,
    # while the read model does not show it yet.
    sent_turn: nil,
    # {conversation id, {:request, id} | {:run, id}}: a stop asked for before
    # the turn it stops was on screen; it is sent once that run appears.
    stop_on_arrival: nil,
    # pass73 finisher (S's request K5): the runs this session asked to stop,
    # newest first (at most 32). `Keymap.live_turn/2` passes over them, so a
    # Ctrl-C after the stop reaches the next turn or arms the quit, even while
    # the read model still draws the stopped run live.
    stops_asked: [],
    # pass73 (V2's request K-1): origin => why its settled mutation was not
    # carried out (the daemon's sentence, or its admission code), for the
    # status row's toast.
    mutation_reasons: %{},
    # pass72-O fields: the side panel's mode, hint mode and the agent overlay.
    # The panel's shape: :full (2 rows per agent), :compact (1 row) or
    # :hidden; under 120 columns anything but :hidden is the one-row strip.
    panel_mode: :full,
    # pass73 G1 (QA Q1-08): the last shape the panel had when it was not
    # :hidden, so Ctrl-B on a narrow terminal (strip -> off -> strip) brings
    # back :compact rather than writing :full over it.
    panel_shown: :full,
    # Hint mode (Ctrl-F): nil, or the badge labels (`UI.Hint.labels/1`) and
    # what has been typed of a two-letter label so far.
    hint: nil,
    # The agent overlay: nil, or %{run_id, node_id, focus: :band | :activity
    # | :composer, raw_ops?, page, restore: %{scroll, draft}} (see
    # `UI.Reducer.Overlay`).
    overlay: nil,
    # cli74 (spec §3.7.1): the settings layer while it is open (a
    # `UI.Settings.Layer`), and the user's key overrides from cli.json's
    # `keys` (`UI.Keymap.Overrides`; nil = the defaults everywhere).
    settings: nil,
    key_overrides: nil,
    # The page stack, focus and tasks kept after the layer closes, for the
    # next `/settings` (nil before the first close).
    settings_resume: nil,
    # Undo, redo and "changed in this session" (`Settings.Undo`): kept for
    # the whole session, so they survive closing the layer (D38).
    settings_history: %SwarmCodeCLI.UI.Settings.Undo{},
    # Bumped at every open; responses of an older generation are dropped.
    settings_generation: 0,
    # Every cli.json value by json name, as the session last read it (the
    # launcher's, then every read and write of the preferences queue).
    prefs: %{},
    # The environment variables and flags that override cli.json at this
    # launch (§3.8.4): `env_overrides`, `flag_overrides`, the project root.
    launch_facts: %{},
    # `swarmcode settings [QUERY]` at boot: opened once the shell is ready.
    pending_open_settings: nil,
    pending_resume_picker: false,
    # pass72 G11 (QA Q12): steers sent from the overlay, newest first, as
    # {run_id, text, node_id, agent name} (at most 50), so the transcript can
    # mark a steer "→ agent" and the overlay can echo it. The daemon records
    # a steer as a plain user message of the run.
    steers: [],
    # pass73-K fields (published with the tag `p73-K-keyword`).
    # T1: tool rows show their diffs, previews and output tails (`/diff`).
    show_diffs: true,
    # T2: the painted theme (`/theme`); the port owner repaints on a change.
    theme_mode: :dark,
    # T2: `SWARM_THEME` named a theme at launch, so it wins at the next one.
    theme_env: nil,
    # T9: the terminal sends wheel reports (`/mouse`); off restores the
    # terminal's own click-and-drag selection.
    mouse?: true,
    # T9: rows the wheel pushed the side panel's view down (the panel clamps
    # it to what is cut off when drawn; 0 shows the top).
    panel_scroll: 0,
    # T3/T8: what became of the messages sent from the main composer, newest
    # first (at most 50): %{id, conversation_id, run_id, text, status, at}
    # with status :sending (not answered yet), :steered (went to the running
    # turn `run_id`), :queued (waits for the running turn), :started (began
    # run `run_id`) or :refused (with `reason`, the words why). `text` is
    # trimmed, as the transcript's user message shows it.
    deliveries: [],
    # T7: approval-policy changes observed on the project, newest first (at
    # most 20): %{conversation_id, from, to, at}; the transcript prints
    # "Approvals: auto → full access" at `at`.
    policy_notices: [],
    # The approval mode the workspace last showed (nil before the first), so
    # a change is noticed across a resync that replaced the snapshot.
    approval_seen: nil,
    library: nil,
    feature_form: nil,
    banner: nil,
    terminal_generation: 0,
    lifecycle: :running,
    terminal_focus: :gained,
    watches: %{},
    destination: :activity,
    history: [],
    focus: "main",
    selection: %{},
    expansions: MapSet.new(),
    tabs: %{},
    filters: %{},
    drafts: %Drafts{},
    field_editors: %FieldEditors{},
    preferences: %Preferences{},
    # The keymap preference is session-scoped and lives here rather than in
    # Preferences, which is validated as exactly six layout keys.
    keymap: :default,
    vim: %Vim{},
    composer_height: 3,
    scrolls: %{main: %Scroll{}, inspector: %Scroll{}, navigator: %Scroll{follow?: false}},
    layers: [],
    layer_contexts: [],
    read_model: %ReadModel{},
    pages: %{},
    mutations: %{},
    requests: %{},
    revision: 0,
    id_prefix: "ui",
    id_sequence: 0,
    now: 0,
    deadline_ms: 30_000,
    timers: %{}
  ]

  @type t :: %__MODULE__{}

  # pass70 Q2: how long a feedback line stays on the status bar.
  @notice_ms 6_000

  @doc "How long a fading notice stays on screen, in milliseconds."
  def notice_ms, do: @notice_ms

  @doc """
  The notice the screen shows now: feedback ("Project trusted", "Command
  rejected: not allowed", "Stopping the turn.") fades `notice_ms/0` after it
  appeared; the quit hint and errors that need an answer stay.
  """
  def shown_notice(%{notice: notice, notice_at: at, now: now}) do
    if fading?(notice) and is_integer(at) and is_integer(now) and now - at >= @notice_ms,
      do: nil,
      else: notice
  end

  def shown_notice(%{notice: notice}), do: notice

  @doc "Whether the notice on screen is one that fades and has not faded yet."
  def fading_notice?(state), do: fading?(shown_notice(state))

  defp fading?({:command_feedback, "Press Ctrl-C again to quit."}), do: false
  defp fading?({:command_feedback, text}) when is_binary(text), do: true
  defp fading?({kind, _}) when kind in [:command_rejected, :input_rejected], do: true
  defp fading?(:layer_capacity_reached), do: true
  defp fading?(_notice), do: false

  # The Ctrl-G dashboard keeps its filter query in `selection` under one key that
  # the keymap, the reducer and the dashboard projector all have to agree on, so
  # the key itself lives here instead of being spelled out in three modules.
  @runs_filter_key "runs_dashboard_filter"

  @doc "The runs dashboard filter query, `\"\"` when nothing has been typed."
  @spec runs_filter(t() | map()) :: binary()
  def runs_filter(%{selection: selection}), do: Map.get(selection, @runs_filter_key, "")

  @doc "Stores the runs dashboard filter query; an empty query drops the key entirely."
  @spec put_runs_filter(t(), binary()) :: t()
  def put_runs_filter(state, "" = _query),
    do: %{state | selection: Map.delete(state.selection, @runs_filter_key)}

  def put_runs_filter(state, query) when is_binary(query),
    do: %{state | selection: Map.put(state.selection, @runs_filter_key, query)}

  def next_id(state, kind) do
    sequence = state.id_sequence + 1
    identity = :erlang.term_to_binary({state.id_prefix, state.source_epoch, kind, sequence})
    id = :crypto.hash(:sha256, identity) |> Base.encode16(case: :lower)
    {id, %{state | id_sequence: sequence}}
  end

  def dirty?(state), do: Drafts.dirty?(state.drafts) or FieldEditors.dirty?(state.field_editors)

  # The agent overlay's composer is the one being typed into while it is open.
  def current_draft_key(%{overlay: %{draft_key: key}}) when not is_nil(key), do: key

  def current_draft_key(%{
        destination: {:conversation, id},
        selection: %{"composer_draft" => {id, _} = key}
      }),
      do: key

  def current_draft_key(%{destination: {:conversation, id}}), do: {id, :main}

  def current_draft_key(%{destination: {:run, id}, read_model: model}) do
    case Map.get(model.runs, id) do
      nil -> nil
      run -> {run.conversation_id, :main}
    end
  end

  def current_draft_key(_), do: nil
end
