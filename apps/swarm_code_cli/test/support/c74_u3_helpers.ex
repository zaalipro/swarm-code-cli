defmodule SwarmCodeCLI.UI.C74U3Helpers do
  @moduledoc """
  cli74 U3: drive the settings layer against `Fake.Settings` (Appendix A)
  and read a section's rows, requests and screen text.
  """

  import SwarmCodeCLI.UI.Pass73Helpers

  alias SwarmCodeCLI.UI.{Projector, Reducer, SafeText}
  alias SwarmCodeCLI.UI.DataSource.Delivery
  alias SwarmCodeCLI.UI.DataSource.Fake.Settings, as: FakeSettings
  alias SwarmCodeCLI.UI.DataSource.Request
  alias SwarmCodeCLI.UI.Settings.{Nav, Row}

  def act(state, action), do: Reducer.update(state, action)
  def act!(state, action), do: elem(act(state, action), 0)
  def verb(state, verb), do: act(state, {:settings, {:verb, verb}})

  def sent(effects),
    do: for({kind, %Request{} = request} <- effects, kind in [:query, :command], do: request)

  def params(%Request{kind: {_op, params}}), do: params

  @doc "Answers every settings request in `effects` from the fake store, until none is left."
  def serve({state, effects}, fake), do: serve(state, effects, fake)

  def serve(state, effects, fake) do
    case sent(effects) do
      [] ->
        {state, fake}

      requests ->
        {state, fake, more} =
          Enum.reduce(requests, {state, fake, []}, fn request, {acc, fake, more} ->
            {fake, body, _facts} =
              case request.kind do
                {:settings_query, _} -> FakeSettings.query(fake, request)
                {:settings_command, _} -> FakeSettings.command(fake, request)
              end

            {acc, next} = deliver(acc, request, body)
            {acc, fake, more ++ next}
          end)

        serve(state, more, fake)
    end
  end

  def deliver(state, request, body) do
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

  @doc "The layer open at `section` with the fake's answers delivered."
  def opened(section, opts \\ []) do
    fake = Keyword.get(opts, :fake, FakeSettings.seed())
    state = Keyword.get(opts, :state, ready())
    state = Map.merge(state, Map.new(Keyword.get(opts, :put, [])))
    state |> act({:settings_open, {:section, section}}) |> serve(fake)
  end

  def rows(state), do: Nav.rows(state)
  def row(state, id), do: Enum.find(Nav.rows(state), &(&1.id == id))
  def key_row(state, key), do: row(state, "key:" <> key)

  def words(%Row{} = row), do: words(row.value)
  def words(segments) when is_list(segments), do: Enum.map_join(segments, "", &elem(&1, 0))

  def all_words(%Row{} = row) do
    [row.label, words(row.value), words(row.tag)]
    |> Kernel.++(Enum.map(row.lines, &words/1))
    |> Kernel.++(Enum.map(row.columns || [], &elem(&1, 0)))
    |> Enum.join(" ")
  end

  def page_text(state), do: state |> rows() |> Enum.map_join("\n", &all_words/1)

  @doc "Focuses the row with `id` and presses a settings verb on it."
  def press(state, id, verb) do
    state |> Nav.put_cursor(id) |> verb(verb)
  end

  def screen(state) do
    {scene, _actions} = Projector.project(state)

    scene.regions
    |> Enum.flat_map(& &1.blocks)
    |> Enum.map_join("\n", fn block ->
      Enum.map_join(block.spans, "", &SafeText.value(&1.text))
    end)
  end

  def commands(effects, action) do
    for request <- sent(effects),
        match?({:settings_command, _}, request.kind),
        params(request)["action"] == action,
        do: params(request)
  end
end
