defmodule SwarmCodeCLI.UI.LibraryTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.UI.{Capabilities, Init, Reducer, Size, Projector, SafeText}
  alias SwarmCodeCLI.UI.DataSource.{Delivery, DTO}

  test "advertised library actions are explicit, confirmed, and settle after closing the page" do
    size = %Size{columns: 120, rows: 40}

    {state, _} =
      Reducer.init(%Init{
        size: size,
        capabilities: %Capabilities{size: size},
        source_epoch: "epoch"
      })

    {state, [{:query, request}]} = Reducer.update(state, {:open_layer, {:library, :schedules}})

    body = %DTO.LibrarySnapshot{
      feature: :schedules,
      request_id: request.request_id,
      items: [%DTO.LibraryItem{id: "task", title: "Daily", actions: [:toggle, :delete]}]
    }

    {ready, []} = SwarmCodeCLI.UI.Library.response(state, request, body)

    assert {^ready, []} =
             Reducer.update(ready, {:library_command, :schedules, "foreign", :delete})

    {scene, _} = Projector.project(ready)

    assert Enum.any?(scene.overlay.footer, fn c ->
             Map.has_key?(c, :text) and String.contains?(SafeText.value(c.text), "Delete")
           end)

    {confirming, []} = Reducer.update(ready, {:library_command, :schedules, "task", :delete})
    assert confirming.library.confirmation == {"task", :delete}
    {pending, [{:command, command}]} = Reducer.update(confirming, {:library_confirm, true})
    assert command.kind == {:feature_command, :schedules, :delete, "task", %{}}
    assert pending.library.command_id == command.request_id
    {closed, _} = Reducer.update(pending, :close_top_layer)
    assert Map.has_key?(closed.requests, command.request_id)

    {settled, []} =
      SwarmCodeCLI.UI.Library.command_response(closed, command, %DTO.Outcome{
        request_id: command.request_id,
        status: :accepted
      })

    assert settled.library == nil
    refute Map.has_key?(settled.requests, command.request_id)
  end

  test "workflows slash navigation opens the library without provider dispatch" do
    state = %SwarmCodeCLI.UI.State{banner: :live_banner}
    target = {:intent, {:dispatch, :send, "/workflows", :main, []}}

    assert {:ok, {:open_layer, {:library, :workflows}}} =
             SwarmCodeCLI.UI.Keymap.activate(target, state, %{"send" => target})
  end

  test "saved slash navigation uses the correlated dispatcher so accepted commands clear the composer" do
    state = %SwarmCodeCLI.UI.State{banner: :persisted_banner}

    for text <- ["/workflows", "/deep_research"] do
      intent = {:dispatch, :send, text, :main, []}
      target = {:intent, intent}

      assert {:ok, {:invoke, ^intent, _}} =
               SwarmCodeCLI.UI.Keymap.activate(target, state, %{"send" => target})
    end
  end

  test "library opens a typed query, shows its results, and drops late results after close" do
    size = %Size{columns: 120, rows: 40}

    {state, _} =
      Reducer.init(%Init{
        size: size,
        capabilities: %Capabilities{size: size},
        source_epoch: "epoch"
      })

    {loading, [{:query, request}]} = Reducer.update(state, {:open_layer, {:library, :workflows}})
    assert request.kind == {:feature_query, :workflows, nil, nil, 20, 262_144}

    body = %DTO.LibrarySnapshot{
      feature: :workflows,
      title: "Workflows",
      description: "Project workflows",
      request_id: request.request_id,
      items: [
        %DTO.LibraryItem{
          id: "review",
          title: "Review changes",
          subtitle: "Project",
          status: "ready",
          detail: "Run tests and review the diff",
          actions: [:start]
        }
      ],
      covered_ids: ["review"]
    }

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

    {ready, []} = Reducer.update(loading, {:data, delivery})
    {scene, _} = Projector.project(ready)
    assert SafeText.value(scene.overlay.title) == " Workflows "

    assert Enum.any?(scene.overlay.blocks, fn block ->
             Map.has_key?(block, :text) and
               String.contains?(SafeText.value(block.text), "Review changes")
           end)

    {closed, _} = Reducer.update(loading, :close_top_layer)
    {late, []} = Reducer.update(closed, {:data, delivery})
    assert late == closed
    assert closed.library == nil
  end
end
