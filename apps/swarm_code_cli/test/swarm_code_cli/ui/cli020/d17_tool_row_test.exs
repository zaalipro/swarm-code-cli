defmodule SwarmCodeCLI.UI.Cli020.D17ToolRowTest do
  @moduledoc "cli020 D17 (ux-live-12): Enter and o on a tool row open its full output."
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers

  alias SwarmCodeCLI.UI.{Input, Keymap}
  alias SwarmCodeCLI.UI.DataSource.DTO

  defp on_tool(detail_ref) do
    state = ready([run("r1", :done)])

    item =
      struct!(DTO.TranscriptItem,
        id: "t1",
        run_id: "r1",
        kind: :tool,
        text: "ok",
        detail_ref: detail_ref
      )

    model = %{state.read_model | transcript: Map.put(state.read_model.transcript, "t1", item)}
    %{state | read_model: model, focus: "main", selection: Map.put(state.selection, "main", "t1")}
  end

  test "Enter and o open the output of a tool row that is not cut (no drawn target)" do
    state = on_tool(%{id: "ref1"})

    for key <- [Input.key(:enter), Input.text_fragment(:press, "o", [])] do
      assert {:ok, {:open_detail, "r1", "ref1"}} = Keymap.resolve(key, state, %{})
    end
  end

  test "with nothing to open Enter and o do nothing" do
    state = on_tool(nil)
    assert :ignore = Keymap.resolve(Input.key(:enter), state, %{})
    assert :ignore = Keymap.resolve(Input.text_fragment(:press, "o", []), state, %{})
  end
end
