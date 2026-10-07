defmodule SwarmCodeCLI.Cli020.E22SchedulesNoteTest do
  # cli020 E22 (tui-code-12): the Schedules library says, first, that tasks
  # fire only while the ncode app runs, also after a save.
  use ExUnit.Case, async: true

  import SwarmCodeCLI.Cli020EHelpers

  alias SwarmCodeCLI.UI.{Capabilities, Init, Library, Reducer, Size}
  alias SwarmCodeCLI.UI.DataSource.DTO

  @note "Scheduled tasks fire only while the ncode app is running. Run now works here."

  defp library(feature, items) do
    size = %Size{columns: 120, rows: 30}

    {state, _} =
      Reducer.init(%Init{size: size, capabilities: %Capabilities{size: size}, source_epoch: "e"})

    {state, [{:query, request}]} = Reducer.update(state, {:open_layer, {:library, feature}})
    body = %DTO.LibrarySnapshot{feature: feature, request_id: request.request_id, items: items}
    {state, []} = Library.response(state, request, body)
    state
  end

  defp prose(state) do
    state
    |> screen_text()
    |> String.split("\n")
    |> Enum.flat_map(&(Regex.run(~r/│(.*)│/u, &1, capture: :all_but_first) || []))
    |> Enum.map_join(" ", &String.trim/1)
    |> String.replace(~r/\s+/u, " ")
  end

  test "the note leads the schedules list, empty or not" do
    assert prose(library(:schedules, [])) =~ @note
    item = %DTO.LibraryItem{id: "t", title: "Daily", status: "on", actions: [:toggle]}
    text = prose(library(:schedules, [item]))
    assert text =~ @note
    [before, _] = String.split(text, "Daily", parts: 2)
    assert before =~ @note
  end

  test "and after a save (the library's message)" do
    state = library(:schedules, [])
    state = put_in(state.library.message, "Saved.")
    assert prose(state) =~ @note
  end

  test "other libraries do not carry it" do
    refute prose(library(:workflows, [])) =~ "Scheduled tasks fire"
  end
end
