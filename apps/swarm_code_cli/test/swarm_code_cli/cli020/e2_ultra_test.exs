defmodule SwarmCodeCLI.Cli020.E2UltraTest do
  # cli020 E2 (parity-7, Q6): the status chip and the help sheet say
  # `Ultra · workflows`; CLI Ultra runs workflows, missions are the app's.
  use ExUnit.Case, async: true

  import SwarmCodeCLI.Cli020EHelpers

  test "the status chip says Ultra · workflows" do
    state = fixture(:chat, {120, 30}) |> put_workspace(mode: :ultra)
    assert List.last(screen(state)) =~ "Ultra · workflows"
  end

  test "the status chip of other modes is unchanged" do
    state = fixture(:chat, {120, 30}) |> put_workspace(mode: :plan)
    row = List.last(screen(state))
    assert row =~ "Plan"
    refute row =~ "workflows"
  end

  test "the help sheet lists the modes, Ultra as Ultra · workflows" do
    state = fixture(:chat, {170, 40})

    state = %{
      state
      | focus: "dialog",
        layers: [:help],
        layer_contexts: [%{focus: "main", hidden_focus: nil}]
    }

    text = state |> SwarmCodeCLI.UI.Projector.Dialog.help_lines(160) |> Enum.join("\n")
    assert text =~ "Modes"
    assert text =~ ~r/Ultra · workflows\s+big tasks run as workflows/
  end
end
