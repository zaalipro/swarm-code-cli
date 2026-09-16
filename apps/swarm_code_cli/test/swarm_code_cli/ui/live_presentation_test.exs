defmodule SwarmCodeCLI.UI.LivePresentationTest do
  use ExUnit.Case, async: true

  alias SwarmCode.Protocol.Scope
  alias SwarmCodeCLI.Plain.{Command, Options, Presenter}

  alias SwarmCodeCLI.UI.{
    Capabilities,
    Fixtures,
    Input,
    Keymap,
    Projector,
    Reducer,
    SafeText,
    Scene,
    Size
  }

  alias SwarmCodeCLI.UI.DataSource.{Delivery, DTO}

  test "approval wire carries closed tool facts and rejects unrecognized permission or fields" do
    wire = approval_wire()
    assert {:ok, item} = DTO.PendingInteraction.decode(wire)
    assert item.approval.tool == "run_command"
    assert item.approval.arguments_detail_ref.total_bytes == 100_000

    for details <- [
          Map.put(wire["approval"], "permission", "auto"),
          Map.put(wire["approval"], "execute", true),
          Map.put(wire["approval"], "arguments_preview", String.duplicate("a", 65_537))
        ] do
      assert {:error, :invalid_dto} =
               DTO.PendingInteraction.decode(%{wire | "approval" => details})
    end
  end

  test "approval dialog shows actual sanitized arguments and opens the full immutable detail" do
    state = fixture()
    item = approval!()
    state = put_in(state.read_model.interactions[item.id], item)
    state = %{state | layers: [{:approval, item.id}], focus: "cancel"}
    {scene, actions} = Projector.project(state)
    assert Scene.validate(scene) == :ok
    rendered = Enum.join(texts(scene.overlay), " ")
    assert rendered =~ "Tool: run command"
    assert rendered =~ "mix test"
    refute rendered =~ "\e"
    assert {:local, {:open_detail, "fixture-run", "approval-args"}} in Map.values(actions)

    focused = %{state | focus: "approval_details"}
    {focused_scene, actions} = Projector.project(focused)
    assert focused_scene.overlay.focused_control_id == "approval_details"

    assert {:ok, {:open_detail, "fixture-run", "approval-args"}} =
             Keymap.resolve(Input.key(:enter), focused, actions)

    assert Reducer.update(state, {:open_detail, "another-run", "approval-args"}) == {state, []}

    {opened, effects} = Reducer.update(state, {:open_detail, "fixture-run", "approval-args"})
    assert opened.detail.ref == item.approval.arguments_detail_ref

    assert Enum.any?(
             effects,
             &match?({:query, %{kind: {:query_detail, "approval-args", 0, _}}}, &1)
           )
  end

  test "long approval previews can be read by keyboard without a separate detail reference" do
    state = fixture()
    item = approval!()

    item = %{
      item
      | approval: %{
          item.approval
          | arguments_preview:
              String.duplicate("before ", 200) <>
                "MIDDLE_MARKER " <>
                String.duplicate("after ", 400),
            arguments_detail_ref: nil
        }
    }

    state = put_in(state.read_model.interactions[item.id], item)
    {state, _} = Reducer.update(state, {:open_layer, {:approval, item.id}})
    assert state.focus == "cancel"

    {scene, table} = Projector.project(state)
    assert {:ok, action} = Keymap.resolve(Input.key(:page_down), state, table)
    {next, []} = Reducer.update(state, action)
    {next_scene, _} = Projector.project(next)
    assert next_scene.overlay.body_scroll > scene.overlay.body_scroll

    {_last, content} =
      Enum.reduce(1..10, {state, ""}, fn _, {current, content} ->
        {scene, table} = Projector.project(current)
        assert {:ok, action} = Keymap.resolve(Input.key(:page_down), current, table)
        {next, []} = Reducer.update(current, action)
        {next, content <> Enum.join(texts(scene.overlay.blocks), "")}
      end)

    assert content =~ "MIDDLE_MARKER"
    {back, []} = Reducer.update(next, {:scroll, "dialog", :first})
    assert elem(Projector.project(back), 0).overlay.body_scroll == 0
  end

  test "plain approval includes tool arguments and offers the scoped full detail command" do
    item = approval!()

    body = %DTO.WorkspaceSnapshot{
      conversation_id: "fixture-conversation",
      runs: [
        %DTO.RunSummary{
          id: "fixture-run",
          conversation_id: "fixture-conversation",
          state: :waiting_approval
        }
      ],
      transcript: %DTO.TranscriptWindow{},
      interactions: [item]
    }

    {presenter, records} = present(body)
    output = records |> Enum.map(&elem(&1, 1)) |> IO.iodata_to_binary()
    assert output =~ "run_command"
    assert output =~ "mix test"
    assert output =~ "detail approval-args"
    refute output =~ "\e"

    assert {:ok, {:local, {:open_detail, "fixture-run", "approval-args"}}} =
             Command.parse("detail approval-args", presenter, presenter.scope)
  end

  test "maximum and escape-expanded inline arguments retain readable start and end at small and wide sizes" do
    for size <- [%Size{columns: 50, rows: 16}, %Size{columns: 150, rows: 40}],
        content <- [
          "HEAD_MARKER " <> String.duplicate("data ", 13_100) <> " TAIL_MARKER",
          "HEAD_MARKER " <> String.duplicate("\e", 10_000) <> " TAIL_MARKER"
        ] do
      state = fixture()
      state = %{state | size: size, capabilities: %{state.capabilities | size: size}}
      item = approval!()

      item = %{
        item
        | approval: %{item.approval | arguments_preview: content, arguments_detail_ref: nil}
      }

      assert {:ok, ^item} = DTO.PendingInteraction.validate(item)
      state = put_in(state.read_model.interactions[item.id], item)
      {state, _} = Reducer.update(state, {:open_layer, {:approval, item.id}})
      {first, actions} = Projector.project(state)
      assert Enum.join(texts(first.overlay.blocks), "") =~ "HEAD_MARKER"
      assert {:ok, next_action} = Keymap.resolve(Input.key(:page_down), state, actions)
      {next, []} = Reducer.update(state, next_action)
      {middle, _} = Projector.project(next)

      assert elem(middle.overlay.body_visible_range, 0) ==
               elem(first.overlay.body_visible_range, 1)

      assert {:ok, end_action} = Keymap.resolve(Input.key(:end), state, actions)
      {last, []} = Reducer.update(state, end_action)
      {scene, _} = Projector.project(last)
      assert Scene.validate(scene) == :ok
      assert Enum.join(texts(scene.overlay.blocks), "") =~ "TAIL_MARKER"
    end
  end

  test "unknown live progress renders indeterminate instead of inventing a percentage" do
    state = fixture()

    run = %{
      state.read_model.runs["fixture-run"]
      | progress: nil,
        state: :running,
        allowed_actions: [:pause, :stop]
    }

    assert {:ok, ^run} = DTO.RunSummary.validate(run)
    state = put_in(state.read_model.runs[run.id], run)
    {scene, _} = Projector.project(state)
    assert Scene.validate(scene) == :ok
    # The run card and its gauge are gone from main: the state is a row of
    # words, and an unknown progress invents no percentage anywhere.
    assert gauge_blocks(scene) == []
    assert progress_blocks(scene) == []
  end

  test "long reasoning has a distinct bounded detail reference available in TUI and plain" do
    state = fixture()
    item = state.read_model.transcript |> Map.values() |> hd()
    ref = %DTO.DetailRef{id: "full-reasoning", total_bytes: 16_777_216}
    assert {:ok, ^ref} = DTO.DetailRef.validate(ref)
    assert {:error, :invalid_dto} = DTO.DetailRef.validate(%{ref | total_bytes: 16_777_217})
    item = Map.put(item, :reasoning_detail_ref, ref)
    assert {:ok, ^item} = DTO.TranscriptItem.validate(item)
    state = put_in(state.read_model.transcript[item.id], item)
    {scene, actions} = Projector.project(state)
    assert Scene.validate(scene) == :ok
    assert {:local, {:open_detail, item.run_id, ref.id}} in Map.values(actions)
    {opened, _} = Reducer.update(state, {:open_detail, item.run_id, ref.id})
    assert opened.detail.ref == ref

    {presenter, records} =
      present(%DTO.WorkspaceSnapshot{
        conversation_id: "fixture-conversation",
        runs: [state.read_model.runs[item.run_id]],
        transcript: %DTO.TranscriptWindow{items: [item]}
      })

    output = records |> Enum.map(&elem(&1, 1)) |> IO.iodata_to_binary()
    assert output =~ "detail full-reasoning"

    assert {:ok, {:local, {:open_detail, _, "full-reasoning"}}} =
             Command.parse("detail full-reasoning", presenter, presenter.scope)
  end

  test "all text and reasoning links on a full plain page remain usable" do
    state = fixture()
    item = state.read_model.transcript |> Map.values() |> hd()

    items =
      for n <- 1..200 do
        item
        |> Map.put(:id, "item-#{n}")
        |> Map.put(:node_id, "node-#{n}")
        |> Map.put(:detail_ref, %DTO.DetailRef{id: "text-#{n}", total_bytes: 100_000})
        |> Map.put(:reasoning_detail_ref, %DTO.DetailRef{
          id: "reasoning-#{n}",
          total_bytes: 100_000
        })
      end

    {presenter, _} =
      present(%DTO.WorkspaceSnapshot{
        conversation_id: "fixture-conversation",
        runs: [state.read_model.runs["fixture-run"]],
        transcript: %DTO.TranscriptWindow{items: items}
      })

    for n <- 1..200, channel <- ["text", "reasoning"] do
      ref = "#{channel}-#{n}"

      assert {:ok, {:local, {:open_detail, "fixture-run", ^ref}}} =
               Command.parse("detail " <> ref, presenter, presenter.scope)
    end
  end

  defp approval! do
    assert {:ok, item} = DTO.PendingInteraction.decode(approval_wire())
    item
  end

  defp approval_wire do
    %{
      "id" => "approval",
      "run_id" => "fixture-run",
      "node_id" => "node",
      "conversation_id" => "fixture-conversation",
      "kind" => "approval",
      "expected_revision" => 4,
      "state" => "pending",
      "question" => nil,
      "allowed_actions" => ["approve", "deny"],
      "urgency" => "normal",
      "deadline" => 0,
      "created_at" => 0,
      "approval" => %{
        "tool" => "run_command",
        "permission" => "execute",
        "arguments_preview" => "{\"command\":\"mix test\"}\e]0;untrusted\a",
        "arguments_detail_ref" => %{"id" => "approval-args", "total_bytes" => 100_000}
      }
    }
  end

  defp fixture do
    size = %Size{columns: 150, rows: 40}
    capabilities = %Capabilities{size: size}
    preview = Fixtures.representative(:chat, size, capabilities)

    {state, _} =
      Reducer.init(%SwarmCodeCLI.UI.Init{
        size: size,
        capabilities: capabilities,
        source_epoch: "epoch",
        destination: {:run, "fixture-run"}
      })

    model =
      put_in(preview.read_model.runs["fixture-run"].allowed_actions, [:pause, :stop]).read_model

    %{state | read_model: model}
  end

  defp present(body) do
    body = %{body | runs_page: %DTO.PageInfo{}, interactions_page: %DTO.PageInfo{}}
    assert {:ok, _} = DTO.WorkspaceSnapshot.validate(body)

    Presenter.present(Presenter.new(%Options{}), "epoch", %Delivery{
      kind: :watch_ready,
      watch_ref: "w",
      request_id: nil,
      sequence: nil,
      scope: %Scope{kind: :conversation, id: "fixture-conversation", generation: 0},
      generation: 0,
      revision: 1,
      body: body
    })
  end

  defp texts(%SafeText{} = text), do: [SafeText.value(text)]
  defp texts(%{__struct__: _} = value), do: value |> Map.from_struct() |> texts()
  defp texts(value) when is_map(value), do: value |> Map.values() |> texts()
  defp texts(value) when is_list(value), do: Enum.flat_map(value, &texts/1)
  defp texts(_), do: []

  defp progress_blocks(%Scene.Block.Progress{} = block), do: [block]

  defp progress_blocks(%{__struct__: _} = value),
    do: value |> Map.from_struct() |> progress_blocks()

  defp progress_blocks(value) when is_map(value), do: value |> Map.values() |> progress_blocks()
  defp progress_blocks(value) when is_list(value), do: Enum.flat_map(value, &progress_blocks/1)
  defp progress_blocks(_), do: []

  # W5 Change 1: workspace projects Gauge blocks for running runs
  defp gauge_blocks(%Scene.Block.Gauge{} = block), do: [block]

  defp gauge_blocks(%{__struct__: _} = value),
    do: value |> Map.from_struct() |> gauge_blocks()

  defp gauge_blocks(value) when is_map(value), do: value |> Map.values() |> gauge_blocks()
  defp gauge_blocks(value) when is_list(value), do: Enum.flat_map(value, &gauge_blocks/1)
  defp gauge_blocks(_), do: []
end
