defmodule SwarmCodeCLI.UI.Settings.C74FollowupsTest do
  @moduledoc """
  cli74 U1-19: what U2 and U3 asked of the layer in their notes — a load the
  service cannot answer is asked once per arrival on a page (Ctrl-R asks
  again), a model value reads as its model id, a file handed to the editor
  and saved carries its page for a `needs_confirmation` answer (the status
  says it when the page has no `confirm_external/3`), and the in-page filter
  falls back to the row text when the section has no `filter/3`.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers, only: [ready: 0]

  alias SwarmCode.Settings.Registry
  alias SwarmCodeCLI.UI.Reducer
  alias SwarmCodeCLI.UI.DataSource.{Delivery, DTO, Request}
  alias SwarmCodeCLI.UI.DataSource.Fake.Settings, as: FakeSettings
  alias SwarmCodeCLI.UI.Reducer.Settings.Ops
  alias SwarmCodeCLI.UI.Settings.{Display, Nav, Sections}

  defp act(state, action), do: Reducer.update(state, action)

  defp sent(effects),
    do: for({kind, %Request{} = request} <- effects, kind in [:query, :command], do: request)

  defp params(%Request{kind: {_op, params}}), do: params

  defp deliver(state, request, body),
    do:
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

  describe "a load the service cannot answer" do
    test "is asked once per arrival, not after every answer; Ctrl-R asks again" do
      {state, effects} = act(ready(), {:settings_open, nil})
      [open] = sent(effects)
      {_fake, body, _} = FakeSettings.query(FakeSettings.seed(), open)

      # The service answered the values alone (the open body was too large).
      body = %{body | body: %{body.body | overview: nil}}
      {state, effects} = deliver(state, open, body)
      [overview] = sent(effects)
      assert %{"view" => "overview"} = params(overview)

      {state, effects} = deliver(state, overview, {:settings_failed, overview.request_id, "busy"})
      assert sent(effects) == []
      assert state.settings.status.text == "busy"

      {_state, effects} = act(state, {:settings, {:verb, :refresh}})
      assert Enum.any?(sent(effects), &match?(%{"view" => "overview"}, params(&1)))
    end
  end

  test "a model value reads as its model id, other maps as a count" do
    assert Display.words(%{"provider_id" => "p1", "model" => "deepseek-v4-pro"}) ==
             "deepseek-v4-pro"

    assert Display.words(%{"a" => 1, "b" => 2}) == "2 entries"
  end

  describe "a file the editor returns" do
    test "is saved with its page, so a needs_confirmation answer goes back to that page" do
      state = elem(act(ready(), {:settings_open, {:section, :memory}}), 0)

      {state, [{:settings_external_edit, generation, ref, _spec}]} =
        Ops.run(state, [
          {:external_edit,
           %{ref: "project_config:p1", content: "{}", fingerprint: "f1", suffix: ".json"}}
        ])

      {state, effects} =
        act(state, {:settings, {:external_result, generation, ref, {:ok, ~s({"hooks":{}})}}})

      [save] = sent(effects)

      assert %{"action" => "file.save", "target" => %{"ref" => "project_config:p1"}} =
               params(save)

      {:c, meta_ref} = elem(save.origin, 2)
      meta = Map.fetch!(state.settings.requests, meta_ref)

      assert meta.opts.confirm_with ==
               {:memory, %{content: ~s({"hooks":{}}), fingerprint: "f1"}}

      reply = %{
        status: :needs_confirmation,
        message: "The file adds 1 hook; confirm to save it.",
        confirm: %{"kind" => "hooks", "items" => [%{"event" => "post_edit"}]}
      }

      {:ok, fake, []} =
        FakeSettings.control(FakeSettings.seed(), :fail_next, ["file.save", reply])

      {_fake, body, _} = FakeSettings.command(fake, save)
      assert %DTO.SettingsResult{status: :needs_confirmation} = body
      {state, _} = deliver(state, save, body)
      assert state.settings.status.text == "The file adds 1 hook; confirm to save it."
    end

    test "a section without confirm_external/3 or filter/3 answers nil" do
      ctx = Nav.ctx(elem(act(ready(), {:settings_open, nil}), 0))

      assert Sections.confirm_external(:overview, ctx, %{content: "", fingerprint: nil}, []) ==
               nil

      assert Sections.filter(:overview, ctx, [], "x") == nil
      assert Registry.fetch!("terminal.panel").section == :layout
    end
  end
end
