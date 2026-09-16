defmodule SwarmCodeCLI.UI.DataSource.ReadModelHiveTest do
  @moduledoc "Changes and verdicts enter the read model from snapshots and deltas by revision."
  use ExUnit.Case, async: true
  alias SwarmCode.Protocol.Scope
  alias SwarmCodeCLI.UI.{ReadModel, State, WatchState}
  alias SwarmCodeCLI.UI.DataSource.{Delivery, Delta, DTO}
  alias SwarmCodeCLI.UI.Reducer.Watch

  @run "33333333-3333-4333-8333-333333333333"
  @conversation "22222222-2222-4222-8222-222222222222"
  @scope %Scope{kind: :conversation, id: @conversation, generation: 1}

  defp change(id, revision, extra \\ []),
    do:
      struct!(
        %DTO.Change{id: id, run_id: @run, path: "lib/#{id}.ex", at: 1, revision: revision},
        extra
      )

  defp verdict(revision),
    do: %DTO.Verdict{
      id: "judge-1",
      run_id: @run,
      round: 1,
      checks: [%DTO.VerdictCheck{key: "tests_pass", ok: true}],
      summary: "ok",
      revision: revision
    }

  defp snapshot(changes, verdicts, revision \\ 1),
    do: %DTO.WorkspaceSnapshot{
      conversation_id: @conversation,
      revision: revision,
      runs_page: %DTO.PageInfo{through_sequence: 9},
      interactions_page: %DTO.PageInfo{through_sequence: 9},
      transcript: %DTO.TranscriptWindow{through_sequence: 9},
      through_sequence: 9,
      changes: changes,
      verdicts: verdicts
    }

  defp delta(kind, entity_id, body, sequence, revision),
    do: %Delta{
      kind: kind,
      entity_id: entity_id,
      run_id: @run,
      conversation_id: @conversation,
      body: body,
      sequence: sequence,
      revision: revision
    }

  test "a workspace snapshot installs changes and verdicts keyed by id" do
    model =
      ReadModel.snapshot(
        %ReadModel{},
        :workspace,
        snapshot([change("c1", 1), change("c2", 1)], [verdict(1)])
      )

    assert Map.keys(model.changes) |> Enum.sort() == ["c1", "c2"]
    assert %DTO.Verdict{round: 1} = model.verdicts["judge-1"]
    assert model.coverage[:workspace][:changes] == ["c1", "c2"]
    assert model.coverage[:workspace][:verdicts] == ["judge-1"]
    assert ReadModel.bounded?(model)

    # A later snapshot replaces the slot's coverage: c2 leaves, an older c1 cannot downgrade.
    newer =
      ReadModel.snapshot(
        %{model | changes: %{"c1" => change("c1", 5)}},
        :workspace,
        snapshot([change("c1", 3)], [])
      )

    assert Map.keys(newer.changes) == ["c1"]
    assert newer.changes["c1"].revision == 5
    assert newer.verdicts == %{}
  end

  test "change and verdict deltas apply by entity revision and remove by id" do
    model =
      ReadModel.snapshot(%ReadModel{}, :workspace, snapshot([change("c1", 2)], [verdict(1)]))

    assert {:ok, model, [], []} =
             ReadModel.delta(
               model,
               :workspace,
               delta(:change_upsert, "c1", change("c1", 1), 10, 1)
             )

    assert model.changes["c1"].revision == 2

    assert {:ok, model, [], []} =
             ReadModel.delta(
               model,
               :workspace,
               delta(:change_upsert, "c1", change("c1", 3, restorable: true), 11, 3)
             )

    assert model.changes["c1"].restorable == true

    assert {:ok, model, [], []} =
             ReadModel.delta(
               model,
               :workspace,
               delta(:change_upsert, "c2", change("c2", 1), 12, 3)
             )

    assert Map.has_key?(model.changes, "c2")
    assert "c2" in model.coverage[:workspace][:changes]

    assert {:ok, model, [], ["c1"]} =
             ReadModel.delta(model, :workspace, delta(:change_remove, "c1", nil, 13, 3))

    refute Map.has_key?(model.changes, "c1")
    refute "c1" in model.coverage[:workspace][:changes]

    assert {:ok, model, [], []} =
             ReadModel.delta(
               model,
               :workspace,
               delta(:verdict_upsert, "judge-1", verdict(4), 14, 4)
             )

    assert model.verdicts["judge-1"].revision == 4

    assert {:error, :snapshot_required} =
             ReadModel.delta(model, :workspace, delta(:change_upsert, "", change("", 1), 15, 4))
  end

  test "the read model stays bounded at 512 changes" do
    many = for i <- 1..512, into: %{}, do: {"c#{i}", change("c#{i}", 1)}
    model = %ReadModel{changes: many}
    assert ReadModel.bounded?(model)
    refute ReadModel.bounded?(%{model | changes: Map.put(many, "c513", change("c513", 1))})

    assert {:error, :snapshot_required} =
             ReadModel.delta(
               model,
               :workspace,
               delta(:change_upsert, "c513", change("c513", 1), 1, 1)
             )
  end

  test "the watch reducer delivers snapshot lists and the new delta kinds into the read model" do
    workspace = %WatchState{
      watch_ref: "watch-1",
      scope: @scope,
      generation: 1,
      source_epoch: "epoch",
      status: :frozen
    }

    state = %State{
      source_epoch: "epoch",
      destination: {:conversation, @conversation},
      watches: %{
        shell: %WatchState{},
        workspace: workspace,
        activity: %WatchState{},
        inspector: %WatchState{}
      }
    }

    ready = %Delivery{
      kind: :watch_ready,
      watch_ref: "watch-1",
      request_id: nil,
      scope: @scope,
      generation: 1,
      revision: 1,
      sequence: nil,
      body: snapshot([change("c1", 1)], [verdict(1)])
    }

    {state, []} = Watch.deliver(state, ready)
    assert state.watches.workspace.status == :ready
    assert state.watches.workspace.sequence == 9
    assert Map.keys(state.read_model.changes) == ["c1"]
    assert Map.keys(state.read_model.verdicts) == ["judge-1"]

    deliver = fn state, body ->
      Watch.deliver(state, %Delivery{
        kind: :delta,
        watch_ref: "watch-1",
        request_id: nil,
        scope: @scope,
        generation: 1,
        revision: body.revision,
        sequence: body.sequence,
        body: body
      })
    end

    {state, []} = deliver.(state, delta(:change_upsert, "c2", change("c2", 2), 10, 2))
    assert state.watches.workspace.sequence == 10
    assert Map.keys(state.read_model.changes) |> Enum.sort() == ["c1", "c2"]

    {state, []} = deliver.(state, delta(:verdict_upsert, "judge-1", verdict(3), 11, 3))
    assert state.read_model.verdicts["judge-1"].revision == 3

    {state, []} = deliver.(state, delta(:change_remove, "c1", nil, 12, 3))
    assert Map.keys(state.read_model.changes) == ["c2"]

    # A stale delta for an already-newer entity is a no-op that still advances the watch.
    {state, []} = deliver.(state, delta(:change_upsert, "c2", change("c2", 1), 13, 3))
    assert state.read_model.changes["c2"].revision == 2
    assert state.watches.workspace.sequence == 13

    # A sequence gap triggers a resync rather than a crash.
    {state, [{:query, request}]} =
      deliver.(state, delta(:change_upsert, "c3", change("c3", 1), 15, 4))

    assert request.kind == {:resync_watch, "watch-1"}
    assert state.watches.workspace.status == :resyncing
  end
end
