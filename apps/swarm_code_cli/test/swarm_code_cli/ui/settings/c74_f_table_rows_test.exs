defmodule SwarmCodeCLI.UI.Settings.C74FTableRowsTest do
  @moduledoc """
  cli74 F15 (A46, found in the sandbox): a table row (a language server, a
  search engine) that is being edited shows the editor on its line; it drew
  its columns and the editor was invisible.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers, only: [ready: 0]

  alias SwarmCodeCLI.UI.{Projector, Reducer, SafeText}
  alias SwarmCodeCLI.UI.DataSource.{Delivery, Request}
  alias SwarmCodeCLI.UI.DataSource.Fake.Settings, as: FakeSettings
  alias SwarmCodeCLI.UI.Reducer.Settings.Ops

  defp serve({state, effects}, fake) do
    for({kind, %Request{} = r} <- effects, kind in [:query, :command], do: r)
    |> Enum.reduce({state, fake}, fn request, {acc, fake} ->
      {fake, body, _} =
        case request.kind do
          {:settings_query, _} -> FakeSettings.query(fake, request)
          {:settings_command, _} -> FakeSettings.command(fake, request)
        end

      delivery = %Delivery{
        kind: :response,
        watch_ref: nil,
        request_id: request.request_id,
        scope: request.scope,
        generation: request.generation,
        revision: nil,
        sequence: nil,
        body: body
      }

      {acc, _} = Reducer.update(acc, {:data, delivery})
      {acc, fake}
    end)
  end

  defp lines(state) do
    {scene, _} = Projector.project(state)

    scene.regions
    |> Enum.flat_map(& &1.blocks)
    |> Enum.map(fn block -> Enum.map_join(block.spans, "", &SafeText.value(&1.text)) end)
  end

  test "Enter on a language shows its command editor on the language's line" do
    {state, _fake} =
      ready()
      |> Reducer.update({:settings_open, {:section, :language_servers}})
      |> serve(FakeSettings.seed())

    before = Enum.find(lines(state), &(&1 =~ "Elixir"))
    assert before =~ ".ex .exs"

    {state, _} = Ops.run(state, [{:edit, "key:lsp.elixir"}])
    assert state.settings.mode == :editing

    line = Enum.find(lines(state), &(&1 =~ "Elixir"))
    refute line =~ ".ex .exs"
    assert line != before
  end
end
