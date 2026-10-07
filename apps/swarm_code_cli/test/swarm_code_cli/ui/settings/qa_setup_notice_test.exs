defmodule SwarmCodeCLI.UI.Settings.QaSetupNoticeTest do
  @moduledoc """
  cli020 live QA (B12): bare `ncode` with no provider opens Settings ›
  Providers and the daemon sends the toast "Add a model provider to start:
  pick a preset, paste its key." The settings page covers the status row
  that draws daemon toasts, so the words never showed. The settings message
  row now shows the daemon's newest toast for its few seconds, and a toast
  whose text already starts with its title says the title once.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.C75Helpers
  import SwarmCodeCLI.UI.C74U3Helpers, only: [opened: 2]

  alias SwarmCodeCLI.UI.DataSource.DTO
  alias SwarmCodeCLI.UI.Pass73Helpers
  alias SwarmCodeCLI.UI.Projector.Settings.Chrome
  alias SwarmCodeCLI.UI.Settings.{Glyphs, Grid}

  @words "Add a model provider to start: pick a preset, paste its key."

  defp with_toast(state, toast) do
    toast = %DTO.Toast{toast | at: state.now}
    %{state | read_model: %{state.read_model | toasts: [toast]}}
  end

  defp message(state) do
    glyphs = &Glyphs.for_caps(&1, state.capabilities)
    state |> Chrome.message(Grid.for(160, 45), glyphs, nil) |> Enum.map_join(&elem(&1, 0))
  end

  defp providers do
    {state, _fake} =
      opened(:providers, state: rich(Pass73Helpers.ready([], columns: 160, rows: 45)))

    %{state | now: 1_000_000}
  end

  test "the settings message row says the daemon's setup toast" do
    state = with_toast(providers(), %DTO.Toast{id: "t1", title: "First run", text: @words})
    assert message(state) =~ "First run · " <> @words
  end

  test "an old toast is not shown" do
    state = with_toast(providers(), %DTO.Toast{id: "t1", title: "First run", text: @words})
    state = %{state | now: state.now + 60_000}
    refute message(state) =~ @words
  end

  test "a text that starts with its title says the title once" do
    text = "First run: added the provider 127.0.0.1 from your settings."
    state = with_toast(providers(), %DTO.Toast{id: "t2", title: "First run", text: text})
    assert message(state) =~ text
    refute message(state) =~ "First run · First run"
  end
end
