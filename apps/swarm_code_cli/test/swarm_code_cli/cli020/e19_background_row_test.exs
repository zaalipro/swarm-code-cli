defmodule SwarmCodeCLI.Cli020.E19BackgroundRowTest do
  # cli020 E19 (ux-live-12): a command moved to the background says how it
  # ended (C10's `background_state`), not `exit code pending`.
  use ExUnit.Case, async: true

  import SwarmCodeCLI.Cli020EHelpers

  alias SwarmCodeCLI.UI.DataSource.DTO
  alias SwarmCodeCLI.UI.Pass73Helpers, as: H

  defp with_tool(background_state) do
    tool = %DTO.ToolCall{
      name: "run_command",
      title: "run mix test --seed 0",
      status: :done,
      started_at: 1,
      finished_at: 2,
      duration_ms: 18_000,
      files: []
    }

    run = %{H.run("s", :done) | created_sequence: 1}
    pending = "exit code pending ==> file_system Compiling"

    items = [
      item("u", role: :user, text: "Run the tests", node_id: "s"),
      item("t", kind: :tool, tool: tool, text: pending, node_id: "t"),
      item("a", node_id: "s", text: "Done.")
    ]

    state =
      H.ready([run],
        columns: 120,
        rows: 30,
        snapshot: %{transcript: %DTO.TranscriptWindow{items: items}}
      )

    # `background` and C10's `background_state` go on after the DTO
    # validation, as the reducer holds them once C lands.
    state = Map.put(state, :panel_mode, :hidden)

    put_in(
      state.read_model.transcript["t"],
      state.read_model.transcript["t"]
      |> Map.update!(:tool, &Map.put(&1, :background, true))
      |> Map.put(:background_state, background_state)
    )
  end

  defp row(state),
    do: state |> screen() |> Enum.find(&(&1 =~ "mix test --seed 0")) || flunk(screen_text(state))

  for words <- ["exit 0", "killed at quit", "still running", "ended (exit not recorded)"] do
    test "#{words}" do
      row = row(with_tool(unquote(words)))
      assert row =~ unquote(words)
      refute row =~ "exit code pending"
      refute row =~ "background"
    end
  end

  test "without the field the row is as before" do
    assert row(with_tool(nil)) =~ "background"
  end
end
