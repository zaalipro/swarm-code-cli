defmodule SwarmCodeCLI.Cli022.YF4EffortStatusTest do
  # cli022 F4: the status line shows the effort the next turn really uses
  # (`effort_effective`: the conversation's, else NCODE_EFFORT, else Settings'
  # default), not only a value the conversation stored.
  use ExUnit.Case, async: true

  import SwarmCodeCLI.Cli020EHelpers

  alias SwarmCodeCLI.UI.DataSource.DTO
  alias SwarmCodeCLI.UI.DataSource.Fake.Session

  defp status(state), do: state |> screen() |> List.last()

  defp chat,
    do: fixture(:chat, {120, 30}) |> put_workspace(chat_model: "claude-sonnet-5", effort: nil)

  test "with no stored effort the line shows the effective one" do
    line = chat() |> put_workspace(effort_effective: "medium", effort_source: :env) |> status()
    assert line =~ "claude-sonnet-5 · medium"

    line = chat() |> put_workspace(effort_effective: "high", effort_source: :default) |> status()
    assert line =~ "claude-sonnet-5 · high"
  end

  test "the effective level is what shows, even beside a stale stored value" do
    line =
      chat()
      |> put_workspace(effort: "low", effort_effective: "xhigh", effort_source: :conversation)
      |> status()

    assert line =~ "claude-sonnet-5 · xhigh"
  end

  test "an older daemon without the field still shows the stored value, or nothing" do
    assert chat() |> put_workspace(effort: "max") |> status() =~ "claude-sonnet-5 · max"
    refute chat() |> status() =~ ~r/claude-sonnet-5 · (low|medium|high|xhigh|max)/
  end

  test "the wire carries the fields and their source, metadata deltas included" do
    body = %{
      "conversation_id" => Ecto.UUID.generate(),
      "mode" => "build",
      "chat_model" => "claude-sonnet-5",
      "swarm_model" => nil,
      "effort" => nil,
      "swarm_effort" => nil,
      "effort_effective" => "medium",
      "effort_source" => "env",
      "swarm_effort_effective" => "low",
      "swarm_effort_source" => "default"
    }

    assert {:ok, %DTO.WorkspaceMetadata{} = meta} = DTO.WorkspaceMetadata.decode(body)
    assert {meta.effort_effective, meta.effort_source} == {"medium", :env}
    assert {meta.swarm_effort_effective, meta.swarm_effort_source} == {"low", :default}

    assert {:error, _} = DTO.WorkspaceMetadata.decode(%{body | "effort_source" => "flag"})
    # Optional on the wire: a daemon from before cli022 omits them.
    assert {:ok, %DTO.WorkspaceMetadata{effort_effective: nil}} =
             DTO.WorkspaceMetadata.decode(Map.drop(body, ~w(effort_effective effort_source
             swarm_effort_effective swarm_effort_source)))
  end

  test "the demo session reports its defaults until a level is set, and default clears it" do
    assert Session.effective_efforts(%{effort: nil, swarm_effort: nil}) == [
             effort_effective: "low",
             effort_source: :default,
             swarm_effort_effective: "medium",
             swarm_effort_source: :default
           ]

    assert Session.effective_efforts(%{effort: "high", swarm_effort: nil})[:effort_source] ==
             :conversation
  end
end
