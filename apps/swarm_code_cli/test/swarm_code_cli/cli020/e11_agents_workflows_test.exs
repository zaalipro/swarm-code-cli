defmodule SwarmCodeCLI.Cli020.E11AgentsWorkflowsTest do
  # cli020 E11 (ux-live-7): /workflows shows a workflow's description and its
  # arguments (`query (required) · angles=4 · sources=6`), never its program
  # or meta JSON; /agents is a two-column list (name · description) without
  # Markdown asterisks; both word-wrap; a workflow offers one Start.
  use ExUnit.Case, async: true

  import SwarmCodeCLI.Cli020EHelpers

  alias SwarmCodeCLI.UI.{Capabilities, Init, Library, Reducer, Size}
  alias SwarmCodeCLI.UI.DataSource.DTO

  @meta ~s({ "meta": { "args": { "sources": { "default": 6, "type": "integer", "doc": "Sources to read deeply" }, "query": { "type": "string", "doc": "The research question", "required": true }, "angles": { "default": 4, "type": "integer" } }, "name": "research", "description": "One-pass research" } })

  defp library(columns, item) do
    size = %Size{columns: columns, rows: 30}

    {state, _} =
      Reducer.init(%Init{size: size, capabilities: %Capabilities{size: size}, source_epoch: "e"})

    {state, [{:query, request}]} = Reducer.update(state, {:open_layer, {:library, :workflows}})

    body = %DTO.LibrarySnapshot{
      feature: :workflows,
      title: "Workflows",
      request_id: request.request_id,
      items: [item],
      covered_ids: [item.id]
    }

    {state, []} = Library.response(state, request, body)
    {state, _} = Reducer.update(state, {:library_select, item.id})
    state
  end

  @research %DTO.LibraryItem{
    id: "research",
    title: "research",
    subtitle: "",
    status: "available",
    detail:
      "One-pass research inside this conversation: sweep a few angles, read the best pages, write research.md into the project " <>
        @meta,
    actions: [:start],
    form: %DTO.FeatureForm{submit_label: "Start", fields: []}
  }

  test "a workflow's detail is its description and its arguments, word-wrapped" do
    text = library(80, @research) |> screen_text()
    refute text =~ "\"meta\""
    refute text =~ "{"
    assert text =~ "query (required) · angles=4 · sources=6"
    refute text =~ ~r/resear\s*\n\s*ch/
    assert text =~ "sweep a few"
  end

  test "one Start action" do
    state = library(80, @research)
    labels = for {_id, label, _action} <- Library.controls(state), do: label
    assert Enum.count(labels, &(&1 == "Start")) == 1
  end

  test "/agents is a two-column list without Markdown" do
    report =
      "- **implementer** (bundled) — Writes and edits code to complete a task\n" <>
        "- **reviewer** (bundled) — Code reviewer that reads changes and reports issues\n" <>
        "- **scout** (bundled) — Read-only explorer that searches code and reports findings"

    state = fixture(:chat, {80, 24})

    state = %{
      state
      | layers: [{:command_report, "r1"}],
        focus: "dialog",
        command_report: %{title: "Agents", text: report}
    }

    text = screen_text(state)
    refute text =~ "**"
    assert text =~ ~r/implementer \(bundled\)\s{2,}Writes and edits code/
    refute text =~ ~r/issu\s*│?\s*\n/
    assert text =~ "reports"
  end
end
