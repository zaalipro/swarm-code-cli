defmodule SwarmCodeCLI.UI.DataSource.C020FakeTest do
  @moduledoc """
  cli020 lane C: the `Fake` answers the new conversation commands and queries
  in the service's shapes, so lanes D and E can test against it.
  """
  use ExUnit.Case, async: true
  alias SwarmCode.Protocol.Scope
  alias SwarmCodeCLI.UI.DataSource.{DTO, Request}
  alias SwarmCodeCLI.UI.DataSource.Fake.Script

  defp script do
    {:ok, value} =
      Script.decode(
        File.read!(Path.expand("../../../fixtures/fake/three_run_script.json", __DIR__))
      )

    value
  end

  defp scope, do: %Scope{kind: :conversation, id: Script.id(:a), generation: 0}

  defp command(script, intent, id \\ "fake-1") do
    {:ok, request} =
      Request.conversation_command(intent, scope(), id, Script.clock_ms() + 1000)

    Script.command(script, request)
  end

  test "C1 queue.resume and queue.edit are accepted" do
    a = Script.id(:a)
    assert {:ok, next, %DTO.Outcome{status: :accepted}, _} = command(script(), {:queue_resume, a})

    assert {:ok, _, %DTO.Outcome{status: :accepted}, _} =
             command(next, {:queue_edit, a, "0123456789abcdef", :clear}, "fake-2")
  end

  test "C14 a clipboard slot and the image staged from it" do
    a = Script.id(:a)

    assert {:ok, next, %DTO.Outcome{status: :accepted, result: %DTO.CommandResult{} = slot}, _} =
             command(script(), {:attachment_slot, a})

    assert slot.kind == :slot and slot.token =~ ~r/\A[0-9a-f]{32}\z/

    assert {:ok, _, %DTO.Outcome{result: %DTO.CommandResult{kind: :attachment} = staged}, _} =
             command(next, {:attach_slot, a, slot.token}, "fake-2")

    assert staged.attachment.bytes > 0
    assert {:ok, _} = DTO.CommandResult.validate(staged)
  end

  test "C16 rewind turns and a rewind" do
    a = Script.id(:a)

    assert {:ok, next,
            %DTO.Outcome{result: %DTO.CommandResult{kind: :rewind_turns, turns: [t | _]}},
            _} =
             command(script(), {:rewind_turns, a})

    assert {:ok, _} = DTO.RewindTurn.validate(t)

    assert {:ok, _, %DTO.Outcome{result: %DTO.CommandResult{kind: :rewound, text: nil}}, _} =
             command(next, {:rewind_apply, a, t.message_id, :files}, "fake-2")
  end

  test "C20 the prompt history filters by the query" do
    a = Script.id(:a)

    assert {:ok, _, %DTO.Outcome{result: %DTO.CommandResult{kind: :history, rows: [row]}}, _} =
             command(script(), {:history_search, a, "build"})

    assert row.text == "Explain the build"
    assert {:ok, _} = DTO.HistoryRow.validate(row)
  end

  test "C15 the shell escape is accepted" do
    a = Script.id(:a)

    assert {:ok, next, %DTO.Outcome{status: :accepted}, _} =
             command(script(), {:shell_run, a, "ls"})

    assert {:ok, _, %DTO.Outcome{status: :accepted}, _} =
             command(next, {:shell_stop, a}, "fake-2")
  end

  test "C15 the read model keeps shell items apart from the runs" do
    item = %DTO.ShellItem{
      id: "5e110000-0000-4000-8000-000000000001",
      conversation_id: Script.id(:a),
      command: "ls",
      output: "mix.exs",
      state: :done,
      exit_code: 0,
      at: 1,
      revision: 1
    }

    delta = %SwarmCodeCLI.UI.DataSource.Delta{
      kind: :shell_upsert,
      entity_id: item.id,
      conversation_id: item.conversation_id,
      body: item,
      revision: 1
    }

    assert {:ok, _} = SwarmCodeCLI.UI.DataSource.Delta.validate(delta)

    assert {:ok, model, _, _} =
             SwarmCodeCLI.UI.ReadModel.delta(%SwarmCodeCLI.UI.ReadModel{}, :workspace, delta)

    assert model.shells[item.id] == item

    remove = %SwarmCodeCLI.UI.DataSource.Delta{kind: :shell_remove, entity_id: item.id}
    assert {:ok, _} = SwarmCodeCLI.UI.DataSource.Delta.validate(remove)
    assert {:ok, model, _, _} = SwarmCodeCLI.UI.ReadModel.delta(model, :workspace, remove)
    assert model.shells == %{}
  end

  test "C4 the fake source tells its clients the ncode app opened" do
    source =
      start_supervised!(
        {SwarmCodeCLI.UI.DataSource.Fake.Source,
         script: script(), source_epoch: "00000000-0000-4000-8000-0000000000ee"}
      )

    :ok = SwarmCodeCLI.UI.DataSource.Fake.Source.attach(source, "client-1", self())
    :ok = SwarmCodeCLI.UI.DataSource.Fake.Source.desktop_running(source, true)

    assert_receive {:fake_source, "client-1",
                    [%SwarmCodeCLI.UI.DataSource.Delta{kind: :desktop_running} = delta]}

    assert {:ok, _} = SwarmCodeCLI.UI.DataSource.Delta.validate(delta)
    assert delta.body == %DTO.DesktopPresence{running: true}
  end

  test "C4 the read model keeps the last desktop presence" do
    model = %SwarmCodeCLI.UI.ReadModel{}

    delta = %SwarmCodeCLI.UI.DataSource.Delta{
      kind: :desktop_running,
      body: %DTO.DesktopPresence{running: true}
    }

    assert {:ok, %{desktop_running: true}, [], []} =
             SwarmCodeCLI.UI.ReadModel.delta(model, :shell, delta)
  end
end
