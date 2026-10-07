defmodule SwarmCodeCLI.UI.Cli020.D16RetryKeyTest do
  @moduledoc "cli020 D16 (ux-live-4): `r` in select mode retries a failed or stopped run."
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers

  alias SwarmCodeCLI.UI.{Input, Keymap}
  alias SwarmCodeCLI.UI.DataSource.DTO

  defp selected(_state, run_state) do
    state = ready([run("r1", run_state)])
    item = struct!(DTO.TranscriptItem, id: "i1", run_id: "r1", text: "answer")
    model = %{state.read_model | transcript: Map.put(state.read_model.transcript, "i1", item)}
    %{state | read_model: model, focus: "main", selection: Map.put(state.selection, "main", "i1")}
  end

  defp r, do: Input.text_fragment(:press, "r", [])

  test "r on a failed or stopped run's item invokes retry_run with its revision" do
    for run_state <- [:failed, :stopped] do
      assert {:ok, {:invoke, {:retry_run, "r1", 3}, _id}} =
               Keymap.resolve(r(), selected(nil, run_state), %{})
    end
  end

  test "r anywhere else still types r into the composer" do
    assert {:ok, {:compose, "r"}} = Keymap.resolve(r(), selected(nil, :done), %{})
  end
end
