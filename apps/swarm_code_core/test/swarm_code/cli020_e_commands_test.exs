defmodule SwarmCode.Cli020ECommandsTest do
  # cli020 E2 (parity-7, Q6) and E3 (bugs-7, ux-live-9, tui-code-14,
  # decisions 4f/4h): the honest Ultra words and the new registry rows.
  use ExUnit.Case, async: true

  alias SwarmCode.Commands

  defp desc(name), do: Enum.find(Commands.catalogue("/"), &(&1.name == name)).desc

  describe "E2 honest Ultra" do
    test "the mode hint and the /ultra description say workflows here, missions in the app" do
      {"ultra", "Ultra", _glyph, hint, _icon} = List.keyfind(Commands.modes(), "ultra", 0)
      assert hint == "big tasks run as workflows (missions are in the ncode app)"

      assert desc("ultra") ==
               "Toggle Ultra — big tasks run as workflows here; missions are in the ncode app for now"
    end
  end
end
