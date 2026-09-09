defmodule SwarmCodeCLI.UI.ProjectorModeTest do
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.Projector.Mode
  alias SwarmCodeCLI.UI.{Capabilities, Scroll, Size}
  alias SwarmCodeCLI.UI.Projector.Composer

  test "Ultra mode renders status strings without crashing" do
    state = %{read_model: %{transcript: %{}}, capabilities: %Capabilities{size: %Size{columns: 80, rows: 24}}}
    run = %{id: "run-1", kind: :ultra, state: :running}

    assert [%{first_index: 0, items: items}] = Mode.project(state, run, 80, 10)
    assert items != []
  end

  test "mode content starts at the main scroll anchor" do
    transcript =
      for n <- 1..8, into: %{} do
        {"item-#{n}", %{run_id: "run-1", role: :assistant, text: "- [ ] item #{n}"}}
      end

    state = %{
      read_model: %{transcript: transcript},
      capabilities: %Capabilities{size: %Size{columns: 80, rows: 24}},
      scrolls: %{main: %Scroll{anchor: {"item-5", 0, :top}, follow?: false}}
    }

    run = %{id: "run-1", kind: :goal, state: :running}
    assert [%{first_index: first}] = Mode.project(state, run, 80, 2)
    assert first >= 4
  end

  test "composer names every selectable workspace mode" do
    for {workspace_mode, label} <- [
          {:build, "Build"},
          {:plan, "Plan"},
          {:swarm, "Swarm"},
          {:ultra, "Ultra"},
          {:workflow, "Workflow"},
          {:consensus, "Consensus"},
          {:research, "Research"}
        ] do
      state = %{read_model: %{snapshots: %{workspace: %{mode: workspace_mode}}}}
      assert Composer.mode_label(state) == label
    end
  end
end
