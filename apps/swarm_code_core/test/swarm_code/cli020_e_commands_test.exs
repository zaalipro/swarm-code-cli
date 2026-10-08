defmodule SwarmCode.Cli020ECommandsTest do
  # cli020 E2 (parity-7, Q6) and E3 (bugs-7, ux-live-9, tui-code-14,
  # decisions 4f/4h): the honest Ultra words and the new registry rows.
  use ExUnit.Case, async: true

  alias SwarmCode.Commands

  defp desc(name), do: Enum.find(Commands.catalogue("/"), &(&1.name == name)).desc

  describe "E2 honest Ultra" do
    test "the mode hint and the /ultra description say workflows here, missions in the app" do
      {"ultra", "Ultra", _glyph, hint, _icon} = List.keyfind(Commands.modes(), "ultra", 0)
      assert hint == "big tasks run as workflows (missions are in the ncode app)"

      assert desc("ultra") ==
               "Toggle Ultra — big tasks run as workflows here; missions are in the ncode app for now"
    end
  end

  describe "E3 registry additions" do
    test "/rename <title> renames; an empty title is a missing argument" do
      assert {:ok, %{action: :rename_conversation, title: "New name"}} =
               Commands.parse("/rename New name")

      assert {:error, %{type: :missing_argument}} = Commands.parse("/rename")
      assert {:error, %{type: :invalid_argument}} = Commands.parse("/rename a\u0007b")
      assert desc("rename") == "Rename this conversation"
    end

    test "/delete, /fork and /undo take no argument" do
      assert {:ok, %{action: :delete_conversation}} = Commands.parse("/delete")
      assert {:ok, %{action: :fork_conversation}} = Commands.parse("/fork")
      assert {:ok, %{action: :undo_turn}} = Commands.parse("/undo")

      for name <- ~w(delete fork undo),
          do: assert({:error, %{type: :unexpected_argument}} = Commands.parse("/#{name} x"))

      assert desc("delete") == "Delete this conversation (asks first)"
      assert desc("fork") == "Copy this conversation into a new one and open it"
      assert desc("undo") == "Rewind the last turn: its messages and its files"
    end

    test "bare /effort and /worker_effort show the effort" do
      assert {:ok, %{action: :show_effort, target: :chat}} = Commands.parse("/effort")
      assert {:ok, %{action: :show_effort, target: :swarm}} = Commands.parse("/worker_effort")

      assert {:ok, %{action: :set_effort, effort: :high, target: :chat}} =
               Commands.parse("/effort high")
    end

    test "the reworded descriptions" do
      assert desc("rewind") == "Rewind the conversation and files to before an earlier turn"
      assert desc("consensus") == "Consensus mode; with a task, judge this one turn only"
      assert desc("quit") == "Leave ncode; running work of this session stops"
    end

    test "/queue is not a core command (it is the client's, D20)" do
      assert {:error, %{type: :unknown_command}} = Commands.parse("/queue clear")
    end
  end
end
