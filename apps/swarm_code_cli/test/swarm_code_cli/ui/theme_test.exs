defmodule SwarmCodeCLI.UI.ThemeTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.UI.{Capabilities, SafeText, Scene, Size, Theme}
  alias SwarmCodeCLI.UI.Scene.{Color, Span, Style, Block}
  alias SwarmCodeCLI.TestSupport.ContractFixtures

  @foregrounds [
    {:border, 0x2A2A2A, 236, :bright_black},
    {:text_primary, 0xF3F2F0, 255, :bright_white},
    {:text_muted, 0x8C8B88, 245, :white},
    {:text_faint, 0x5E5D5A, 240, :bright_black},
    {:focus, 0xFF6A1A, 208, :bright_yellow},
    {:disabled, 0x5E5D5A, 240, :bright_black},
    {:stale, 0xF5B400, 220, :bright_yellow},
    {:accent, 0xFF6A1A, 208, :bright_yellow},
    {:assistant, 0xFF6A1A, 208, :bright_yellow},
    {:success, 0x3DDC5A, 41, :bright_green},
    {:warning, 0xF5B400, 220, :bright_yellow},
    {:error, 0xFF4D4F, 203, :bright_red},
    {:info, 0x4DA3FF, 75, :bright_blue},
    {:workflow, 0x4DA3FF, 75, :bright_blue},
    {:run_assistant, 0xFF6A1A, 208, :bright_yellow},
    {:run_goal, 0xB08CFF, 141, :bright_magenta},
    {:run_swarm, 0x2FD0B8, 44, :bright_cyan},
    {:run_workflow, 0x4DA3FF, 75, :bright_blue},
    {:run_research, 0xFF9F45, 215, :yellow},
    {:run_consensus_judge, 0xB8E356, 149, :bright_green},
    {:run_ultra, 0x9B5CFF, 135, :bright_magenta},
    {:agent_lane_1, 0x2DD4BF, 44, :cyan},
    {:agent_lane_2, 0xA78BFA, 141, :magenta},
    {:agent_lane_3, 0xF59E0B, 214, :yellow},
    {:agent_lane_4, 0xF472B6, 212, :magenta},
    {:agent_lane_5, 0x38BDF8, 81, :cyan},
    {:key, 0x4DA3FF, 75, :bright_blue}
  ]
  defp caps(mode), do: Capabilities.explicit(%Size{columns: 80, rows: 24}, color_mode: mode)

  test "Carbon foreground roles match the contract in all four modes" do
    for {role, rgb, index, ansi} <- @foregrounds do
      assert Theme.style(role, caps(:truecolor)).foreground.value ==
               {:rgb, div(rgb, 65_536), rem(div(rgb, 256), 256), rem(rgb, 256)}

      assert Theme.style(role, caps(:ansi256)).foreground.value == {:indexed, index}
      assert Theme.style(role, caps(:ansi16)).foreground.value == {:ansi, ansi}
      assert Theme.style(role, caps(:monochrome)).foreground == nil
    end
  end

  test "surface and selection backgrounds degrade without assuming numeric ANSI palettes" do
    for {role, rgb, index, ansi} <- [
          {:canvas, 20, 233, :black},
          {:surface, 25, 234, :black},
          {:card, 30, 235, :bright_black}
        ] do
      assert Theme.style(role, caps(:truecolor)).background.value == {:rgb, rgb, rgb, rgb}
      assert Theme.style(role, caps(:ansi256)).background.value == {:indexed, index}
      assert Theme.style(role, caps(:ansi16)).background.value == {:ansi, ansi}
      assert Theme.style(role, caps(:monochrome)).background == nil
    end

    assert Theme.style(:selection, caps(:truecolor)).foreground.value == {:rgb, 243, 242, 240}
    assert Theme.style(:selection, caps(:truecolor)).background.value == {:rgb, 38, 38, 38}
    assert Theme.style(:selection, caps(:ansi256)).foreground.value == {:indexed, 255}
    assert Theme.style(:selection, caps(:ansi256)).background.value == {:indexed, 236}
    assert :reversed in Theme.style(:selection, caps(:ansi16)).modifiers
  end

  test "focus selection disabled and stale carry words and neutral structural cues" do
    for {role, word, cues} <- [
          {:focus, "FOCUS >", []},
          {:selection, "SELECTED >", []},
          {:disabled, "[DISABLED]", [:reason_required]},
          {:stale, "[STALE]", [:border]}
        ] do
      style = Theme.style(role, caps(:monochrome))
      assert SafeText.value(style.prefix) == word
      assert Enum.all?(cues, &(&1 in style.cues))
      refute style.modifiers == [:dim]
      if role in [:focus, :selection], do: assert(:reversed in style.modifiers)
    end

    assert :separator in Theme.style(:surface, caps(:monochrome)).cues
    assert :border in Theme.style(:card, caps(:monochrome)).cues
  end

  test "seven run kinds and five agent lanes always include their unique ASCII identity" do
    kinds = [:assistant, :goal, :swarm, :workflow, :research, :consensus_judge, :ultra]

    for mode <- [:truecolor, :ansi256, :ansi16, :monochrome] do
      assert Enum.map(kinds, fn kind ->
               {prefix, role} = Theme.run_kind(kind)
               assert role in Theme.roles()
               SafeText.value(prefix)
             end) == ~w(A G S W R C U)

      assert Enum.map(1..5, fn lane ->
               {prefix, role} = Theme.agent_lane(lane)
               assert SafeText.value(Theme.style(role, caps(mode)).prefix) == "A#{lane}"
               SafeText.value(prefix)
             end) == ~w(A1 A2 A3 A4 A5)

      for kind <- kinds do
        {prefix, role} = Theme.run_kind(kind)
        assert Theme.style(role, caps(mode)).prefix == prefix
      end
    end

    assert_raise FunctionClauseError, fn -> apply(Theme, :run_kind, [:unknown]) end
    assert_raise FunctionClauseError, fn -> Theme.agent_lane(6) end
  end

  test "statuses are base labels only and queued is warning" do
    for {state, word, tone} <- [
          {:connecting, "CONNECTING", :info},
          {:empty, "EMPTY", :text_muted},
          {:loading, "LOADING", :info},
          {:running, "RUNNING", :accent},
          {:streaming, "STREAMING", :accent},
          {:queued, "QUEUED", :warning},
          {:waiting_question, "NEEDS ANSWER", :warning},
          {:waiting_approval, "NEEDS APPROVAL", :warning},
          {:paused, "PAUSED", :warning},
          {:retrying, "RETRYING", :warning},
          {:done, "DONE", :success},
          {:failed, "FAILED", :error},
          {:stopped, "STOPPED", :text_muted},
          {:interrupted, "INTERRUPTED", :warning},
          {:stale, "STALE", :stale},
          {:resyncing, "RESYNCING", :info},
          {:disconnected, "DISCONNECTED", :error},
          {:superseded, "SUPERSEDED", :text_muted},
          {:mutation_pending, "PENDING", :info}
        ] do
      assert {label, ^tone} = Theme.status(state)
      assert SafeText.value(label) == word
    end

    assert_raise FunctionClauseError, fn -> apply(Theme, :status, [:unknown]) end
  end

  test "every style remains a closed renderer-neutral Scene value" do
    for role <- Theme.roles(), mode <- [:truecolor, :ansi256, :ansi16, :monochrome] do
      style = Theme.style(role, caps(mode))
      assert %Style{role: ^role} = style
      refute :underlined in style.modifiers
      scene = ContractFixtures.minimal_scene(SafeText.chrome(:main))
      [region] = scene.regions

      scene = %{
        scene
        | regions: [
            %{
              region
              | blocks: [
                  %Block.RichText{spans: [%Span{text: SafeText.chrome(:main), style: style}]}
                ]
            }
          ]
      }

      assert Scene.validate(scene) == :ok
    end

    assert Enum.sort(Theme.roles()) == Enum.sort(Style.roles())
    assert_raise FunctionClauseError, fn -> Theme.style(:invented, caps(:truecolor)) end

    for value <- [{:rgb, 256, 0, 0}, {:indexed, -1}, {:ansi, :made_up}, "\e[31m"] do
      refute Color.valid?(struct!(Color, role: :default, value: value))
    end
  end
end
