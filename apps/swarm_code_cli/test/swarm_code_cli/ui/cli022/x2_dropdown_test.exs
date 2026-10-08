defmodule SwarmCodeCLI.UI.Cli022.X2DropdownTest do
  @moduledoc """
  cli022 F2/F3: the argument dropdown lists `default` for both effort
  commands, opens with its cursor on the current value and marks it with a
  muted `●` before the description (no "(current)" words).
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers

  alias SwarmCodeCLI.UI.{Input, SafeText, SlashPalette}
  alias SwarmCodeCLI.UI.Projector.Composer

  defp workspace(state, fields) do
    workspace = Map.merge(state.read_model.snapshots.workspace, Map.new(fields))

    %{
      state
      | read_model: %{
          state.read_model
          | snapshots: Map.put(state.read_model.snapshots, :workspace, workspace)
        }
    }
  end

  defp base(fields \\ []) do
    workspace(
      ready(),
      [
        effort_levels: ~w(low medium high),
        effort: "medium",
        swarm_effort_levels: ~w(low high),
        swarm_effort: nil,
        approval_mode: :auto
      ] ++ fields
    )
  end

  defp texts(state), do: Enum.map(SlashPalette.entries(state), & &1.text)

  defp lines(state) do
    for block <- Composer.slash_popup(state, 100),
        do: Enum.map_join(block.spans, "", &SafeText.value(&1.text))
  end

  test "both effort commands list default first" do
    assert texts(type(base(), "/effort ")) ==
             ["effort default", "effort low", "effort medium", "effort high"]

    assert texts(type(base(), "/worker_effort ")) ==
             ["worker_effort default", "worker_effort low", "worker_effort high"]

    assert texts(type(base(), "/effort d")) == ["effort default"]
  end

  test "default is the current row while no effort is set, a level otherwise" do
    current = fn state ->
      for %{current?: true, value: v} <- SlashPalette.entries(state), do: v
    end

    assert current.(type(base(), "/effort ")) == ["medium"]
    assert current.(type(base(), "/worker_effort ")) == ["default"]
    assert current.(type(base(effort: nil), "/effort ")) == ["default"]
  end

  test "the default row names the level in effect when the daemon reports it" do
    state = type(base(effort: nil, effective_effort: "medium"), "/effort ")
    assert %{desc: desc} = Enum.find(SlashPalette.entries(state), &(&1.value == "default"))
    assert desc =~ "medium"
  end

  test "the cursor opens on the current value, not the first row" do
    state = type(base(), "/effort ")
    assert SlashPalette.selected(state).text == "effort medium"

    assert type(base(), "/worker_effort ") |> SlashPalette.selected() |> Map.get(:text) ==
             "worker_effort default"

    assert type(base(), "/panel ") |> SlashPalette.selected() |> Map.get(:value) == "full"
  end

  test "with nothing current the cursor stays on the first row; the typed filter re-aims it" do
    assert type(base(), "/theme ") |> SlashPalette.selected() |> Map.get(:text) == "theme dark"
    assert type(base(), "/effort h") |> SlashPalette.selected() |> Map.get(:text) == "effort high"
  end

  test "arrows move from the current row, Enter on an untouched list re-runs the current value" do
    state = type(base(), "/effort ") |> press!(Input.key(:down))
    assert SlashPalette.selected(state).text == "effort high"
    state = type(base(), "/effort ") |> press!(Input.key(:up))
    assert SlashPalette.selected(state).text == "effort low"

    {_state, effects} = type(base(), "/effort ") |> press(Input.key(:enter))
    assert [%{kind: {:dispatch, :send, "/effort medium", :main, []}}] = requests(effects)
  end

  test "Enter on the default row sends /effort default" do
    state = type(base(), "/effort ") |> press!(Input.key(:up)) |> press!(Input.key(:up))
    assert SlashPalette.selected(state).text == "effort default"
    {_state, effects} = press(state, Input.key(:enter))
    assert [%{kind: {:dispatch, :send, "/effort default", :main, []}}] = requests(effects)
  end

  test "the popup marks the current row with a dot, never with the words" do
    rows = lines(type(base(), "/effort "))
    assert Enum.any?(rows, &(&1 =~ "●"))
    refute Enum.any?(rows, &(&1 =~ "(current)"))
    [marked] = Enum.filter(rows, &(&1 =~ "●"))
    assert marked =~ "/effort medium"
    # the other rows keep a blank mark slot, so the descriptions line up
    [unmarked] = Enum.filter(rows, &(&1 =~ "Quick"))
    column = fn line, word -> line |> String.split(word) |> hd() |> String.length() end
    assert column.(marked, "Balanced") == column.(unmarked, "Quick")
  end

  test "command rows (no argument list) carry no mark slot" do
    rows = lines(type(base(), "/pan"))
    refute Enum.any?(rows, &(&1 =~ "●"))
  end
end
