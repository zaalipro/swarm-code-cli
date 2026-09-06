defmodule SwarmCodeCLI.UI.Scene.Style do
  alias SwarmCodeCLI.UI.Scene.Color

  @roles [
    :plain,
    :title,
    :heading,
    :body,
    :label,
    :value,
    :code,
    :link,
    :key,
    :status,
    :selected,
    :disabled,
    :emphasis,
    :canvas,
    :surface,
    :card,
    :border,
    :text_primary,
    :text_muted,
    :text_faint,
    :focus,
    :selection,
    :stale,
    :accent,
    :assistant,
    :success,
    :warning,
    :error,
    :info,
    :workflow,
    :run_assistant,
    :run_goal,
    :run_swarm,
    :run_workflow,
    :run_research,
    :run_consensus_judge,
    :run_ultra,
    :agent_lane_1,
    :agent_lane_2,
    :agent_lane_3,
    :agent_lane_4,
    :agent_lane_5
  ]
  @modifiers [:bold, :dim, :italic, :underlined, :reversed]
  @cues [:separator, :border, :explicit_label, :reason_required]
  defstruct role: :plain, foreground: nil, background: nil, modifiers: [], prefix: nil, cues: []

  @type role ::
          :plain
          | :title
          | :heading
          | :body
          | :label
          | :value
          | :code
          | :link
          | :key
          | :status
          | :selected
          | :disabled
          | :emphasis
          | :canvas
          | :surface
          | :card
          | :border
          | :text_primary
          | :text_muted
          | :text_faint
          | :focus
          | :selection
          | :stale
          | :accent
          | :assistant
          | :success
          | :warning
          | :error
          | :info
          | :workflow
          | :run_assistant
          | :run_goal
          | :run_swarm
          | :run_workflow
          | :run_research
          | :run_consensus_judge
          | :run_ultra
          | :agent_lane_1
          | :agent_lane_2
          | :agent_lane_3
          | :agent_lane_4
          | :agent_lane_5
  @type t :: %__MODULE__{
          role: role(),
          foreground: Color.t() | nil,
          background: Color.t() | nil,
          modifiers: [atom()],
          prefix: SwarmCodeCLI.UI.SafeText.t() | nil,
          cues: [:separator | :border | :explicit_label | :reason_required]
        }
  def roles, do: @roles
  def cues, do: @cues
  def modifiers, do: @modifiers
end
