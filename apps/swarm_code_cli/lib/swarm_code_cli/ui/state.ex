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
