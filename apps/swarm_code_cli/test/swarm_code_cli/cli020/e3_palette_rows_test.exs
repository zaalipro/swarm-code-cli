defmodule SwarmCodeCLI.Cli020.E3PaletteRowsTest do
  # cli020 E3: the `/` list shows the client-local meaning of the commands
  # D20 answers itself (bare /queue, /rewind, /undo, /delete, /effort,
  # /worker_effort), with the words of the core registry.
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.SlashPalette

  defp row(name), do: Enum.find(SlashPalette.catalogue("/"), &(&1.name == name))

  test "the local rows carry the local meaning" do
    assert %{args: "<text> | clear | drop N", client: true} = row("queue")
    assert row("rewind").desc == "Rewind the conversation and files to before an earlier turn"
    assert row("rewind").client
    assert row("undo").desc == "Rewind the last turn: its messages and its files"
    assert row("undo").client
    assert row("delete").desc == "Delete this conversation (asks first)"
    assert row("delete").client
    assert %{args: "[low|medium|high|max]", client: true} = row("effort")
    assert row("effort").desc =~ "Reasoning effort of this conversation's chat model"
    assert %{args: "[low|medium|high|max]", client: true} = row("worker_effort")
    assert row("worker_effort").desc =~ "Reasoning effort of this conversation's worker model"
  end

  test "each name is listed once" do
    names = Enum.map(SlashPalette.catalogue("/"), & &1.name)
    assert names == Enum.uniq(names)
  end

  test "/rename and /fork come from the core registry" do
    assert row("rename").args == "<title>"
    assert row("fork").desc == "Copy this conversation into a new one and open it"
  end
end
