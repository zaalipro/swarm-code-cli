defmodule SwarmCodeCLI.UI.Settings.C74ProviderTest do
  @moduledoc """
  cli74 U1-17 (§3.10.1, D11): a message while the conversation's chat
  provider cannot answer is not sent — the draft stays, the status says why
  and where; commands still go; F2 then opens Providers; the header chip
  shows while it holds; the service's own refusal reads the same; an older
  service that sends the provider's name alone is never second-guessed.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers

  alias SwarmCodeCLI.UI.{Input, Keymap, Projector, Reducer, SafeText}
  alias SwarmCodeCLI.UI.DataSource.{Delivery, DTO}
  alias SwarmCodeCLI.UI.Settings.{ChatProvider, Layer}

  @words "No model provider can answer: llmotions has no key · F2 opens Settings › Providers"

  defp with_provider(state, provider) do
    workspace = Map.fetch!(state.read_model.snapshots, :workspace)

    snapshots =
      Map.put(state.read_model.snapshots, :workspace, %{workspace | chat_provider: provider})

    %{state | read_model: %{state.read_model | snapshots: snapshots}}
  end

  defp keyless, do: with_provider(ready(), %{name: "llmotions", usable: false})

  defp enter(state) do
    {:ok, action} = Keymap.draft_send(state)
    Reducer.update(state, action)
  end

  defp status_text(state) do
    {scene, _} = Projector.project(state)

    scene.regions
    |> Enum.flat_map(& &1.blocks)
    |> Enum.map_join("\n", fn block ->
      block |> Map.get(:spans, []) |> Enum.map_join("", &SafeText.value(&1.text))
    end)
  end

  test "Enter with a keyless provider keeps the draft and says why and where" do
    state = type(keyless(), "hello there")
    {state, effects} = enter(state)

    assert requests(effects) == []
    assert text(state) == "hello there"
    assert state.notice == {:command_feedback, @words}
    assert status_text(state) =~ "No model provider can answer: llmotions has no key"
  end

  test "with no provider at all the words say none is set up" do
    state = ready() |> with_provider(%{name: nil, usable: false}) |> type("hi")
    {state, _effects} = enter(state)

    assert state.notice ==
             {:command_feedback,
              "No model provider is set up yet · F2 opens Settings › Providers"}
  end

  test "a command still goes: /model and friends fix the provider" do
    state = type(keyless(), "/compact")
    {_state, effects} = enter(state)
    assert [%{kind: {:dispatch, :send, "/compact", _, _}}] = requests(effects)
  end

  test "F2 then opens Settings at Providers; an explicit /settings argument still wins" do
    {state, _} = keyless() |> type("hello") |> enter()
    opened = press!(state, Input.key({:function, 2}))
    assert Layer.section(opened.settings) == :providers
    assert text(opened) == "hello"

    layout = Reducer.update(keyless(), {:settings_open, {:section, :layout}}) |> elem(0)
    assert Layer.section(layout.settings) == :layout
  end

  test "the header chip shows while the provider cannot answer, and goes when it can" do
    assert status_text(keyless()) =~ "no model provider · Providers"

    usable = with_provider(ready(), %{name: "llmotions", usable: true})
    refute status_text(usable) =~ "no model provider"
  end

  test "an older service that names the provider alone is never refused by the client" do
    state = ready() |> with_provider("llmotions") |> type("hello")
    assert ChatProvider.missing(state) == nil
    {_state, effects} = enter(state)
    assert [%{kind: {:dispatch, :send, "hello", _, _}}] = requests(effects)

    opened = press!(ready(), Input.key({:function, 2}))
    assert Layer.section(opened.settings) == :overview
  end

  test "the service's own refusal reads the same words" do
    state = ready() |> type("hello")
    {state, effects} = enter(state)
    [request] = requests(effects)

    refusal = %DTO.Refusal{
      code: "provider_required",
      text: "No model provider can answer: DeepSeek has no key. Add one in /settings providers."
    }

    {state, _} =
      Reducer.update(
        state,
        {:data,
         %Delivery{
           kind: :response,
           request_id: request.request_id,
           watch_ref: nil,
           scope: request.scope,
           generation: request.generation,
           revision: nil,
           sequence: nil,
           body: %DTO.Outcome{
             request_id: request.request_id,
             status: :rejected,
             identifiers: [],
             reason: refusal,
             error: SwarmCodeCLI.UI.DataSource.AdmissionError.new(:not_allowed)
           }
         }}
      )

    assert Map.get(state.mutation_reasons, request.origin) ==
             "No model provider can answer: DeepSeek has no key · F2 opens Settings › Providers"

    assert text(state) == "hello"
  end
end
