defmodule SwarmCodeCLI.Cli020.E16DialogSizesTest do
  # cli020 E16 (ux-live-19, bugs-6 UI) at 80x24: message dialogs are as tall
  # as their words and one action row; Quit says `Enter/X quit · Esc cancel`;
  # `/cost` draws its per-model rows and the total; empty states say what to
  # do; the open desktop app is a persistent warning.
  use ExUnit.Case, async: true

  import SwarmCodeCLI.Cli020EHelpers

  alias SwarmCodeCLI.UI.{Capabilities, Init, Library, Reducer, Size}
  alias SwarmCodeCLI.UI.DataSource.DTO
  alias SwarmCodeCLI.UI.Pass73Helpers, as: H

  defp box(text) do
    rows = String.split(text, "\n")
    top = Enum.find_index(rows, &(&1 =~ "┌"))
    bottom = Enum.find_index(rows, &(&1 =~ "└"))
    assert top && bottom, text
    Enum.slice(rows, top..bottom)
  end

  defp live_quit do
    state = H.ready([%{H.run("s", :running) | created_sequence: 1}], columns: 80, rows: 24)

    %{
      state
      | layers: [{:unsent_changes, :detach}],
        focus: "cancel",
        exit_pending: :detach
    }
    |> Map.put(:quit_live_runs, 1)
  end

  test "the quit dialog: its sentence and one action row" do
    rows = live_quit() |> screen_text() |> box()
    text = Enum.join(rows, "\n")
    assert length(rows) <= 6, text
    assert text =~ "Stop 1 live run and quit?"
    assert text =~ "Enter/X quit"
    assert text =~ "Esc cancel"
    refute text =~ "Enter chooses"
    refute text =~ "CONFIRM EXIT"
    assert Enum.any?(rows, &(&1 =~ "Enter/X quit" and &1 =~ "Esc cancel")), text
  end

  test "/cost draws the per-model rows and the total" do
    state = fixture(:chat, {80, 24})

    report = %{
      title: "Cost",
      text: "$0.05 for 2 runs: 15k tokens in, 4k out.",
      rows: [
        %{model: "deepseek-v4-pro", tokens_in: 12_000, tokens_out: 3_000, cost_usd: 0.04},
        %{model: "claude-sonnet-5", tokens_in: 3_000, tokens_out: 1_000, cost_usd: nil}
      ]
    }

    state = %{state | layers: [{:command_report, "r"}], focus: "cancel", command_report: report}
    text = state |> screen_text() |> box() |> Enum.join("\n")
    assert text =~ ~r/deepseek-v4-pro\s+12k in · 3k out\s+\$0\.04/
    assert text =~ ~r/claude-sonnet-5\s+3k in · 1k out\s+—/
    assert text =~ ~r/Total\s+15k in · 4k out\s+\$0\.04/
    assert length(box(screen_text(state))) <= 9
  end

  test "empty checkpoints say when they are taken" do
    size = %Size{columns: 80, rows: 24}

    {state, _} =
      Reducer.init(%Init{size: size, capabilities: %Capabilities{size: size}, source_epoch: "e"})

    {state, [{:query, request}]} = Reducer.update(state, {:open_layer, {:library, :checkpoints}})

    body = %DTO.LibrarySnapshot{
      feature: :checkpoints,
      title: "Checkpoints",
      request_id: request.request_id,
      items: []
    }

    {state, []} = Library.response(state, request, body)
    assert screen_text(state) =~ "No checkpoints yet: they are taken before each edit."
  end

  test "an empty runs dashboard says how to start" do
    state = fixture(:chat, {80, 24})

    state = %{
      state
      | read_model: %{state.read_model | runs: %{}},
        layers: [{:runs_dashboard, "d"}],
        focus: "dialog"
    }

    assert screen_text(state) =~ "Nothing has run yet: send a message, or /swarm <task>."
  end

  test "the open desktop app is a persistent warning" do
    state = H.ready([%{H.run("s", :done) | created_sequence: 1}], columns: 120, rows: 30)
    refute screen_text(state) =~ "The ncode app is open"
    text = state |> put_workspace(desktop_running: true) |> screen_text()
    assert text =~ "The ncode app is open on the same database."
    assert text =~ "Ctrl-C twice"
  end
end
