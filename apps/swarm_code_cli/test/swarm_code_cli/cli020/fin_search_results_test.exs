defmodule SwarmCodeCLI.Cli020.FinSearchResultsTest do
  # cli020 finisher (C8 + E9, tui-code-11): the answer of `/search <words>`
  # with hits is kept as `state.search_results` and opens the palette on its
  # "?" rows, whose Enter opens the hit's conversation; no hits stays the
  # report that says so.
  use ExUnit.Case, async: true

  import SwarmCodeCLI.Test.Cli020State

  alias SwarmCodeCLI.UI.{Reducer, Switcher}
  alias SwarmCodeCLI.UI.DataSource.{DTO, Delivery}

  @hit "7a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"

  defp searched(rows) do
    {state, effects} = ready() |> type("/search router") |> send_draft()
    [request] = for {:command, request} <- effects, do: request

    Reducer.update(
      state,
      {:data,
       %Delivery{
         kind: :response,
         watch_ref: nil,
         request_id: request.request_id,
         scope: request.scope,
         generation: request.generation,
         revision: nil,
         sequence: nil,
         body: %DTO.Outcome{
           request_id: request.request_id,
           status: :accepted,
           feedback: %DTO.Feedback{
             kind: :report,
             title: "Search: router",
             text: "**Fix the router**\nthe router drops\n/resume 7a1b2c3d",
             subject: :search,
             rows: rows,
             conversation_id: nil
           }
         }
       }}
    )
  end

  test "hits open the palette on the ? rows; Enter opens the conversation" do
    row = %DTO.FeedbackRow{conversation_id: @hit, title: "Fix the router", snippet: "drops"}
    {state, _effects} = searched([row])

    assert %{query: "router", options: [_]} = state.search_results
    assert [{:switcher, _} | _] = state.layers
    entries = Switcher.visible(state)
    assert [%{target: {:local, {:open_conversation, @hit}}, title: "Fix the router"}] = entries
  end

  test "no hits keeps the report" do
    {state, _effects} = searched([])
    assert state.search_results == nil
    assert [{:command_report, _} | _] = state.layers
  end
end
