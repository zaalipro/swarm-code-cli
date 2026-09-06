defmodule SwarmCodeCLI.UI.ThreeRunScenarioTest do
  use ExUnit.Case, async: false

  alias SwarmCodeCLI.UI.{
    SessionRuntime,
    Init,
    Size,
    Capabilities,
    Drafts,
    Editor,
    Projector,
    OrderedIdSet
  }

  alias SwarmCodeCLI.UI.DataSource.{Fake, Delivery, DTO}
  alias Fake.{Script, Source}
  alias SwarmCodeCLI.Test.RendererFake

  defp await(runtime, predicate, remaining \\ 1000)
  defp await(_, _, 0), do: flunk("semantic barrier did not settle")

  defp await(runtime, predicate, remaining) do
    state = SessionRuntime.snapshot(runtime)
    if predicate.(state), do: state, else: await(runtime, predicate, remaining - 1)
  end

  defp action(runtime, value), do: SessionRuntime.action(runtime, value)

  defp key(runtime, value) when is_binary(value),
    do: SessionRuntime.input(runtime, {:text_fragment, :press, value, []})

  defp key(runtime, value), do: SessionRuntime.input(runtime, {:key, :press, value, []})
  defp draft(state, key), do: Drafts.fetch(state.drafts, key)

  defp preserved(state),
    do: Map.take(state, [:drafts, :focus, :selection, :scrolls, :composer_height, :preferences])

  test "three runs continue through drafts, stale delivery, Q1 CAS, reflow and explicit client detach" do
    {:ok, script} =
      Script.decode(File.read!(Path.expand("../../fixtures/fake/three_run_script.json", __DIR__)))

    source = start_supervised!({Source, script: script, source_epoch: "scenario"})

    client =
      start_supervised!({Fake, source: source, source_epoch: "scenario", client_id: "first"})

    size = %Size{columns: 160, rows: 50}
    caps = %Capabilities{size: size}

    init = %Init{
      size: size,
      capabilities: caps,
      source_epoch: "scenario",
      destination: {:conversation, Script.id(:a)},
      now: Script.clock_ms()
    }

    runtime =
      start_supervised!({SessionRuntime, init: init, data_source: client, frame_ms: 60_000})

    renderer =
      start_supervised!({RendererFake, runtime: runtime, capabilities: caps, observer: self()})

    state =
      await(
        runtime,
        &(&1.watches.workspace.status == :ready and map_size(&1.read_model.runs) == 3)
      )

    old_watch = state.watches.workspace
    a = {Script.id(:a), :main}
    b = {Script.id(:b), :main}
    action(runtime, {:focus_region, "composer"})
    key(runtime, "Review authentication")
    SessionRuntime.input(runtime, {:text_fragment, :press, "o", [:control]})
    key(runtime, "and its tests")
    SessionRuntime.input(runtime, {:key, :press, :left, []})
    SessionRuntime.input(runtime, {:key, :press, :left, [:shift]})
    action(runtime, {:draft_target, a, :main})
    action(runtime, {:composer_height, {:nudge, 1}})
    action(runtime, {:focus_region, "main"})
    action(runtime, {:scroll, "main", :first})
    action(runtime, {:scroll, "main", {:line, 5}})
    before = SessionRuntime.snapshot(runtime)
    assert Editor.text(draft(before, a).editor) == "Review authentication\nand its tests"
    # Fixture message-A-2 has three lines; zero-based final line is 2.
    assert before.scrolls.main.anchor == {"message-A-2", 2, :top}
    assert before.scrolls.main.follow? == false
    assert Editor.cursor(draft(before, a).editor) == 33
    assert Editor.selection(draft(before, a).editor) == {33, 34}
    assert :ok = Source.advance(source, "a1-a2-b1-step-1")
    state = await(runtime, &Map.has_key?(&1.read_model.interactions, Script.id(:q1)))
    assert state.read_model.interactions[Script.id(:q1)].expected_revision == 7

    assert Map.take(Script.counts(Source.snapshot(source)), [:running, :waiting]) == %{
             running: 2,
             waiting: 1
           }

    assert draft(state, a) == draft(before, a)
    assert state.scrolls.main.anchor == before.scrolls.main.anchor
    action(runtime, {:navigate, {:conversation, Script.id(:b)}})

    state =
      await(
        runtime,
        &(&1.watches.workspace.status == :ready and &1.watches.workspace.scope.id == Script.id(:b))
      )

    late = %Delivery{
      kind: :watch_ready,
      watch_ref: old_watch.watch_ref,
      request_id: nil,
      scope: old_watch.scope,
      generation: old_watch.generation,
      revision: 999,
      sequence: nil,
      body: %DTO.WorkspaceSnapshot{
        conversation_id: Script.id(:a),
        transcript: %DTO.TranscriptWindow{},
        runs_page: %DTO.PageInfo{},
        interactions_page: %DTO.PageInfo{}
      }
    }

    assert {:ok, _} = Delivery.validate(late)
    send(runtime, {:swarm_code_ui_data, "scenario", late})
    assert SessionRuntime.snapshot(runtime) == state
    send(runtime, {:swarm_code_ui_data, "stale-epoch", late})
    assert SessionRuntime.snapshot(runtime) == state
    action(runtime, {:open_layer, {:run_inspector, Script.id(:b1), :overview}})
    await(runtime, &(&1.watches.inspector.status == :ready))
    action(runtime, {:scroll, "inspector", {:line, -1}})
    inspector = SessionRuntime.snapshot(runtime).scrolls.inspector
    assert inspector.follow? == false
    key(runtime, :escape)
    action(runtime, {:navigate, :activity})
    await(runtime, &(&1.watches.activity.status == :ready))
    action(runtime, {:open_layer, {:question, Script.id(:q1)}})
    key(runtime, "2")
    modal = SessionRuntime.snapshot(runtime)
    option2 = Enum.at(modal.read_model.interactions[Script.id(:q1)].question.options, 1).id
    assert modal.focus == option2
    assert :ok = Source.advance(source, "a1-b1-step-2")
    state = await(runtime, &(&1.read_model.runs[Script.id(:a1)].progress == 60))
    assert state.focus == modal.focus
    assert state.drafts == modal.drafts
    assert state.scrolls.main.anchor == modal.scrolls.main.anchor
    assert state.scrolls.inspector.anchor == modal.scrolls.inspector.anchor
    {_, actions} = Projector.project(state)
    q1 = Script.id(:q1)
    a2 = Script.id(:a2)
    node_a2 = Script.id(:node_a2)

    assert Enum.any?(actions, fn {_, target} ->
             match?({:intent, {:answer_question, ^a2, ^node_a2, ^q1, 7, _}}, target)
           end)

    key(runtime, :enter)

    await(
      runtime,
      &Enum.any?(&1.mutations, fn {_, value} -> match?({:settled, _, :accepted}, value) end)
    )

    canonical = Source.snapshot(source)
    assert map_size(canonical.commands) == 1
    [{_, command}] = Map.to_list(canonical.commands)
    expected_kind = {:answer_question, a2, node_a2, q1, 7, [option2]}

    expected_fingerprint =
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary({expected_kind, :global, nil, {:interaction, q1, 7}})
      )

    assert command.fingerprint == expected_fingerprint
    assert command.outcome.status == :accepted
    assert command.outcome.identifiers == [q1, a2]
    assert canonical.runs[Script.id(:a2)].state == :running
    key(runtime, :escape)
    action(runtime, {:navigate, {:conversation, Script.id(:b)}})
    await(runtime, &(&1.watches.workspace.status == :ready))
    action(runtime, {:focus_region, "composer"})
    key(runtime, "Research citations")
    before_resize = SessionRuntime.snapshot(runtime)

    for {columns, rows} <- [{80, 24}, {50, 14}, {160, 50}] do
      SessionRuntime.input(runtime, {:resize, %Size{columns: columns, rows: rows}})
      state = SessionRuntime.snapshot(runtime)
      assert state.drafts == before_resize.drafts
      assert state.scrolls == before_resize.scrolls
      {scene, _} = Projector.project(state)
      assert :ok = SwarmCodeCLI.UI.Scene.validate(scene)
      if columns == 50, do: assert(scene.layout_class == :compressed_small)
    end

    action(runtime, {:navigate, {:conversation, Script.id(:a)}})
    state = await(runtime, &(&1.watches.workspace.status == :ready))
    assert draft(state, a) == draft(before_resize, a)
    assert draft(state, b) == draft(before_resize, b)
    assert Editor.text(draft(state, a).editor) == "Review authentication\nand its tests"
    assert state.read_model.runs[Script.id(:a1)].state == :running
    assert state.read_model.runs[Script.id(:a2)].state == :running
    assert state.read_model.runs[Script.id(:b1)].state == :running
    action(runtime, {:focus_region, "main"})
    key(runtime, :end)
    state = SessionRuntime.snapshot(runtime)
    assert state.scrolls.main.follow? == true
    assert OrderedIdSet.to_list(state.scrolls.main.unseen) == []
    assert state.scrolls.inspector.follow? == false
    saved = preserved(state)
    canonical = Source.snapshot(source)
    key(runtime, "q")
    assert SessionRuntime.snapshot(runtime).focus == "cancel"
    key(runtime, :enter)
    assert preserved(SessionRuntime.snapshot(runtime)) == saved
    assert Source.snapshot(source) == canonical
    assert SessionRuntime.status(runtime).phase == :running
    key(runtime, "q")
    key(runtime, :tab)
    key(runtime, :enter)
    assert_receive {:renderer_draw, ^renderer, _, _, :ok}
    monitor = Process.monitor(runtime)
    assert :ok = RendererFake.settle(renderer)
    assert_receive {:renderer_shutdown, ^renderer}
    assert_receive {:DOWN, ^monitor, :process, ^runtime, :normal}
    assert Source.snapshot(source) == canonical
    assert :sys.get_state(client).phase == :closed

    new_client =
      start_supervised!({Fake, source: source, source_epoch: "scenario", client_id: "second"},
        id: :second
      )

    assert {:ok, "new-binding"} = Fake.bind_owner(new_client, self(), "new-binding")

    watch = %SwarmCodeCLI.UI.DataSource.Watch{
      watch_ref: "new-watch",
      slot: :shell,
      scope: %SwarmCode.Protocol.Scope{kind: :global, id: nil, generation: 0},
      generation: 0,
      page_size: 200,
      byte_limit: 1_048_576
    }

    assert :ok = Fake.watch(new_client, watch)

    assert_receive {:swarm_code_ui_data, "scenario",
                    %Delivery{kind: :watch_ready, body: recovered}}

    assert Enum.all?(recovered.runs, &(&1.state == :running))
    assert length(recovered.runs) == 3
  end
end
