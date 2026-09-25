defmodule SwarmCodeCLI.UI.Settings.C74DataTest do
  @moduledoc """
  cli74 U1-5: the settings layer's data flow against the service's fake
  store (`Fake.Settings`): the open view, per-section loads, daemon value
  writes (`values.patch` with its CAS), `settings_update` re-reads, tasks,
  stale answers after a reopen, a resynced watch, a service that cannot
  answer settings, and an `outcome` reply.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers, only: [ready: 0]

  alias SwarmCodeCLI.UI.{Reducer}
  alias SwarmCodeCLI.UI.DataSource.{Delivery, Delta, DTO, Request}
  alias SwarmCodeCLI.UI.DataSource.Fake.Settings, as: FakeSettings
  alias SwarmCodeCLI.UI.Settings.{Layer, Nav}

  defp act(state, action), do: Reducer.update(state, action)
  defp act!(state, action), do: elem(act(state, action), 0)

  defp sent(effects),
    do: for({kind, %Request{} = request} <- effects, kind in [:query, :command], do: request)

  defp params(%Request{kind: {_op, params}}), do: params

  # Answers every settings request in `effects` from the fake store, and
  # whatever those answers ask for next, until nothing is left.
  defp serve({state, effects}, fake), do: serve(state, effects, fake)

  defp serve(state, effects, fake) do
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

  defp opened(fake \\ FakeSettings.seed()) do
    ready() |> act({:settings_open, {:section, :agents_limits}}) |> serve(fake)
  end

  defp row(state, key), do: Enum.find(Nav.rows(state), &(&1.id == "key:" <> key))
  defp words(segments), do: Enum.map_join(segments, "", &elem(&1, 0))

  test "opening asks for the open view once and fills every section's values" do
    {state, effects} = act(ready(), {:settings_open, {:section, :agents_limits}})
    [request] = sent(effects)
    assert %{"view" => "open"} = params(request)
    assert {:settings, 1, {:q, _ref}} = request.origin

    {state, _fake} = serve(state, effects, FakeSettings.seed())
    layer = state.settings
    assert layer.data.loaded_at != nil
    assert MapSet.member?(layer.data.values_loaded, :agents_limits)
    assert is_binary(layer.data.project_id)

    row = row(state, "limits.max_concurrent_agents")
    assert words(row.value) == "6"
    assert row.state == :normal
    assert row.editor != nil

    # Nothing more is asked while nothing changes.
    {_state, effects} = act(state, {:settings, {:verb, :down}})
    assert sent(effects) == []
  end

  test "a daemon number step writes one values.patch with its CAS; the answer toasts" do
    {state, fake} = opened()
    state = Nav.put_cursor(state, "key:limits.max_concurrent_agents")

    {state, effects} = act(state, {:settings, {:verb, :right}})
    [{:start_timer, timer, 600, _}] = effects
    {state, effects} = act(state, {:settings, {:settle, state.settings.generation, timer}})

    [request] = sent(effects)

    assert %{
             "action" => "values.patch",
             "attributes" => %{
               "changes" => [%{"key" => "limits.max_concurrent_agents", "value" => 7}]
             },
             "expected" => %{"limits.max_concurrent_agents" => 6}
           } = params(request)

    {state, fake, _} =
      Enum.reduce([request], {state, fake, []}, fn request, {acc, fake, _} ->
        {fake, body, facts} = FakeSettings.command(fake, request)
        {acc, _} = deliver(acc, request, body)
        {acc, fake, facts}
      end)

    assert state.settings.status.text == "Max concurrent agents → 7 · next spawn"
    assert [%{label: "Max concurrent agents"}] = state.settings_history.past
    assert state.settings.writes == %{}
    _ = fake
  end

  test "a rejected daemon value shows its message under the row" do
    {state, fake} = opened()
    reply = %{status: :rejected, message: "must be between 1 and 16"}

    {:ok, fake, []} = FakeSettings.control(fake, :fail_next, ["values.patch", reply])
    state = Nav.put_cursor(state, "key:limits.max_concurrent_agents")
    {state, effects} = act(state, {:settings, {:verb, :right}})
    [{:start_timer, timer, _, _}] = effects
    {state, effects} = act(state, {:settings, {:settle, state.settings.generation, timer}})
    [request] = sent(effects)
    {_fake, body, _} = FakeSettings.command(fake, request)
    {state, _} = deliver(state, request, body)
    assert :invalid in row(state, "limits.max_concurrent_agents").marks
    assert state.settings.status.text == "Couldn't save: must be between 1 and 16"
    assert words(row(state, "limits.max_concurrent_agents").value) == "6"
  end

  test "settings_update re-reads the sections it names" do
    {state, _fake} = opened()
    update = %DTO.SettingsUpdate{revision: 99, sections: [:agents_limits], origin: :elsewhere}

    {state, effects} = SwarmCodeCLI.UI.Reducer.Settings.Responses.delta(state, update)
    refute MapSet.member?(state.settings.data.values_loaded, :agents_limits)
    assert Map.has_key?(state.settings.changed_elsewhere, :agents_limits)

    assert [%{"view" => "values", "sections" => ["agents_limits"]}] =
             Enum.map(sent(effects), &params/1)

    # An older revision is ignored.
    stale = %DTO.SettingsUpdate{revision: 3, sections: [:agents_limits], origin: :settings}
    assert {_, []} = SwarmCodeCLI.UI.Reducer.Settings.Responses.delta(state, stale)
  end

  test "a settings_update delivered on the shell watch reaches the layer" do
    {state, _fake} = opened()
    watch = state.watches.shell
    update = %DTO.SettingsUpdate{revision: 50, sections: [:agents_limits], origin: :elsewhere}

    delivery = %Delivery{
      kind: :delta,
      watch_ref: watch.watch_ref,
      request_id: nil,
      scope: watch.scope,
      generation: watch.generation,
      revision: 50,
      sequence: watch.sequence + 1,
      body: %Delta{
        kind: :settings_update,
        body: update,
        sequence: watch.sequence + 1,
        revision: 50
      }
    }

    {state, effects} = act(state, {:data, delivery})
    assert state.settings.data.revision == 50
    assert Enum.any?(sent(effects), &match?(%{"view" => "values"}, params(&1)))
  end

  test "a task's end fetches its result" do
    {state, _fake} = opened()

    task = %DTO.SettingsTask{task_id: "t1", action: "provider.test", state: :done, elapsed_ms: 10}
    {state, effects} = SwarmCodeCLI.UI.Reducer.Settings.Responses.delta(state, task)
    assert %{"state" => :done} = state.settings.tasks["t1"]
    assert [%{"view" => "task", "id" => "t1"}] = Enum.map(sent(effects), &params/1)
  end

  test "an answer for a closed or reopened layer is dropped" do
    {state, effects} = act(ready(), {:settings_open, {:section, :agents_limits}})
    [request] = sent(effects)
    {fake, body, _} = FakeSettings.query(FakeSettings.seed(), request)
    _ = fake

    state = act!(state, {:settings_open, nil})
    assert state.settings == nil
    {state, _} = act(state, {:settings_open, {:section, :agents_limits}})
    assert state.settings.generation == 2

    {state, _} = deliver(state, request, body)
    assert state.settings.data.loaded_at == nil
  end

  test "a service without settings leaves the terminal sections working" do
    {state, effects} = act(ready(), {:settings_open, {:section, :agents_limits}})
    [request] = sent(effects)
    {state, _} = deliver(state, request, {:settings_failed, request.request_id, "not offered"})

    assert %Layer{available: false, message: "not offered"} = state.settings
    state = act!(state, {:settings_open, {:key, "terminal.show_diffs"}})
    {_state, effects} = act(state, {:settings, {:verb, :toggle}})
    assert Enum.any?(effects, &match?({:settings_cli_write, _, _, _, _}, &1))
  end

  test "an unsaved live session answers available: false with the words for it" do
    {state, effects} = act(ready(), {:settings_open, {:section, :agents_limits}})
    [request] = sent(effects)

    snapshot = %DTO.SettingsSnapshot{
      request_id: request.request_id,
      view: :open,
      available: false,
      message:
        "Settings for the database are available in saved sessions only. The terminal sections work here."
    }

    {state, _} = deliver(state, request, snapshot)
    assert state.settings.available == false
    assert state.settings.message =~ "saved sessions only"
  end

  test "a resynced shell watch asks again for what the page needs" do
    {state, effects} = act(ready(), {:settings_open, {:section, :agents_limits}})
    assert [_] = sent(effects)

    watch = state.watches.shell

    state = %{
      state
      | watches: %{state.watches | shell: %{watch | generation: watch.generation + 1}}
    }

    {state, effects} = SwarmCodeCLI.UI.Reducer.Settings.Responses.after_data(state)
    assert [request] = sent(effects)
    assert request.generation == watch.generation + 1
    assert state.settings.watch_generation == watch.generation + 1
  end

  test "an outcome reply to a write says it could not tell, and re-reads" do
    {state, _fake} = opened()
    state = Nav.put_cursor(state, "key:limits.max_concurrent_agents")
    {state, [{:start_timer, timer, _, _}]} = act(state, {:settings, {:verb, :right}})
    {state, effects} = act(state, {:settings, {:settle, state.settings.generation, timer}})
    [request] = sent(effects)

    result = %DTO.SettingsResult{
      request_id: request.request_id,
      status: :unavailable,
      corrective_action: :refresh
    }

    {state, effects} = deliver(state, request, result)
    assert state.settings.status.text == "Couldn't tell whether that was saved; reloading."
    assert sent(effects) != []
  end
end
