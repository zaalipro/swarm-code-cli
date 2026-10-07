defmodule SwarmCode.Daemon.Service.C020DispatcherTest do
  @moduledoc """
  cli020 lane C: the slash commands the dispatcher answers differently in
  0.2.0 (one-shot /consensus, /search rows, structured /agents and /cost,
  /rename, /delete, /fork, bare /effort).
  """
  use ExUnit.Case, async: false
  import SwarmCode.Test.C020Backend
  alias SwarmCode.Daemon.Service.CommandDispatcher, as: Dispatcher
  alias SwarmCode.Domain.{Conversations, Engine}

  setup_all do
    setup_world("dispatcher")
  end

  setup c do
    {:ok, conv} = Conversations.create(c.project.id)
    on_exit(fn -> Engine.stop_all(conv.id) end)
    %{conversation: conv}
  end

  describe "C7 /consensus <task>" do
    test "is one-shot: the run is judged, the conversation keeps its mode", c do
      {conv, _, _} = provider!(c, c.conversation, fn _ -> {:text, "Done."} end)

      assert {:ok, %{type: :started, run_id: run_id}} =
               Dispatcher.dispatch(conv.id, "/consensus fix the flaky test")

      assert Conversations.get(conv.id).consensus == false
      assert Conversations.get(conv.id).mode == "build"
      assert Conversations.get_run(run_id).consensus == true
    end

    test "bare /consensus stays sticky", c do
      assert {:ok, %{type: :updated}} = Dispatcher.dispatch(c.conversation.id, "/consensus")
      assert Conversations.get(c.conversation.id).consensus == true
    end
  end
end
