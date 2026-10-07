defmodule SwarmCodeCLI.Cli020.E25ResearchLevelsTest do
  # cli020 E25 (tui-code-21): the research levels in words; the stored
  # value stays the atom.
  use ExUnit.Case, async: true

  import SwarmCodeCLI.Cli020EHelpers

  alias SwarmCodeCLI.UI.{Capabilities, Init, Library, Reducer, Size}
  alias SwarmCodeCLI.UI.DataSource.DTO

  defp form do
    size = %Size{columns: 120, rows: 30}

    {state, _} =
      Reducer.init(%Init{size: size, capabilities: %Capabilities{size: size}, source_epoch: "e"})

    {state, [{:query, request}]} = Reducer.update(state, {:open_layer, {:library, :research}})
    body = %DTO.LibrarySnapshot{feature: :research, request_id: request.request_id, items: []}
    {state, []} = Library.response(state, request, body)
    {state, _} = Reducer.update(state, {:open_layer, {:research_form, "research-form"}})
    state
  end

  test "Fastest · about a minute, Standard, Deep, Ultra" do
    text = screen_text(form())
    assert text =~ "Fastest · about a minute"
    assert text =~ "Standard"
    assert text =~ "Deep"
    assert text =~ "Ultra"
    refute text =~ ~r/\b(low|medium|high)\b/
  end

  test "choosing a level stores the atom" do
    {state, _} = Reducer.update(form(), {:research_depth, :high})
    assert Map.get(state.selection, {:research_form, :depth}) == :high
    assert screen_text(state) =~ "› Deep"
  end
end
