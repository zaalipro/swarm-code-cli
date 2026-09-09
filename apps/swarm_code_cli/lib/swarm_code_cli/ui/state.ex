defmodule SwarmCodeCLI.UI.State do
  @moduledoc "Immutable UI state. Inspection intentionally excludes all user and source content."
  alias SwarmCodeCLI.UI.{Drafts, FieldEditors, Scroll, ReadModel}
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
