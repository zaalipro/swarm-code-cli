defmodule SwarmCodeCLI.UI.R1019LaunchPrefsTest do
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{Capabilities, Init, Reducer, Size}
  alias SwarmCodeCLI.UI.Layout.Preferences

  defp init_state(prefs) do
    size = %Size{columns: 120, rows: 30}

    {state, _effects} =
      Reducer.init(%Init{
        size: size,
        capabilities: %Capabilities{size: size},
        source_epoch: "e",
        now: 0,
        prefs: prefs
      })

    state
  end

  test "C-FEAT-14: the saved composer height and inspector width apply at launch" do
    state = init_state(%{"composer_rows" => 6, "inspector_width" => "wide"})

    assert state.composer_height == 6
    assert state.preferences.composer_height == 6

    assert state.preferences.inspector_width ==
             Preferences.preset(%Preferences{}, :inspector, :wide).inspector_width
  end

  test "C-FEAT-14: missing or out-of-range values keep the launch defaults" do
    state = init_state(%{"composer_rows" => 99, "inspector_width" => "bogus"})

    assert state.composer_height in 1..8
    assert state.preferences.inspector_width == %Preferences{}.inspector_width

    default = init_state(%{})
    assert default.composer_height == 3
    assert default.preferences.inspector_width == %Preferences{}.inspector_width
  end
end
