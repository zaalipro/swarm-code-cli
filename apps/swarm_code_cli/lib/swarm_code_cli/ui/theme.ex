defmodule SwarmCodeCLI.UI.Theme do
  @moduledoc """
  Carbon dark as renderer-neutral color values, text prefixes and layout cues.

  Consumers render `prefix` in every color mode and honor structural `cues`.
  `:reason_required` requires the projector to supply the disabled reason as
  SafeText beside the fixed [DISABLED] prefix. Status words and action availability
  remain projector data; status/1 never invents Retry or Resume permission.
  No colored underline or renderer escape sequences are represented here.
  """
  alias SwarmCodeCLI.UI.{Capabilities, SafeText, Scene}
  alias SwarmCodeCLI.UI.Scene.{Color, Style}
  @modes [:truecolor, :ansi256, :ansi16, :monochrome]
  def roles, do: Style.roles()

  @spec style(Scene.style_role(), Capabilities.t()) :: Style.t()
  def style(role, %Capabilities{color_mode: mode}) when mode in @modes do
    role |> base_style(mode) |> Map.put(:role, role)
  end

  defp base_style(:border, mode),
    do: %Style{foreground: color(mode, 0x2A2A2A, 236, :bright_black)} |> cue(:border, mode)

  defp base_style(:text_primary, mode),
    do: %Style{foreground: color(mode, 0xF3F2F0, 255, :bright_white)} |> cue(:text_primary, mode)

  defp base_style(:text_muted, mode),
    do: %Style{foreground: color(mode, 0x8C8B88, 245, :white)} |> cue(:text_muted, mode)

  defp base_style(:text_faint, mode),
    do: %Style{foreground: color(mode, 0x5E5D5A, 240, :bright_black)} |> cue(:text_faint, mode)

  defp base_style(:focus, mode),
    do: %Style{foreground: color(mode, 0xFF6A1A, 208, :bright_yellow)} |> cue(:focus, mode)

  defp base_style(:disabled, mode),
    do: %Style{foreground: color(mode, 0x5E5D5A, 240, :bright_black)} |> cue(:disabled, mode)

  defp base_style(:stale, mode),
    do: %Style{foreground: color(mode, 0xF5B400, 220, :bright_yellow)} |> cue(:stale, mode)

  defp base_style(:accent, mode),
    do: %Style{foreground: color(mode, 0xFF6A1A, 208, :bright_yellow)} |> cue(:accent, mode)

  defp base_style(:assistant, mode),
    do: %Style{foreground: color(mode, 0xFF6A1A, 208, :bright_yellow)} |> cue(:assistant, mode)

  defp base_style(:success, mode),
    do: %Style{foreground: color(mode, 0x3DDC5A, 41, :bright_green)} |> cue(:success, mode)

  defp base_style(:warning, mode),
    do: %Style{foreground: color(mode, 0xF5B400, 220, :bright_yellow)} |> cue(:warning, mode)

  defp base_style(:error, mode),
    do: %Style{foreground: color(mode, 0xFF4D4F, 203, :bright_red)} |> cue(:error, mode)

  defp base_style(:info, mode),
    do: %Style{foreground: color(mode, 0x4DA3FF, 75, :bright_blue)} |> cue(:info, mode)

  defp base_style(:workflow, mode),
    do: %Style{foreground: color(mode, 0x4DA3FF, 75, :bright_blue)} |> cue(:workflow, mode)

  defp base_style(:run_assistant, mode),
    do:
      %Style{foreground: color(mode, 0xFF6A1A, 208, :bright_yellow)} |> cue(:run_assistant, mode)

  defp base_style(:run_goal, mode),
    do: %Style{foreground: color(mode, 0xB08CFF, 141, :bright_magenta)} |> cue(:run_goal, mode)

  defp base_style(:run_swarm, mode),
    do: %Style{foreground: color(mode, 0x2FD0B8, 44, :bright_cyan)} |> cue(:run_swarm, mode)

  defp base_style(:run_workflow, mode),
    do: %Style{foreground: color(mode, 0x4DA3FF, 75, :bright_blue)} |> cue(:run_workflow, mode)

  defp base_style(:run_research, mode),
    do: %Style{foreground: color(mode, 0xFF9F45, 215, :yellow)} |> cue(:run_research, mode)

  defp base_style(:run_consensus_judge, mode),
    do:
      %Style{foreground: color(mode, 0xB8E356, 149, :bright_green)}
      |> cue(:run_consensus_judge, mode)

  defp base_style(:run_ultra, mode),
    do: %Style{foreground: color(mode, 0x9B5CFF, 135, :bright_magenta)} |> cue(:run_ultra, mode)

  defp base_style(:agent_lane_1, mode),
    do: %Style{foreground: color(mode, 0x2DD4BF, 44, :cyan)} |> cue(:agent_lane_1, mode)

  defp base_style(:agent_lane_2, mode),
    do: %Style{foreground: color(mode, 0xA78BFA, 141, :magenta)} |> cue(:agent_lane_2, mode)

  defp base_style(:agent_lane_3, mode),
    do: %Style{foreground: color(mode, 0xF59E0B, 214, :yellow)} |> cue(:agent_lane_3, mode)

  defp base_style(:agent_lane_4, mode),
    do: %Style{foreground: color(mode, 0xF472B6, 212, :magenta)} |> cue(:agent_lane_4, mode)

  defp base_style(:agent_lane_5, mode),
    do: %Style{foreground: color(mode, 0x38BDF8, 81, :cyan)} |> cue(:agent_lane_5, mode)

  defp base_style(:canvas, mode),
    do: %Style{background: color(mode, 0x141414, 233, :black)} |> cue(:canvas, mode)

  defp base_style(:surface, mode),
    do: %Style{background: color(mode, 0x191919, 234, :black)} |> cue(:surface, mode)

  defp base_style(:card, mode),
    do: %Style{background: color(mode, 0x1E1E1E, 235, :bright_black)} |> cue(:card, mode)

  defp base_style(:selection, mode) when mode in [:ansi16, :monochrome],
    do: %Style{modifiers: [:reversed]} |> cue(:selection, mode)

  defp base_style(:selection, mode),
    do:
      %Style{
        foreground: color(mode, 0xF3F2F0, 255, :bright_white),
        background: color(mode, 0x262626, 236, :black)
      }
      |> cue(:selection, mode)

  defp base_style(:plain, mode), do: base_style(:text_primary, mode)

  defp base_style(:title, mode),
    do: base_style(:text_primary, mode) |> Map.put(:modifiers, [:bold])

  defp base_style(:heading, mode),
    do: base_style(:text_primary, mode) |> Map.put(:modifiers, [:bold])

  defp base_style(:body, mode), do: base_style(:text_primary, mode)
  defp base_style(:label, mode), do: base_style(:text_muted, mode)
  defp base_style(:value, mode), do: base_style(:text_primary, mode)
  defp base_style(:code, mode), do: base_style(:text_primary, mode)
  defp base_style(:link, mode), do: base_style(:info, mode)

  defp base_style(:key, mode),
    do:
      %Style{foreground: color(mode, 0x4DA3FF, 75, :bright_blue)} |> Map.put(:modifiers, [:bold])

  defp base_style(:status, mode), do: base_style(:text_primary, mode)
  defp base_style(:selected, mode), do: base_style(:selection, mode)

  defp base_style(:emphasis, mode),
    do: base_style(:text_primary, mode) |> Map.put(:modifiers, [:bold])

  defp color(:truecolor, rgb, _index, _ansi),
    do: %Color{
      role: :default,
      value: {:rgb, div(rgb, 65_536), rem(div(rgb, 256), 256), rem(rgb, 256)}
    }

  defp color(:ansi256, _rgb, index, _ansi), do: %Color{role: :default, value: {:indexed, index}}
  defp color(:ansi16, _rgb, _index, ansi), do: %Color{role: :default, value: {:ansi, ansi}}
  defp color(:monochrome, _rgb, _index, _ansi), do: nil

  defp cue(style, :focus, mode),
    do: %{
      style
      | prefix: SafeText.chrome(:focus_marker),
        modifiers: if(mode == :monochrome, do: [:reversed, :bold], else: [:bold])
    }

  defp cue(style, :selection, _mode), do: %{style | prefix: SafeText.chrome(:selection_marker)}

  defp cue(style, :disabled, _mode),
    do: %{style | prefix: SafeText.chrome(:disabled_marker), cues: [:reason_required]}

  defp cue(style, :stale, _mode),
    do: %{style | prefix: SafeText.chrome(:stale_marker), cues: [:border]}

  defp cue(style, :surface, _mode), do: %{style | cues: [:separator]}
  defp cue(style, role, _mode) when role in [:card, :border], do: %{style | cues: [:border]}

  defp cue(style, role, _mode) when role in [:text_muted, :text_faint],
    do: %{style | cues: [:explicit_label]}

  defp cue(style, :accent, _mode), do: %{style | prefix: SafeText.chrome(:accent_marker)}
  defp cue(style, :assistant, _mode), do: %{style | prefix: SafeText.chrome(:run_assistant)}
  defp cue(style, :success, _mode), do: %{style | prefix: SafeText.chrome(:success_marker)}
  defp cue(style, :warning, _mode), do: %{style | prefix: SafeText.chrome(:warning_marker)}
  defp cue(style, :error, _mode), do: %{style | prefix: SafeText.chrome(:error_marker)}
  defp cue(style, :info, _mode), do: %{style | prefix: SafeText.chrome(:info_marker)}
  defp cue(style, :workflow, _mode), do: %{style | prefix: SafeText.chrome(:run_workflow)}
  defp cue(style, :run_assistant, _mode), do: %{style | prefix: SafeText.chrome(:run_assistant)}
  defp cue(style, :run_goal, _mode), do: %{style | prefix: SafeText.chrome(:run_goal)}
  defp cue(style, :run_swarm, _mode), do: %{style | prefix: SafeText.chrome(:run_swarm)}
  defp cue(style, :run_workflow, _mode), do: %{style | prefix: SafeText.chrome(:run_workflow)}
  defp cue(style, :run_research, _mode), do: %{style | prefix: SafeText.chrome(:run_research)}

  defp cue(style, :run_consensus_judge, _mode),
    do: %{style | prefix: SafeText.chrome(:run_consensus_judge)}

  defp cue(style, :run_ultra, _mode), do: %{style | prefix: SafeText.chrome(:run_ultra)}
  defp cue(style, :agent_lane_1, _mode), do: %{style | prefix: SafeText.chrome(:agent_lane_1)}
  defp cue(style, :agent_lane_2, _mode), do: %{style | prefix: SafeText.chrome(:agent_lane_2)}
  defp cue(style, :agent_lane_3, _mode), do: %{style | prefix: SafeText.chrome(:agent_lane_3)}
  defp cue(style, :agent_lane_4, _mode), do: %{style | prefix: SafeText.chrome(:agent_lane_4)}
  defp cue(style, :agent_lane_5, _mode), do: %{style | prefix: SafeText.chrome(:agent_lane_5)}
  defp cue(style, _role, _mode), do: style

  def run_kind(:assistant), do: {SafeText.chrome(:run_assistant), :run_assistant}
  def run_kind(:goal), do: {SafeText.chrome(:run_goal), :run_goal}
  def run_kind(:swarm), do: {SafeText.chrome(:run_swarm), :run_swarm}
  def run_kind(:workflow), do: {SafeText.chrome(:run_workflow), :run_workflow}
  def run_kind(:research), do: {SafeText.chrome(:run_research), :run_research}

  def run_kind(:consensus_judge),
    do: {SafeText.chrome(:run_consensus_judge), :run_consensus_judge}

  def run_kind(:ultra), do: {SafeText.chrome(:run_ultra), :run_ultra}
  def agent_lane(1), do: {SafeText.chrome(:agent_lane_1), :agent_lane_1}
  def agent_lane(2), do: {SafeText.chrome(:agent_lane_2), :agent_lane_2}
  def agent_lane(3), do: {SafeText.chrome(:agent_lane_3), :agent_lane_3}
  def agent_lane(4), do: {SafeText.chrome(:agent_lane_4), :agent_lane_4}
  def agent_lane(5), do: {SafeText.chrome(:agent_lane_5), :agent_lane_5}
  def status(:connecting), do: {SafeText.chrome(:status_connecting), :info}
  def status(:empty), do: {SafeText.chrome(:status_empty), :text_muted}
  def status(:loading), do: {SafeText.chrome(:status_loading), :info}
  def status(:running), do: {SafeText.chrome(:status_running), :accent}
  def status(:streaming), do: {SafeText.chrome(:status_streaming), :accent}
  def status(:queued), do: {SafeText.chrome(:status_queued), :warning}
  def status(:waiting_question), do: {SafeText.chrome(:status_waiting_question), :warning}
  def status(:waiting_approval), do: {SafeText.chrome(:status_waiting_approval), :warning}
  def status(:paused), do: {SafeText.chrome(:status_paused), :warning}
  def status(:retrying), do: {SafeText.chrome(:status_retrying), :warning}
  def status(:done), do: {SafeText.chrome(:status_done), :success}
  def status(:failed), do: {SafeText.chrome(:status_failed), :error}
  def status(:stopped), do: {SafeText.chrome(:status_stopped), :text_muted}
  def status(:interrupted), do: {SafeText.chrome(:status_interrupted), :warning}
  def status(:stale), do: {SafeText.chrome(:status_stale), :stale}
  def status(:resyncing), do: {SafeText.chrome(:status_resyncing), :info}
  def status(:disconnected), do: {SafeText.chrome(:status_disconnected), :error}
  def status(:superseded), do: {SafeText.chrome(:status_superseded), :text_muted}
  def status(:mutation_pending), do: {SafeText.chrome(:status_mutation_pending), :info}
end
