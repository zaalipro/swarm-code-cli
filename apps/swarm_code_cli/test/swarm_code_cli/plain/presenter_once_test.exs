defmodule SwarmCodeCLI.Plain.PresenterOnceTest do
  @moduledoc """
  cli020 B8 (onboarding-23): `ncode --plain` prints the opening transcript
  once. The shell snapshot, the workspace snapshot and the replayed buffered
  deltas carry the same runs and items at the same revision; each is printed
  the first time only, and again when its revision moves.
  """
  use ExUnit.Case, async: true

  alias SwarmCode.Protocol.Scope
  alias SwarmCodeCLI.Plain.{Options, Presenter}
  alias SwarmCodeCLI.UI.DataSource.{Delivery, Delta, DTO}

  @global %Scope{kind: :global, id: nil, generation: 0}
  @scope %Scope{kind: :conversation, id: "c", generation: 1}

  defp run(id, revision),
    do: %DTO.RunSummary{
      id: id,
      conversation_id: "c",
      title: "turn " <> id,
      state: :done,
      revision: revision
    }

  defp item(id, run, text, revision),
    do: %DTO.TranscriptItem{
      id: id,
      run_id: run,
      conversation_id: "c",
      node_id: id,
      role: :assistant,
      kind: :text,
      state: :done,
      text: text,
      revision: revision,
      attempt_id: "a"
    }

  defp ready(scope, watch, body),
    do: %Delivery{
      kind: :watch_ready,
      watch_ref: watch,
      request_id: nil,
      scope: scope,
      generation: scope.generation,
      revision: 1,
      sequence: nil,
      body: body
    }

  defp upsert(body, sequence),
    do: %Delivery{
      kind: :delta,
      watch_ref: "w",
      request_id: nil,
      scope: @scope,
      generation: 1,
      revision: sequence,
      sequence: sequence,
      body: %Delta{
        kind: :node_upsert,
        entity_id: body.id,
        run_id: body.run_id,
        conversation_id: "c",
        body: body,
        sequence: sequence,
        revision: sequence
      }
    }

  defp text(records), do: records |> Enum.map(&elem(&1, 1)) |> IO.iodata_to_binary()

  defp count(output, needle), do: length(String.split(output, needle)) - 1

  test "a saved conversation with two turns prints each run and item once" do
    runs = [run("r1", 3), run("r2", 5)]

    items = [
      item("u1", "r1", "first question", 1),
      item("m1", "r1", "first answer", 2),
      item("u2", "r2", "second question", 1),
      item("m2", "r2", "second answer", 4)
    ]

    p = Presenter.new(%Options{})
    {p, shell} = Presenter.present(p, "e", ready(@global, "s", %DTO.ShellSnapshot{runs: runs}))
    p = Presenter.focus_scope(p, @scope)

    workspace = %DTO.WorkspaceSnapshot{
      conversation_id: "c",
      runs: runs,
      transcript: %DTO.TranscriptWindow{items: items},
      allowed_actions: [:send],
      runs_page: %DTO.PageInfo{},
      interactions_page: %DTO.PageInfo{}
    }

    {p, opening} = Presenter.present(p, "e", ready(@scope, "w", workspace))
    {p, replay} = Presenter.present(p, "e", upsert(Enum.at(items, 1), 2))
    output = text(shell) <> text(opening) <> text(replay)

    for needle <- [
          "RUN r1@3",
          "RUN r2@5",
          "first question",
          "first answer",
          "second question",
          "second answer"
        ] do
      assert count(output, needle) == 1, needle
    end

    # A new revision of an item is news.
    {_p, changed} =
      Presenter.present(p, "e", upsert(item("m1", "r1", "first answer, longer", 6), 3))

    assert text(changed) =~ "first answer, longer"
  end
end
