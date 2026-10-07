defmodule SwarmCodeCLI.UI.Cli020.D20LocalCommandsTest do
  @moduledoc "cli020 D20: the client-local slash commands (/queue …, /delete, and D10/D18's)."
  use ExUnit.Case, async: true

  import SwarmCodeCLI.Test.Cli020State

  alias SwarmCodeCLI.Test.Cli020State
  alias SwarmCodeCLI.UI.{Input, Keymap, Reducer}
  alias SwarmCodeCLI.UI.Reducer.{QueueCommands, Remote}

  @c Cli020State.conversation()
  @rev "0123456789abcdef"

  defp queued do
    state = ready(snapshot: %{queued_texts: ["first", "second"]})
    workspace = Map.put(state.read_model.snapshots.workspace, :queue_revision, @rev)

    %{
      state
      | read_model: %{
          state.read_model
          | snapshots: Map.put(state.read_model.snapshots, :workspace, workspace)
        }
    }
  end

  test "each local word, and the ones that stay the daemon's" do
    for {text, command} <- [
          {"/rewind", :rewind},
          {"/undo", :undo},
          {"/effort", {:effort, :chat}},
          {"/swarm_effort", {:effort, :swarm}},
          {"/delete", :delete},
          {"/queue", :queue},
          {"/queue clear", :queue},
          {"/queue drop 2", :queue}
        ] do
      assert Keymap.local_command(text) == command, text
    end

    for text <- ["/effort high", "/swarm_effort low", "/rewind 3", "/delete now"],
        do: assert(Keymap.local_command(text) == nil, text)
  end

  test "/queue alone lists the queue" do
    assert QueueCommands.parse("") == :list
    {state, _} = queued() |> type("/queue") |> send_draft()

    if Remote.drawable?({:queue_list}),
      do: assert([{:queue_list} | _] = state.layers),
      else:
        assert(
          state.notice == {:command_feedback, "The queue list is not drawn in this build yet."}
        )
  end

  test "/queue clear and /queue drop N send queue_edit with the workspace's revision" do
    for {text, edit} <- [{"/queue clear", :clear}, {"/queue drop 2", {:drop, 2}}] do
      {state, effects} = queued() |> type(text) |> send_draft()
      intent = {:queue_edit, @c, @rev, edit}

      if landed?(intent) do
        assert commands(effects) == [intent]
        assert text(state) == ""
      else
        assert state.notice == {:command_feedback, Remote.unavailable_words()}
      end
    end
  end

  test "/queue drop out of range or not a number says so" do
    {state, []} = queued() |> type("/queue drop 3") |> send_draft()
    assert state.notice == {:command_feedback, "The queue has 2 message(s): /queue drop 1..2."}
    {state, []} = queued() |> type("/queue drop x") |> send_draft()
    assert state.notice == {:command_feedback, "Drop which message? /queue drop N, N from 1."}
  end

  test "/queue with other words still queues them as text" do
    assert QueueCommands.parse("fix the build") == :text
    assert QueueCommands.parse("clear the cache") == :text
  end

  test "d on a row of the queue list drops that message" do
    state = %{queued() | layers: [{:queue_list}]}
    assert {:ok, {:queue_move, 1}} = Keymap.resolve(Input.key(:down), state, %{})
    {state, []} = Reducer.update(state, {:queue_move, 1})
    assert {:ok, {:queue_drop}} = Keymap.resolve(Input.text_fragment(:press, "d", []), state, %{})
    {_state, effects} = Reducer.update(state, {:queue_drop})
    intent = {:queue_edit, @c, @rev, {:drop, 2}}
    if landed?(intent), do: assert(commands(effects) == [intent])
  end

  test "bare /delete asks first; a second within 5 s sends it" do
    state = %{ready() | now: 1_000}

    {state, effects} = state |> type("/delete") |> send_draft()
    assert commands(effects) == []

    assert state.notice ==
             {:command_feedback,
              "Delete this conversation? Send /delete again within 5 s to confirm."}

    assert text(state) == ""
    {_state, effects} = %{state | now: 3_000} |> type("/delete") |> send_draft()
    assert [{:dispatch, :send, "/delete", :main, []}] = commands(effects)
  end
end
