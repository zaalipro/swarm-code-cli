defmodule SwarmCodeCLI.UI.DataSource.ReadModelPass71Test do
  @moduledoc """
  pass71 F17 (review R5): a command denied with `D` vanished from the live
  transcript and came back only when the conversation was reopened. The
  approval's interaction and the op's transcript item share the op's id, and
  `interaction_remove` took that id out of the workspace order the transcript
  draws from.
  """
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.UI.ReadModel
  alias SwarmCodeCLI.UI.DataSource.{Delta, DTO}

  @run "33333333-3333-4333-8333-333333333333"
  @conversation "22222222-2222-4222-8222-222222222222"
  @op "44444444-4444-4444-8444-444444444444"

  defp op(state),
    do: %DTO.TranscriptItem{
      id: @op,
      run_id: @run,
      conversation_id: @conversation,
      node_id: @op,
      revision: 7,
      role: :tool,
      kind: :tool,
      state: state,
      text: "",
      tool: %DTO.ToolCall{name: "run_command", title: "run: mkdir x", status: state}
    }

  test "settling an approval keeps its op in the transcript order" do
    snapshot = %DTO.WorkspaceSnapshot{
      conversation_id: @conversation,
      transcript: %DTO.TranscriptWindow{items: [op(:waiting_approval)]},
      runs_page: %DTO.PageInfo{},
      interactions_page: %DTO.PageInfo{}
    }

    model = ReadModel.snapshot(%ReadModel{}, :workspace, snapshot)
    assert @op in model.order.workspace

    remove = %Delta{kind: :interaction_remove, entity_id: @op, run_id: @run}
    assert {:ok, model, [], [@op]} = ReadModel.delta(model, :workspace, remove)
    assert @op in model.order.workspace

    upsert = %Delta{kind: :node_upsert, entity_id: @op, run_id: @run, body: op(:stopped)}
    assert {:ok, model, [@op], []} = ReadModel.delta(model, :workspace, upsert)
    assert model.transcript[@op].state == :stopped
    assert Enum.count(model.order.workspace, &(&1 == @op)) == 1

    # A transcript removal still takes it out.
    gone = %Delta{kind: :transcript_remove, entity_id: @op, run_id: @run}
    assert {:ok, model, [], [@op]} = ReadModel.delta(model, :workspace, gone)
    refute @op in model.order.workspace
  end
end
