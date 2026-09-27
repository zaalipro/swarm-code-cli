defmodule SwarmCodeCLI.UI.Settings.C75StrataTest do
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.Scene.Style
  alias SwarmCodeCLI.UI.Settings.Strata

  @table [
    {:session, :agent_lane_1},
    {:project, :agent_lane_2},
    {:project_file, :agent_lane_2},
    {:env, :agent_lane_4},
    {:flag, :agent_lane_5},
    {:cli, :run_consensus_judge},
    {:global, :text_muted},
    {:default, :text_faint},
    {nil, :text_faint}
  ]

  test "every layer has its stratum hue (R21.4)" do
    for {layer, role} <- @table do
      assert Strata.role(layer) == role, inspect(layer)
    end

    assert Strata.role(:something_else) == :text_faint
  end

  test "every returned role is a Scene role (no new role, D3)" do
    for {layer, _} <- @table do
      assert Strata.role(layer) in Style.roles()
    end

    assert :warning in Style.roles()
  end

  test "an attention row's spine is amber; otherwise the layer's hue" do
    assert Strata.spine_role(%{marks: [:attention], layer: :env}) == :warning
    assert Strata.spine_role(%{marks: [:changed], layer: :env}) == :agent_lane_4
    assert Strata.spine_role(%{marks: [], layer: nil}) == :text_faint
  end

  test "set?/1: a layer set the value unless it is the default or unknown" do
    assert Strata.set?(:global)
    assert Strata.set?(:session)
    refute Strata.set?(:default)
    refute Strata.set?(nil)
    refute Strata.set?(:unknown)
  end
end
