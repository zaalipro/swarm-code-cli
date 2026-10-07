defmodule SwarmCode.Daemon.Service.ShellEscapeTest do
  @moduledoc """
  cli020 C15 (competitors-9): `!cmd` runs in the project, one at a time per
  conversation, and becomes a shell message the next turn reads.
  """
  use ExUnit.Case, async: false
  import SwarmCode.Test.C020Backend
  alias SwarmCode.Daemon.Service.ShellEscape
  alias SwarmCode.Domain.{Conversations, OSProcess}

  setup_all do
    setup_world("shell")
  end

  setup c do
    {:ok, conv} = Conversations.create(c.project.id)
    %{conversation: conv, backend: start_backend(c, conv)}
  end

  defp run(c, text),
    do: command(c.backend, id("shell"), scope(c.conversation), :shell_run, %{"command" => text})

  defp stop(c), do: command(c.backend, id("stop"), scope(c.conversation), :shell_stop, %{})

  defp shell_messages(c),
    do:
      c.conversation.id
      |> Conversations.list_messages()
      |> Enum.filter(&String.starts_with?(&1.content, "$ "))

  defp shells(c), do: workspace(c.backend, scope(c.conversation))["shells"]

  test "echo hi becomes a shell message and a shell item", c do
    assert {:ok, %{"value" => %{"status" => "accepted"}}} = run(c, "echo hi")
    assert eventually(fn -> shell_messages(c) != [] end)
    assert [%{content: "$ echo hi\nhi\n[exit 0]", run_id: nil}] = shell_messages(c)

    assert eventually(fn -> match?([%{"state" => "done"}], shells(c)) end)
    [item] = shells(c)
    assert {item["command"], item["output"], item["exit_code"]} == {"echo hi", "hi", 0}
    assert {:ok, decoded} = SwarmCodeCLI.UI.DataSource.DTO.ShellItem.decode(item)
    assert SwarmCodeCLI.UI.DataSource.DTO.ShellItem.exit(decoded) == 0
  end

  test "a second command is refused while one runs; stop ends it and kills it", c do
    marker = Path.join(c.path, "shell-#{System.unique_integer([:positive])}.pid")
    assert {:ok, _} = run(c, "echo $$ > #{marker}; exec sleep 30")
    assert eventually(fn -> File.exists?(marker) and File.read!(marker) != "" end)
    pid = marker |> File.read!() |> String.trim() |> String.to_integer()
    assert OSProcess.alive?(pid)

    assert eventually(fn -> match?([%{"state" => "running"}], shells(c)) end)

    assert {:ok, %{"value" => %{"status" => "rejected", "reason" => %{"code" => "busy"} = r}}} =
             run(c, "echo again")

    assert r["text"] == "A shell command is still running · Esc stops it."

    assert {:ok, %{"value" => %{"status" => "accepted"}}} = stop(c)
    assert [%{content: "$ echo $$ > " <> rest}] = shell_messages(c)
    assert String.ends_with?(rest, "[exit stopped]")
    assert eventually(fn -> not OSProcess.alive?(pid) end)
    assert eventually(fn -> match?([%{"state" => "stopped"}], shells(c)) end)
  end

  test "stopping the backend kills a running command", c do
    marker = Path.join(c.path, "shell-#{System.unique_integer([:positive])}.pid")
    assert {:ok, _} = run(c, "echo $$ > #{marker}; exec sleep 30")
    assert eventually(fn -> File.exists?(marker) and File.read!(marker) != "" end)
    pid = marker |> File.read!() |> String.trim() |> String.to_integer()
    ref = Process.monitor(c.backend)
    GenServer.stop(c.backend)
    assert_receive {:DOWN, ^ref, :process, _, _}
    assert eventually(fn -> not OSProcess.alive?(pid) end)
  end

  test "the message format round-trips" do
    content = ShellEscape.content("ls -la", "a\nb", 2)
    assert content == "$ ls -la\na\nb\n[exit 2]"

    assert %{command: "ls -la", output: "a\nb", exit_code: 2, state: :done} =
             ShellEscape.parse(content)

    assert %{state: :stopped} = ShellEscape.parse(ShellEscape.content("sleep 9", "", :stopped))
    assert ShellEscape.parse("Rewound 2 files") == nil
  end
end
