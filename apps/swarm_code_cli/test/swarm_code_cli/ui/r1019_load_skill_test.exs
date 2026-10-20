defmodule SwarmCodeCLI.UI.R1019LoadSkillTest do
  @moduledoc """
  C-FEAT-2 (CLI part): the daemon's `load_skill` tool reads as "load skill
  release-notes" in the transcript, not as its raw name, and its inspector
  family is a read.
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.Test.Pass73Scenes
  alias SwarmCodeCLI.UI.{Paint, Projector}
  alias SwarmCodeCLI.UI.DataSource.DTO
  alias SwarmCodeCLI.UI.Paint.{Options, Plan}
  alias SwarmCodeCLI.UI.Projector.Inspector.Ops

  defp screen(state) do
    {scene, _} = Projector.project(state)

    {:ok, plan} =
      Paint.build(scene, %Options{
        color_mode: state.capabilities.color_mode,
        ascii?: state.capabilities.ascii?
      })

    for y <- 0..(state.size.rows - 1) do
      for x <- 0..(state.size.columns - 1), reduce: "" do
        acc ->
          case Plan.cell(plan, x, y) do
            {:glyph, glyph, _, _} -> acc <> glyph
            _ -> acc
          end
      end
    end
  end

  defp skill_scene(columns, rows) do
    state = Pass73Scenes.screenshot_11(columns, rows)
    chat = Pass73Scenes.chat_id()
    model = state.read_model

    tool = %DTO.TranscriptItem{
      id: "skill-tool-0",
      run_id: chat,
      conversation_id: "demo-panel",
      node_id: "skill-tool-node-0",
      agent_id: "agent-81-1",
      revision: 1,
      role: :assistant,
      kind: :tool,
      state: :done,
      text: "",
      reasoning: "",
      attempt_id: "demo-attempt",
      created_sequence: 81_010,
      at: state.now - 20_000,
      tool: %DTO.ToolCall{
        name: "load_skill",
        title: "load_skill release-notes",
        status: :done,
        detail: "ok"
      }
    }

    model = %{
      model
      | transcript: Map.put(model.transcript, tool.id, tool),
        order: %{model.order | workspace: model.order.workspace ++ [tool.id]}
    }

    %{state | read_model: model}
  end

  test "the load_skill tool reads as a verb and a target in the transcript" do
    for {columns, rows} <- [{160, 45}, {120, 36}] do
      text = columns |> skill_scene(rows) |> screen() |> Enum.join("\n")

      assert text =~ ~r/load skill\s+release-notes/, text
      refute text =~ "load_skill", text
    end
  end

  test "the load_skill family is a read mark" do
    assert Ops.family("load_skill") == {:ops_mark, :info}
    assert Ops.family("read_file") == Ops.family("load_skill")
  end
end
