defmodule SwarmCode.Domain.Engine.CliUltraTest do
  # cli020 A6 (parity-7, owner Q6): desktop 0.2.0's Ultra is missions
  # (`mission_start` and its approval card). The CLI has no mission card yet,
  # so its Ultra keeps the workflow tool set and prompt (two recorded CLI
  # patches on the synced `tools.ex` and `prompts.ex`); the builtin mission
  # workflow stays on disk but out of every list.
  use ExUnit.Case, async: true

  alias SwarmCode.Domain.{Tools, Workflows}
  alias SwarmCode.Domain.Engine.Prompts
  alias SwarmCode.Domain.Projects.Project

  @project %Project{name: "ultra", root_path: "/tmp/ultra"}

  test "the Ultra tool set has the workflow tools and no mission_start" do
    names = "assistant" |> Tools.for_agent(0, 2, "build", ultra: true) |> Enum.map(& &1.name)

    assert "workflow_run" in names
    assert "start_swarm" in names
    refute "mission_start" in names
  end

  test "the Ultra system prompt is the CLI's workflow procedure" do
    text = Prompts.assistant(@project, ultra: true)

    assert text =~ "author and launch a workflow"
    assert text =~ "or turned Ultra mode on"
    assert text =~ "WORKFLOW AUTHORING MODE"
    refute text =~ "mission_start"
    refute text =~ "MISSIONS"
  end

  test "a plain turn names no mission either" do
    refute Prompts.assistant(@project) =~ "mission_start"
  end

  test "the builtin mission workflow is listed nowhere" do
    refute Enum.any?(Workflows.list(nil), &(&1.name == "mission"))
  end
end
