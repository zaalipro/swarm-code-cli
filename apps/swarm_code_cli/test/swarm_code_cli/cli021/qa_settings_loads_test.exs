defmodule SwarmCodeCLI.Cli021.QaSettingsLoadsTest do
  @moduledoc """
  cli021 qa (found live): the daemon runs at most four settings jobs per
  session (`Settings.Jobs.pool/0`) and refuses the fifth with "data source
  admission capacity exceeded". Models & effort asks for seven loads at once
  (U3 added the price rows), so some were refused, never asked again on that
  page, and the context window rows read "…" for good. The layer now keeps at
  most three loads on their way (one job left for a write) and asks for the
  rest as answers arrive.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers, only: [ready: 0]

  alias SwarmCodeCLI.UI.Reducer
  alias SwarmCodeCLI.UI.DataSource.{Delivery, Request}
  alias SwarmCodeCLI.UI.DataSource.Fake.Settings, as: FakeSettings
  alias SwarmCodeCLI.UI.Settings.Wire

  defp act(state, action), do: Reducer.update(state, action)

  defp sent(effects),
    do: for({kind, %Request{} = request} <- effects, kind in [:query, :command], do: request)

  defp loads_in_flight(state),
    do:
      Enum.count(state.settings.requests, fn {_ref, meta} ->
        is_map(meta) and meta[:kind] == :load
      end)

  # Answers one request at a time (the oldest first), checking the bound
  # after every answer, until nothing is left.
  defp serve(state, queue, fake, max_seen) do
    assert loads_in_flight(state) <= 3

    case queue do
      [] ->
        {state, fake, max_seen}

      [request | rest] ->
        {fake, body, _facts} =
          case request.kind do
            {:settings_query, _} -> FakeSettings.query(fake, request)
            {:settings_command, _} -> FakeSettings.command(fake, request)
          end

        {state, effects} = deliver(state, request, body)
        serve(state, rest ++ sent(effects), fake, max(max_seen, loads_in_flight(state)))
    end
  end

  defp deliver(state, request, body) do
    act(
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
         body: body
       }}
    )
  end

  test "Models & effort never has more than three loads on their way, and gets them all" do
    {state, effects} = act(ready(), {:settings_open, {:section, :models_effort}})
    first = sent(effects)
    assert length(first) <= 3

    {state, _fake, max_seen} = serve(state, first, FakeSettings.seed(), length(first))
    assert max_seen <= 3

    # Every load of the page arrived: nothing is left to ask.
    assert {_state, []} = Wire.sync(state)
    assert Map.has_key?(state.settings.data.records, {"pricing_rows", %{}})
    assert state.settings.data.overview != nil
  end
end
