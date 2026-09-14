defmodule SwarmCodeCLI.UI.ProjectorModeTest do
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.Projector.Mode
  alias SwarmCodeCLI.UI.{Capabilities, Scroll, Size}
  alias SwarmCodeCLI.UI.Projector.Composer
  alias SwarmCodeCLI.UI.Scene.Block

  test "Ultra mode renders status strings without crashing" do
    state = %{
      read_model: %{transcript: %{}},
      capabilities: %Capabilities{size: %Size{columns: 80, rows: 24}}
    }

    run = %{id: "run-1", kind: :ultra, state: :running}

    assert [%{first_index: 0, items: items}] = Mode.project(state, run, 80, 10)
    assert items != []
  end

  test "mode content starts at the main scroll anchor" do
    transcript =
      for n <- 1..8, into: %{} do
        {"item-#{n}", %{run_id: "run-1", role: :assistant, text: "- [ ] item #{n}"}}
      end

    state = %{
      read_model: %{transcript: transcript},
      capabilities: %Capabilities{size: %Size{columns: 80, rows: 24}},
      scrolls: %{main: %Scroll{anchor: {"item-5", 0, :top}, follow?: false}}
    }

    run = %{id: "run-1", kind: :goal, state: :running}
    assert [%{first_index: first}] = Mode.project(state, run, 80, 2)
    assert first >= 4
  end

  test "composer names every selectable workspace mode" do
    for {workspace_mode, label} <- [
          {:build, "Build"},
          {:plan, "Plan"},
          {:swarm, "Swarm"},
          {:ultra, "Ultra"},
          {:workflow, "Workflow"},
          {:consensus, "Consensus"},
          {:research, "Research"}
        ] do
      state = %{read_model: %{snapshots: %{workspace: %{mode: workspace_mode}}}}
      assert Composer.mode_label(state) == label
    end
  end

  test "ultra pipeline uses safe ❯ glyph instead of ambiguous →" do
    state = %{
      read_model: %{transcript: %{}},
      capabilities: %Capabilities{size: %Size{columns: 80, rows: 24}}
    }

    run = %{id: "run-1", kind: :ultra, state: :streaming}
    assert [%{items: items}] = Mode.project(state, run, 80, 10)

    texts =
      items
      |> Enum.flat_map(fn
        %Block.RichText{spans: spans} ->
          Enum.map(spans, &SwarmCodeCLI.UI.SafeText.value(&1.text))

        %Block.Text{text: text} ->
          [SwarmCodeCLI.UI.SafeText.value(text)]
      end)

    assert Enum.any?(texts, &String.contains?(&1, "❯"))
    refute Enum.any?(texts, &String.contains?(&1, "→"))
  end

  test "consensus mode uses section_heading for PLAN and CHANGES labels" do
    transcript = %{
      "t1" => %{run_id: "run-1", role: :tool, text: "plan details here"},
      "t2" => %{run_id: "run-1", role: :tool, text: "change details here"}
    }

    state = %{
      read_model: %{transcript: transcript},
      capabilities: %Capabilities{size: %Size{columns: 80, rows: 24}}
    }

    run = %{id: "run-1", kind: :consensus, state: :done}
    assert [%{items: items}] = Mode.project(state, run, 80, 20)

    spans =
      items
      |> Enum.flat_map(fn
        %Block.RichText{spans: spans} -> spans
        _ -> []
      end)

    # PLAN and CHANGES should be section headings with bold modifier
    plan_span =
      Enum.find(spans, fn span ->
        SwarmCodeCLI.UI.SafeText.value(span.text) == "PLAN" and :bold in span.style.modifiers
      end)

    assert plan_span, "PLAN section heading should be bold"

    changes_span =
      Enum.find(spans, fn span ->
        SwarmCodeCLI.UI.SafeText.value(span.text) == "CHANGES" and :bold in span.style.modifiers
      end)

    assert changes_span, "CHANGES section heading should be bold"

    # Pinned strings must survive
    all_text =
      Enum.map_join(spans, " ", &SwarmCodeCLI.UI.SafeText.value(&1.text))

    assert all_text =~ "Consensus"
  end

  test "plan gate actions only appear when run allows :approve/:deny" do
    alias SwarmCodeCLI.UI.DataSource.DTO
    alias SwarmCodeCLI.UI.{Draft, Drafts, Editor, ReadModel, State}

    run = %DTO.RunSummary{
      id: "plan-run",
      conversation_id: "conv-1",
      kind: :chat,
      title: "Plan proposal",
      revision: 1,
      state: :done,
      allowed_actions: [:approve, :deny, :steer, :send],
      progress: nil
    }

    item = %DTO.TranscriptItem{
      id: "t1",
      run_id: run.id,
      conversation_id: run.conversation_id,
      node_id: "n1",
      revision: 1,
      role: :assistant,
      state: :done,
      text: "- [x] Step one\n- [ ] Step two",
      attempt_id: "a1"
    }

    # Pending approval interaction enables the plan gate
    interaction = %DTO.PendingInteraction{
      id: "interaction-1",
      run_id: run.id,
      node_id: "n1",
      conversation_id: run.conversation_id,
      kind: :approval,
      state: :pending,
      allowed_actions: [:approve, :deny],
      urgency: :normal
    }

    model = %ReadModel{
      runs: %{run.id => run},
      transcript: %{item.id => item},
      interactions: %{interaction.id => interaction},
      order: %{shell: [run.id], workspace: [item.id]},
      snapshots: %{workspace: %{mode: :plan, chat_model: "test"}}
    }

    editor = Editor.new(ambiguous_width: :narrow)
    draft = Draft.new({run.conversation_id, :main}, editor)
    drafts = Drafts.new(ambiguous_width: :narrow) |> Drafts.put(draft)

    state = %State{
      size: %Size{columns: 120, rows: 40},
      capabilities: %Capabilities{size: %Size{columns: 120, rows: 40}},
      source_epoch: "test",
      destination: {:run, run.id},
      read_model: model,
      drafts: drafts,
      focus: "composer",
      revision: 1
    }

    {scene, _} = SwarmCodeCLI.UI.Projector.project(state)
    main = Enum.find(scene.regions, &(&1.role == :main))

    # Find all blocks recursively
    all_blocks = collect_blocks(main.blocks)

    # Plan gate actions should be present (at least 2 decks: run actions + plan gate)
    decks = Enum.filter(all_blocks, &is_struct(&1, Block.ActionDeck))
    assert length(decks) >= 2, "Should have run action deck + plan gate deck"

    # Now test without :approve/:deny - gate should NOT appear
    run_no_gate = %{run | allowed_actions: [:send]}
    model_no_gate = %{model | runs: %{run.id => run_no_gate}}
    state_no_gate = %{state | read_model: model_no_gate}
    {scene2, _} = SwarmCodeCLI.UI.Projector.project(state_no_gate)
    main2 = Enum.find(scene2.regions, &(&1.role == :main))
    all_blocks2 = collect_blocks(main2.blocks)

    # Count total actions - should not include Approve/Decline/Revise
    decks2 = Enum.filter(all_blocks2, &is_struct(&1, Block.ActionDeck))

    all_actions =
      Enum.flat_map(decks2, fn deck ->
        Enum.map(deck.actions, fn
          %Block.Text{text: text} -> SwarmCodeCLI.UI.SafeText.value(text)
          other -> inspect(other)
        end)
      end)

    refute Enum.any?(all_actions, &(&1 == "Approve")),
           "Approve should not appear without :approve permission"

    refute Enum.any?(all_actions, &(&1 == "Decline")),
           "Decline should not appear without :deny permission"
  end

  test "activity urgency sort puts pending items first" do
    alias SwarmCodeCLI.UI.DataSource.DTO
    alias SwarmCodeCLI.UI.{Drafts, Editor, ReadModel, State}

    items = %{
      "a1" => %DTO.ActivityItem{
        id: "a1",
        run_id: "r1",
        kind: :running,
        state: :running,
        title: "Running task",
        revision: 1
      },
      "a2" => %DTO.ActivityItem{
        id: "a2",
        run_id: "r2",
        kind: :question,
        state: :waiting_question,
        title: "Pending question",
        revision: 2
      },
      "a3" => %DTO.ActivityItem{
        id: "a3",
        run_id: "r3",
        kind: :failure,
        state: :failed,
        title: "Failed task",
        revision: 3
      }
    }

    model = %ReadModel{
      runs: %{},
      transcript: %{},
      activity: items,
      order: %{},
      snapshots: %{}
    }

    _editor = Editor.new(ambiguous_width: :narrow)
    drafts = Drafts.new(ambiguous_width: :narrow)

    state = %State{
      size: %Size{columns: 120, rows: 40},
      capabilities: %Capabilities{size: %Size{columns: 120, rows: 40}},
      source_epoch: "test",
      destination: :activity,
      read_model: model,
      drafts: drafts,
      focus: "main",
      revision: 1
    }

    {scene, _} = SwarmCodeCLI.UI.Projector.project(state)
    main = Enum.find(scene.regions, &(&1.role == :main))
    list = Enum.find(main.blocks, &is_struct(&1, Block.VirtualList))
    assert list

    texts =
      Enum.map(list.items, fn
        %Block.RichText{spans: spans} ->
          Enum.map_join(spans, &SwarmCodeCLI.UI.SafeText.value(&1.text))

        other ->
          inspect(other)
      end)

    # Pending (waiting_question) should sort before running, which sorts before failed
    pending_idx = Enum.find_index(texts, &String.contains?(&1, "Pending question"))
    running_idx = Enum.find_index(texts, &String.contains?(&1, "Running task"))
    failed_idx = Enum.find_index(texts, &String.contains?(&1, "Failed task"))

    assert pending_idx < running_idx, "Pending items should sort before running"
    assert running_idx < failed_idx, "Running items should sort before failed"
  end

  defp collect_blocks(%{__struct__: _} = x),
    do: [x | x |> Map.from_struct() |> Map.values() |> Enum.flat_map(&collect_blocks/1)]

  defp collect_blocks(x) when is_list(x), do: Enum.flat_map(x, &collect_blocks/1)
  defp collect_blocks(_), do: []
end
