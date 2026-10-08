defmodule SwarmCode.Daemon.Service.Cli022QuitSummaryTest do
  @moduledoc """
  cli022 F5: the quit summary's `Files changed` is the session's net change.
  It listed every path with a checkpoint row since the session started, and a
  rewind restores the files but keeps those rows, so a file `/rewind` put back
  was still "changed". A file whose content equals its state before the
  session's first write to it (or that did not exist then and does not now) is
  left out. Driven through the real persisted backend, loopback model and
  `rewind.apply`, then `PersistedSession.exit_summary/3`.
  """
  use ExUnit.Case, async: false
  import SwarmCode.Test.C020Backend
  alias SwarmCode.Domain.{Conversations, Engine}
  alias SwarmCodeCLI.Release.PersistedSession

  setup_all do
    setup_world("quit-summary")
  end

  # Turn 1 writes NOTES.md (it held "original"), turn 2 creates new.md.
  defp two_turns(c) do
    {:ok, conv} = Conversations.create(c.project.id)
    on_exit(fn -> Engine.stop_all(conv.id) end)
    notes = Path.join(c.root, "NOTES.md")
    fresh = Path.join(c.root, "new.md")
    File.write!(notes, "original\n")
    File.rm(fresh)
    started = DateTime.add(DateTime.utc_now(), -1, :second)

    {conv, _, _} =
      provider!(c, conv, fn
        1 -> {:tool, "write_file", %{"path" => "NOTES.md", "content" => "changed\n"}}
        2 -> {:text, "wrote notes"}
        3 -> {:tool, "write_file", %{"path" => "new.md", "content" => "fresh\n"}}
        4 -> {:text, "wrote new"}
        _ -> :hang
      end)

    backend = start_backend(c, conv)

    for text <- ["first", "second"] do
      assert {:ok, %{"value" => %{"status" => "accepted"}}} =
               send_text(backend, scope(conv), text)

      assert eventually(fn -> Engine.running_runs(conv.id) == [] and settled?(conv, text) end)
    end

    assert File.read!(notes) == "changed\n"
    assert File.read!(fresh) == "fresh\n"
    %{conv: conv, backend: backend, notes: notes, fresh: fresh, started: started}
  end

  defp settled?(conv, text),
    do: Enum.any?(Conversations.list_runs(conv.id), &(&1.prompt == text and &1.status == "done"))

  defp files(c, t) do
    session = %{conversation: t.conv, project: c.project}
    PersistedSession.exit_summary(session, t.started, exchanges: 0).files
  end

  defp rewind!(t, prompt) do
    assert {:ok, %{"value" => %{"result" => %{"turns" => turns}}}} =
             command(t.backend, id("turns"), scope(t.conv), :rewind_turns, %{})

    turn = Enum.find(turns, &(&1["prompt"] == prompt))

    assert {:ok, %{"value" => %{"status" => "accepted"}}} =
             command(t.backend, id("rewind"), scope(t.conv), :rewind_apply, %{
               "message_id" => turn["message_id"],
               "scope" => "files"
             })
  end

  test "a file a rewind restored is not changed; one it left is", c do
    t = two_turns(c)
    assert files(c, t) == ["NOTES.md", "new.md"]

    # Rewinding the second turn deletes new.md (it did not exist before).
    rewind!(t, "second")
    refute File.exists?(t.fresh)
    assert files(c, t) == ["NOTES.md"]

    # Rewinding the first puts NOTES.md back to "original".
    rewind!(t, "first")
    assert File.read!(t.notes) == "original\n"
    assert files(c, t) == []

    assert PersistedSession.summary_text(
             PersistedSession.exit_summary(
               %{conversation: t.conv, project: c.project},
               t.started,
               exchanges: 0
             )
           ) =~ "Resume"

    refute PersistedSession.summary_text(
             PersistedSession.exit_summary(
               %{conversation: t.conv, project: c.project},
               t.started,
               exchanges: 0
             )
           ) =~ "Files changed"
  end

  test "the net change: a hand revert counts, a change after a rewind counts again", c do
    t = two_turns(c)
    File.write!(t.notes, "original\n")
    assert files(c, t) == ["new.md"]

    File.write!(t.notes, "original\nand more\n")
    File.rm!(t.fresh)
    assert files(c, t) == ["NOTES.md"]
  end
end
