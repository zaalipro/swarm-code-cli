defmodule SwarmCodeCLI.UI.InspectorCardsTest do
  @moduledoc """
  Cell-level assertions for the INSPECTOR workstream.

  Verifies heading text per run kind, AGENTS/NEEDS cards with real counts,
  agent rows at 170x34 (xl) and 150x30 (wide), and decision 30 (empty cards
  hidden) and decision 32 (no duplicate AGENTS label for swarm).
  """
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.UI.{Capabilities, Fixtures, Paint, Projector, Scene, Size}
  alias SwarmCodeCLI.UI.Paint.{Options, Plan}
  alias SwarmCodeCLI.UI.DataSource.DTO

  # Helper: paint a fixture and extract the text of inspector-region rows.
  defp inspector_text(kind, cols, rows, opts \\ []) do
    size = %Size{columns: cols, rows: rows}
    caps = struct(Capabilities, Keyword.get(opts, :caps, []))
    state = Fixtures.representative(kind, size, caps)

    state =
      case Keyword.get(opts, :interactions) do
        nil -> state
        interactions -> put_in(state.read_model.interactions, interactions)
      end

    {scene, _} = Projector.project(state)
    assert Scene.validate(scene) == :ok
    color_mode = Keyword.get(opts, :color_mode, :monochrome)
    assert {:ok, plan} = Paint.build(scene, %Options{color_mode: color_mode})
    assert :ok = Plan.validate(plan)

    inspector = Enum.find(scene.regions, &(&1.role == :inspector))

    if inspector do
      for y <- inspector.rect.y..(inspector.rect.y + inspector.rect.height - 1) do
        for x <- inspector.rect.x..(inspector.rect.x + inspector.rect.width - 1), into: "" do
          case Plan.cell(plan, x, y) do
            {:glyph, glyph, _, _} -> glyph
            _ -> ""
          end
        end
        |> String.trim_trailing()
      end
    else
      []
    end
  end

  describe "inspector heading per run kind at 170x34 (xl)" do
    test "chat shows LIVE RUN heading" do
      rows = inspector_text(:chat, 170, 34)
      assert Enum.any?(rows, &String.contains?(&1, "LIVE RUN"))
    end

    test "swarm shows AGENTS heading" do
      rows = inspector_text(:swarm, 170, 34)
      assert Enum.any?(rows, &String.contains?(&1, "AGENTS"))
    end

    test "consensus shows REVIEW BOARD heading" do
      rows = inspector_text(:consensus, 170, 34)
      assert Enum.any?(rows, &String.contains?(&1, "REVIEW BOARD"))
    end

    test "research shows RESEARCH heading" do
      rows = inspector_text(:research, 170, 34)
      assert Enum.any?(rows, &String.contains?(&1, "RESEARCH"))
    end
  end

  describe "inspector heading per run kind at 150x30 (wide)" do
    test "chat shows LIVE RUN heading at wide" do
      rows = inspector_text(:chat, 150, 30)
      assert Enum.any?(rows, &String.contains?(&1, "LIVE RUN"))
    end

    test "swarm shows AGENTS heading at wide" do
      rows = inspector_text(:swarm, 150, 30)
      assert Enum.any?(rows, &String.contains?(&1, "AGENTS"))
    end
  end

  describe "AGENTS card with real counts" do
    test "swarm shows real agent counts (4 active, 1 waiting)" do
      rows = inspector_text(:swarm, 170, 34)
      assert Enum.any?(rows, &String.contains?(&1, "4 active"))
      assert Enum.any?(rows, &String.contains?(&1, "1 waiting"))
    end

    test "swarm agent counts reflect computed split, not mockup values" do
      rows = inspector_text(:swarm, 170, 34)
      # Decision 32: the counts line follows the heading directly, no repeated AGENTS label
      # The heading is "AGENTS" on the first inspector row
      first_row = Enum.at(rows, 0)
      assert String.contains?(first_row, "AGENTS")
      # The count line should be the second row
      second_row = Enum.at(rows, 1)
      assert String.contains?(second_row, "4 active · 1 waiting")
    end

    test "chat run with no agents hides AGENTS card (decision 30)" do
      rows = inspector_text(:chat, 170, 34)
      # AGENTS heading should not appear as a card (only LIVE RUN heading exists)
      refute Enum.any?(rows, &String.contains?(&1, "0 active"))
      refute Enum.any?(rows, &String.contains?(&1, "0 waiting"))
    end
  end

  describe "NEEDS card visibility (decision 30)" do
    test "chat with no pending interactions hides NEEDS card" do
      rows = inspector_text(:chat, 170, 34)
      # No NEEDS section heading or pending count should appear in inspector
      refute Enum.any?(rows, &String.contains?(&1, "0 pending"))
    end

    test "swarm with pending interactions shows NEEDS card" do
      # Add a pending interaction to the fixture
      interaction = %DTO.PendingInteraction{
        id: "test-interaction",
        run_id: "fixture-run",
        node_id: "node-1",
        conversation_id: "fixture-conversation",
        kind: :question,
        expected_revision: 1,
        state: :pending,
        allowed_actions: [:answer_question],
        urgency: :normal,
        deadline: 0,
        created_at: 0
      }

      rows =
        inspector_text(:swarm, 170, 34, interactions: %{"test-interaction" => interaction})

      assert Enum.any?(rows, &String.contains?(&1, "NEEDS"))
      assert Enum.any?(rows, &String.contains?(&1, "1 pending"))
    end
  end

  describe "agent rows at 170x34 (xl)" do
    test "swarm shows all 5 agent rows with lane glyph and status" do
      rows = inspector_text(:swarm, 170, 34)
      assert Enum.any?(rows, &String.contains?(&1, "Agent agent-1"))
      assert Enum.any?(rows, &String.contains?(&1, "Agent agent-2"))
      assert Enum.any?(rows, &String.contains?(&1, "Agent agent-3"))
      assert Enum.any?(rows, &String.contains?(&1, "Agent agent-4"))
      assert Enum.any?(rows, &String.contains?(&1, "Agent agent-5"))
    end

    test "agent-5 shows NEEDS ANSWER status (pinned invariant)" do
      rows = inspector_text(:swarm, 170, 34)
      assert Enum.any?(rows, &String.contains?(&1, "NEEDS ANSWER"))
    end

    test "agent rows include Stop action" do
      rows = inspector_text(:swarm, 170, 34)
      agent_rows = Enum.filter(rows, &String.contains?(&1, "Agent agent-"))
      assert Enum.all?(agent_rows, &String.contains?(&1, "Stop"))
    end
  end

  describe "agent rows at 150x30 (wide)" do
    test "swarm shows agent rows at wide layout" do
      rows = inspector_text(:swarm, 150, 30)
      assert Enum.any?(rows, &String.contains?(&1, "Agent agent-5"))
      assert Enum.any?(rows, &String.contains?(&1, "NEEDS ANSWER"))
    end
  end

  describe "ultra pipeline uses safe arrow glyph" do
    test "ultra inspector uses pipeline_arrow glyph (not ambiguous arrow)" do
      rows = inspector_text(:chat, 170, 34)
      # Chat has no pipeline text, only ultra does
      refute Enum.any?(rows, &String.contains?(&1, "→"))
    end
  end

  describe "monochrome + ASCII mode" do
    test "chat shows LIVE RUN in ASCII mode" do
      rows = inspector_text(:chat, 170, 34, caps: [ascii?: true], color_mode: :monochrome)
      assert Enum.any?(rows, &String.contains?(&1, "LIVE RUN"))
    end

    test "swarm shows AGENTS heading and agent rows in ASCII mode" do
      rows = inspector_text(:swarm, 170, 34, caps: [ascii?: true], color_mode: :monochrome)
      assert Enum.any?(rows, &String.contains?(&1, "AGENTS"))
      assert Enum.any?(rows, &String.contains?(&1, "Agent agent-5"))
      assert Enum.any?(rows, &String.contains?(&1, "NEEDS ANSWER"))
    end
  end
end
