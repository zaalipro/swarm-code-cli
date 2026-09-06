defmodule SwarmCodeCLI.UI.Paint.ProjectorTest do
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{
    Capabilities,
    Drafts,
    Editor,
    Fixtures,
    Layout,
    Paint,
    Projector,
    Size,
    State,
    Width
  }

  alias SwarmCodeCLI.UI.Paint.{Metrics, Options, Plan}
  alias SwarmCodeCLI.UI.Scene.Block
  alias SwarmCodeCLI.UI.Projector.Workspace
  alias SwarmCodeCLI.UI.DataSource.DTO.{PendingInteraction, Question, QuestionOption}

  @sizes [
    {80, 24},
    {120, 40},
    {160, 50},
    {170, 34},
    {169, 34},
    {150, 30},
    {149, 30},
    {150, 29},
    {100, 24},
    {99, 24},
    {100, 23},
    {72, 20},
    {71, 20},
    {72, 19},
    {50, 16},
    {50, 15},
    {50, 14},
    {49, 14},
    {50, 13},
    {1, 1}
  ]

  defp fixture(kind, {columns, rows}, policy \\ :narrow, color \\ :truecolor, ascii \\ false) do
    size = %Size{columns: columns, rows: rows}
    caps = %Capabilities{size: size, ambiguous_width: policy, color_mode: color, ascii?: ascii}
    Fixtures.representative(kind, size, caps)
  end

  defp paint(state) do
    {scene, table} = Projector.project(state)

    options = %Options{
      color_mode: state.capabilities.color_mode,
      ascii?: state.capabilities.ascii?
    }

    assert {:ok, plan} = Paint.build(scene, options)
    assert :ok = Plan.validate(plan)
    assert plan.diagnostics == []
    assert MapSet.new(Map.keys(plan.actions)) == MapSet.new(Map.keys(table))
    assert Enum.all?(plan.actions, fn {_, rects} -> rects != [] end)
    {scene, table, plan}
  end

  defp row(plan, y, x \\ 0, width \\ nil) do
    width = width || plan.size.columns

    for column <- x..(x + width - 1), reduce: "" do
      text ->
        case Plan.cell(plan, column, y) do
          {:glyph, glyph, _, _} -> text <> glyph
          _ -> text
        end
    end
  end

  defp screen(plan), do: Enum.map_join(0..(plan.size.rows - 1), "\n", &row(plan, &1))

  test "all representative fixtures paint visible facts and every projected action across layout boundaries" do
    for kind <- [:chat, :swarm, :consensus, :research], size <- @sizes do
      {scene, table, plan} = paint(fixture(kind, size))

      if scene.layout_class == :too_small do
        assert plan.actions == %{}
        refute Enum.any?(Map.values(table), &match?({:intent, _}, &1))
        assert screen(plan) =~ "S"
      else
        pixels = screen(plan)

        for fact <- ["NO USER DATA", "Build", "NEEDS", "Focus"] do
          assert pixels =~ fact, "#{kind} #{inspect(size)} is missing #{fact}"
        end

        refute pixels =~ "Target: Main"
        refute pixels =~ "Validation: none"

        assert row(plan, 0) =~ "Build"
        assert row(plan, plan.size.rows - 1) =~ "Focus"

        if scene.layout_class == :compressed_small do
          refute Enum.any?(Map.values(table), &match?({:intent, _}, &1))
          assert pixels =~ "Resize help"
        end
      end
    end
  end

  test "all capability combinations preserve visible actions and composer cell position" do
    for kind <- [:chat, :swarm, :consensus, :research],
        policy <- [:narrow, :wide],
        color <- [:truecolor, :ansi256, :ansi16, :monochrome],
        ascii <- [false, true],
        size <- [{80, 24}, {120, 40}, {160, 50}, {50, 16}] do
      state = fixture(kind, size, policy, color, ascii)
      key = State.current_draft_key(state)
      draft = Drafts.fetch(state.drafts, key)
      prefix = "界·é "
      {:ok, editor} = Editor.apply(draft.editor, {:insert, prefix <> "X"})
      {:ok, editor} = Editor.apply(editor, {:move, :left})
      state = %{state | drafts: Drafts.put(state.drafts, %{draft | editor: editor})}
      {scene, _, plan} = paint(state)
      composer = Enum.find(scene.regions, &(&1.role == :composer))
      assert plan.cursor == scene.cursor
      assert plan.cursor.x == composer.rect.x + Width.cells(prefix, policy)
      assert plan.cursor.y == composer.rect.y
      assert {:glyph, "X", 1, _} = Plan.cell(plan, plan.cursor.x, plan.cursor.y)
      assert row(plan, composer.rect.y, composer.rect.x, composer.rect.width) =~ prefix <> "X"
    end
  end

  test "question focus is revealed in actual cells and modal actions have no background targets" do
    item = %PendingInteraction{
      id: "question",
      run_id: "fixture-run",
      node_id: "node",
      conversation_id: "fixture-conversation",
      expected_revision: 3,
      question: %Question{
        prompt: "Choose",
        options:
          for(
            i <- 1..20,
            do: %QuestionOption{
              id: "option-#{i}",
              label: "Choice #{i}: " <> String.duplicate("wrapped choice ", 15)
            }
          )
      },
      allowed_actions: [:answer_question]
    }

    target = {:intent, {:answer_question, item.run_id, item.node_id, item.id, 3, ["option-20"]}}

    for size <- [{50, 16}, {72, 20}, {120, 40}],
        policy <- [:narrow, :wide],
        ascii <- [false, true] do
      state = fixture(:chat, size, policy, :monochrome, ascii)
      state = put_in(state.read_model.interactions[item.id], item)
      {scene, table, plan} = paint(%{state | layers: [{:question, item.id}], focus: "option-20"})
      assert scene.overlay.body_scroll > 0
      assert plan.cursor == nil
      assert plan.focus.control_id == "option-20"
      assert target in Map.values(table)
      refute {:intent, {:run_control, :stop, item.run_id}} in Map.values(table)
      assert screen(plan) =~ "wrapped choice"
      assert screen(plan) =~ "Cancel"
      assert length(String.split(screen(plan), "FOCUS >")) - 1 == 1
      {id, _} = Enum.find(table, fn {_, value} -> value == target end)
      [focused | _] = plan.actions[id]
      assert row(plan, focused.y, focused.x, focused.width) =~ "FOCUS >"
    end
  end

  test "confirmation controls remain visible and compressed projection removes mutation targets" do
    for size <- [{50, 16}, {72, 20}, {120, 40}, {50, 14}], policy <- [:narrow, :wide] do
      state = fixture(:chat, size, policy)
      target = {:intent, {:run_control, :stop, "fixture-run"}}

      {scene, table, plan} =
        paint(%{state | layers: [{:confirm_intent, elem(target, 1)}], focus: "cancel"})

      assert plan.focus.control_id == "cancel"
      assert screen(plan) =~ "Cancel"
      {id, _} = Enum.find(table, fn {_, value} -> value == {:local, :close_top_layer} end)
      [focused | _] = plan.actions[id]
      assert row(plan, focused.y, focused.x, focused.width) =~ "FOCUS > Cancel"
      assert length(String.split(screen(plan), "FOCUS >")) - 1 == 1
      assert target in Map.values(table) == (scene.layout_class != :compressed_small)
    end
  end

  test "notice and recovery chrome measurements match actual rows before the transcript" do
    for size <- [{50, 16}, {72, 20}, {100, 24}, {150, 30}],
        policy <- [:narrow, :wide],
        notice <- [
          nil,
          {:input_rejected, :paste_too_large},
          {:input_rejected, :paste_preallocation_bound_exceeded}
        ],
        status <- [:streaming, :failed] do
      state = fixture(:chat, size, policy)
      state = put_in(state.read_model.runs["fixture-run"].state, status)

      item = %{
        state.read_model.transcript["002"]
        | text: Enum.map_join(1..100, "\n", fn _ -> "transcript line" end)
      }

      state = %{
        state
        | notice: notice,
          read_model: %{
            state.read_model
            | transcript: %{item.id => item},
              order: %{workspace: [item.id]}
          },
          watches: %{workspace: %SwarmCodeCLI.UI.WatchState{status: :resyncing}}
      }

      {scene, _, plan} = paint(state)
      main = Enum.find(scene.regions, &(&1.role == :main))
      chrome = Enum.take_while(main.blocks, &(not is_struct(&1, Block.VirtualList)))
      options = %Options{color_mode: state.capabilities.color_mode}
      assert {:ok, rows} = Metrics.height(chrome, main.rect.width, options, 200, policy)
      layout = Layout.calculate(state.size, state.preferences)
      height = Workspace.content_height(state, main.rect, layout.class)
      assert height == min(max(0, main.rect.height - rows), div(main.rect.height * 45, 100))

      assert Enum.count(main.rect.y..(main.rect.y + main.rect.height - 1), fn y ->
               row(plan, y, main.rect.x, main.rect.width) =~ "transcript line"
             end) == height

      if notice, do: assert(screen(plan) =~ "INPUT REJECTED")
      assert screen(plan) =~ "RESYNCING"
    end
  end

  test "three run statuses retain exact independent actions in painted cells" do
    state = fixture(:swarm, {170, 34})
    original = state.read_model.runs["fixture-run"]

    runs = [
      %{
        original
        | id: "failed",
          title: "Failed run",
          state: :failed,
          allowed_actions: [:retry],
          revision: 7
      },
      %{
        original
        | id: "interrupted",
          title: "Interrupted run",
          state: :interrupted,
          allowed_actions: [:resume]
      },
      %{
        original
        | id: "superseded",
          title: "Superseded run",
          state: :superseded,
          allowed_actions: []
      }
    ]

    model = %{
      state.read_model
      | runs: Map.new(runs, &{&1.id, &1}),
        order: %{shell: Enum.map(runs, & &1.id)}
    }

    for run <- runs do
      {_, table, plan} = paint(%{state | read_model: model, destination: {:run, run.id}})
      assert screen(plan) =~ String.upcase(Atom.to_string(run.state))
      assert {:intent, {:retry_run, "failed", 7}} in Map.values(table) == (run.id == "failed")

      assert {:intent, {:run_control, :resume, "interrupted"}} in Map.values(table) ==
               (run.id == "interrupted")

      refute {:intent, {:run_control, :stop, "superseded"}} in Map.values(table)
    end
  end

  test "wrapped interaction action deck reserves its actual rows" do
    for policy <- [:narrow, :wide] do
      state = fixture(:chat, {50, 16}, policy)
      key = State.current_draft_key(state)
      draft = Drafts.fetch(state.drafts, key)
      {:ok, editor} = Editor.apply(draft.editor, {:insert, "Ready"})
      state = %{state | drafts: Drafts.put(state.drafts, %{draft | editor: editor})}

      state =
        put_in(
          state.read_model.snapshots[:workspace],
          %SwarmCodeCLI.UI.DataSource.DTO.WorkspaceSnapshot{allowed_actions: [:send, :queue]}
        )

      interactions =
        for kind <- [:question, :approval], into: %{} do
          id = Atom.to_string(kind)

          {id,
           %PendingInteraction{
             id: id,
             kind: kind,
             run_id: "fixture-run",
             node_id: id,
             conversation_id: "fixture-conversation",
             allowed_actions: []
           }}
        end

      transcript =
        Map.new(state.read_model.transcript, fn {id, item} ->
          {id,
           %{item | detail_ref: %SwarmCodeCLI.UI.DataSource.DTO.DetailRef{id: "detail-" <> id}}}
        end)

      state = %{
        state
        | read_model: %{state.read_model | interactions: interactions, transcript: transcript}
      }

      {scene, table, plan} = paint(state)
      main = Enum.find(scene.regions, &(&1.role == :main))
      deck = Enum.find(main.blocks, &is_struct(&1, Block.ActionDeck))
      assert {:ok, deck_height} = Metrics.height(deck, main.rect.width, %Options{}, 200, policy)
      assert deck_height > 1

      for kind <- [:question, :approval] do
        assert {:local, {:open_layer, {kind, Atom.to_string(kind)}}} in Map.values(table)
      end

      assert screen(plan) =~ "NEEDS ANSWER"
      assert screen(plan) =~ "NEEDS APPROVAL"
      chrome = Enum.take_while(main.blocks, &(not is_struct(&1, Block.VirtualList)))
      assert {:ok, height} = Metrics.height(chrome, main.rect.width, %Options{}, 200, policy)

      assert Workspace.content_height(state, main.rect, scene.layout_class) ==
               min(max(0, main.rect.height - height), div(main.rect.height * 45, 100))
    end
  end

  test "transcript section headers occupy rows within the shared content viewport" do
    for {kind, status} <- [{:consensus, :done}, {:research, :done}, {:chat, :superseded}] do
      state = fixture(kind, {50, 16})

      item = %{
        state.read_model.transcript["002"]
        | role: :tool,
          state: status,
          text: Enum.map_join(1..100, "\n", fn _ -> "retained evidence" end)
      }

      state = %{
        state
        | read_model: %{
            state.read_model
            | transcript: %{item.id => item},
              order: %{workspace: [item.id]}
          }
      }

      {scene, _, _} = paint(state)
      main = Enum.find(scene.regions, &(&1.role == :main))
      list = Enum.find(main.blocks, &is_struct(&1, Block.VirtualList))
      assert {:ok, actual_rows} = Metrics.height(list, main.rect.width)
      assert actual_rows == Workspace.content_height(state, main.rect, scene.layout_class)
    end
  end

  test "run status appears once while retry and resume availability remain visible" do
    for status <- [:streaming, :failed, :interrupted, :superseded],
        color <- [:truecolor, :monochrome] do
      state = fixture(:chat, {80, 24}, :narrow, color)
      state = put_in(state.read_model.runs["fixture-run"].state, status)
      state = put_in(state.read_model.runs["fixture-run"].allowed_actions, [:retry, :resume])
      {scene, _, plan} = paint(state)
      main = Enum.find(scene.regions, &(&1.role == :main))

      pixels =
        Enum.map_join(
          main.rect.y..(main.rect.y + main.rect.height - 1),
          "\n",
          &row(plan, &1, main.rect.x, main.rect.width)
        )

      word =
        status |> SwarmCodeCLI.UI.Theme.status() |> elem(0) |> SwarmCodeCLI.UI.SafeText.value()

      assert length(String.split(pixels, word)) - 1 == 1
      refute pixels =~ "RUNNING STREAMING"
      assert pixels =~ "RETRY AVAILABLE" == (status == :failed)
      assert pixels =~ "RESUME AVAILABLE" == (status == :interrupted)
    end
  end

  test "composer only shows decision-relevant target and validation facts" do
    for target <- [:none, :main, {:reply, "node"}],
        validation <- [:none, {:pending, "validation"}, {:invalid, ["attachment missing"]}] do
      state = fixture(:chat, {80, 24})
      key = State.current_draft_key(state)
      draft = Drafts.fetch(state.drafts, key)
      draft = %{draft | target: target, staged_validation: validation}
      state = %{state | drafts: Drafts.put(state.drafts, draft)}
      {_, _, plan} = paint(state)
      pixels = screen(plan)
      assert pixels =~ "Target: Reply" == match?({:reply, _}, target)
      refute pixels =~ "Target: Main"
      refute pixels =~ "Validation: none"
      assert pixels =~ "Validation: pending" == match?({:pending, _}, validation)
      assert pixels =~ "Validation: ERROR attachment missing" == match?({:invalid, _}, validation)
      assert Drafts.fetch(state.drafts, key) == draft
    end
  end

  test "empty needs is reported once and pending interactions stay prominent" do
    for activity_height <- [0, 1, 2] do
      state = fixture(:chat, {80, 24})
      state = %{state | preferences: %{state.preferences | activity_height: activity_height}}
      {_, _, plan} = paint(state)
      assert length(String.split(screen(plan), "NEEDS 0")) - 1 == 1

      item = %PendingInteraction{
        id: "pending",
        run_id: "fixture-run",
        node_id: "node",
        conversation_id: "fixture-conversation",
        allowed_actions: []
      }

      state = put_in(state.read_model.interactions[item.id], item)
      {scene, _, plan} = paint(state)
      main = Enum.find(scene.regions, &(&1.role == :main))
      assert row(plan, main.rect.y, main.rect.x, main.rect.width) =~ "NEEDS 1"
    end
  end

  test "inspector captions carry one status with their exact stop on the same row" do
    for color <- [:truecolor, :monochrome], policy <- [:narrow, :wide] do
      state = fixture(:swarm, {160, 50}, policy, color)
      {scene, table, plan} = paint(state)
      inspector = Enum.find(scene.regions, &(&1.role == :inspector))

      for agent <- Map.values(state.read_model.agents) do
        target = {:intent, {:stop_agent, agent.run_id, agent.id, agent.revision}}
        {id, _} = Enum.find(table, fn {_, value} -> value == target end)
        [rect | _] = plan.actions[id]
        text = row(plan, rect.y, inspector.rect.x, inspector.rect.width)

        word =
          agent.state
          |> SwarmCodeCLI.UI.Theme.status()
          |> elem(0)
          |> SwarmCodeCLI.UI.SafeText.value()

        assert text =~ agent.id
        assert text =~ "Stop"
        assert length(String.split(text, word)) - 1 == 1
      end
    end
  end

  test "prose wrapping preserves words and whitespace while fenced code retains cell wrapping" do
    alias SwarmCodeCLI.UI.Prose
    assert Prose.wrap("alpha beta gamma", 10, :narrow) == ["alpha beta", " gamma"]
    assert Prose.wrap("alpha beta gamma", 8, :narrow) == ["alpha ", "beta ", "gamma"]
    assert Prose.wrap("alpha  beta\n\ngamma", 8, :narrow) == ["alpha  ", "beta", "", "gamma"]
    assert Prose.wrap("abcdefghij", 4, :narrow) == ["abcd", "efgh", "ij"]

    assert Prose.wrap("```\nalpha beta gamma\n```", 8, :narrow) ==
             ["```", "alpha be", "ta gamma", "```"]

    for policy <- [:narrow, :wide] do
      text = "界· one é two permissions"
      lines = Prose.wrap(text, 10, policy)
      assert Enum.join(lines) == text
      assert Enum.all?(lines, &(Width.cells(&1, policy) <= 10))
    end
  end

  test "prose whitespace breaks retain complete combining graphemes after escaping" do
    alias SwarmCodeCLI.UI.{Prose, SafeText}

    for policy <- [:narrow, :wide], text <- ["aa \u0301bcdef", "aa \u0301\u0327bcdef"] do
      limits = %{SafeText.Limits.content() | ambiguous_width: policy}
      assert {:ok, safe} = SafeText.external(text, limits)
      lines = Prose.wrap(SafeText.value(safe), 4, policy)
      assert Enum.join(lines) == text
      assert Enum.all?(lines, &(Width.cells(&1, policy) <= 4))
      assert Enum.flat_map(lines, &String.graphemes/1) == String.graphemes(text)

      for line <- lines do
        assert {:ok, escaped} = SafeText.external(line, limits)
        assert SafeText.value(escaped) == line
      end
    end
  end

  test "oversized canonical scenes project normally and Paint rejects their capacity" do
    for size <- [{600, 40}, {120, 210}], layers <- [[], [:help]] do
      state = %{fixture(:chat, size) | layers: layers}
      {scene, _} = Projector.project(state)
      assert scene.size == state.size
      assert {:error, :capacity_exceeded} = Paint.build(scene, %Options{})
    end
  end

  test "Markdown scroll height and windows count rendered rows with complete fence context" do
    alias SwarmCodeCLI.UI.ScrollMetrics
    state = fixture(:chat, {80, 24})
    item = %{state.read_model.transcript["002"] | text: "```\na\n```\nb\nc\nd\ne\nf\ng\nh"}

    state = %{
      state
      | read_model: %{
          state.read_model
          | transcript: %{item.id => item},
            order: %{workspace: [item.id]}
        },
        scrolls:
          Map.put(state.scrolls, :main, %{
            state.scrolls.main
            | follow?: false,
              anchor: {item.id, 0, :top}
          })
    }

    assert ScrollMetrics.height(state, :main, item.id) == 8
    {scene, _, plan} = paint(state)
    main = Enum.find(scene.regions, &(&1.role == :main))
    list = Enum.find(main.blocks, &is_struct(&1, Block.VirtualList))
    assert {:ok, 8} = Metrics.height(list, main.rect.width)
    chrome = Enum.take_while(main.blocks, &(not is_struct(&1, Block.VirtualList)))
    assert {:ok, offset} = Metrics.height(chrome, main.rect.width)

    for {line, index} <- Enum.with_index(~w(a b c d e f g h)) do
      assert String.trim(row(plan, main.rect.y + offset + index, main.rect.x, main.rect.width)) ==
               line
    end

    long = %{item | text: "```\n" <> Enum.map_join(1..250, "\n", &"code #{&1}") <> "\n```"}
    state = put_in(state.read_model.transcript[item.id], long)
    state = put_in(state.scrolls.main.anchor, {item.id, 240, :top})
    assert ScrollMetrics.height(state, :main, item.id) == 250
    {scene, _, plan} = paint(state)
    main = Enum.find(scene.regions, &(&1.role == :main))
    assert screen(plan) =~ "code 241"
    assert screen(plan) =~ "code 248"
    refute screen(plan) =~ "code 240"

    assert length(Enum.find(main.blocks, &is_struct(&1, Block.VirtualList)).items) <=
             main.rect.height
  end

  test "scroll anchors and painted transcript share word-aware rows" do
    alias SwarmCodeCLI.UI.{Prose, SafeText, ScrollMetrics}

    for policy <- [:narrow, :wide] do
      state = fixture(:swarm, {160, 50}, policy)

      item = %{
        state.read_model.transcript["002"]
        | text: String.duplicate("Independent permissions stay exact · Unicode 界. ", 30)
      }

      state = %{
        state
        | read_model: %{
            state.read_model
            | transcript: %{item.id => item},
              order: %{workspace: [item.id]}
          },
          scrolls:
            Map.put(state.scrolls, :main, %{
              state.scrolls.main
              | follow?: false,
                anchor: {item.id, 2, :top}
            })
      }

      {scene, _, plan} = paint(state)
      main = Enum.find(scene.regions, &(&1.role == :main))
      lines = Prose.wrap(item.text, main.rect.width, policy)
      assert ScrollMetrics.height(state, :main, item.id) == length(lines)
      list = Enum.find(main.blocks, &is_struct(&1, Block.VirtualList))

      expected =
        lines
        |> Enum.drop(2)
        |> Enum.take(Workspace.content_height(state, main.rect, scene.layout_class))

      assert Enum.map_join(hd(list.items).spans, &SafeText.value(&1.text)) ==
               Enum.join(expected, "\n")

      chrome = Enum.take_while(main.blocks, &(not is_struct(&1, Block.VirtualList)))
      assert {:ok, offset} = Metrics.height(chrome, main.rect.width, %Options{}, 200, policy)

      for {line, index} <- Enum.with_index(expected) do
        assert String.trim_trailing(
                 row(plan, main.rect.y + offset + index, main.rect.x, main.rect.width)
               ) == String.trim_trailing(line)
      end
    end
  end

  test "admitted Markdown beyond inline parser capacity falls back to literal rows" do
    alias SwarmCodeCLI.UI.ScrollMetrics
    state = fixture(:chat, {80, 24})
    item = %{state.read_model.transcript["002"] | text: String.duplicate("*", 65_000)}

    state = %{
      state
      | read_model: %{
          state.read_model
          | transcript: %{item.id => item},
            order: %{workspace: [item.id]}
        },
        scrolls:
          Map.put(state.scrolls, :main, %{
            state.scrolls.main
            | follow?: false,
              anchor: {item.id, 0, :top}
          })
    }

    assert ScrollMetrics.height(state, :main, item.id) == 813
    {_, _, plan} = paint(state)
    assert screen(plan) =~ String.duplicate("*", 80)
  end

  test "Markdown style survives wrapping and an anchor inside an open fence" do
    alias SwarmCodeCLI.UI.{SafeText, Transcript}
    state = fixture(:chat, {80, 24})
    item = %{state.read_model.transcript["002"] | text: "**alpha beta gamma delta**"}
    {block, 4} = Transcript.window(item, :chat, 8, state.capabilities, 0, 10, false)
    spans = Enum.reject(block.spans, &(SafeText.value(&1.text) == "\n"))
    assert Enum.all?(spans, &(:bold in &1.style.modifiers))
    assert Enum.map_join(spans, &SafeText.value(&1.text)) == "alpha beta gamma delta"
    item = %{item | text: "```\na\nb\nc\n```\noutside"}
    {block, 2} = Transcript.window(item, :chat, 8, state.capabilities, 1, 2, false)
    assert Enum.map_join(block.spans, &SafeText.value(&1.text)) == "b\nc"
    expected = SwarmCodeCLI.UI.Theme.style(:code, state.capabilities).foreground

    for span <- block.spans, SafeText.value(span.text) != "\n" do
      assert span.style.foreground.value == expected.value
      assert span.style.role == :plain
      assert span.style.prefix == nil
    end
  end

  test "already escaped transcript units retain the escaped byte budget" do
    alias SwarmCodeCLI.UI.{SafeText, Transcript}
    state = fixture(:chat, {80, 24})
    source = "a" <> String.duplicate("\u0301", 32_750) <> String.duplicate("\0", 25)
    assert {:ok, safe} = SafeText.external(source, SafeText.Limits.content())
    assert byte_size(SafeText.value(safe)) > SafeText.Limits.content().input_bytes
    item = %{state.read_model.transcript["002"] | text: source}
    {block, _} = Transcript.window(item, :chat, 500, state.capabilities, 0, 2, false)
    assert Enum.map_join(block.spans, &SafeText.value(&1.text)) == SafeText.value(safe)
  end

  test "follow selects the newest rendered rows across transcript items" do
    state = fixture(:chat, {80, 24})

    transcript =
      Map.new(state.read_model.transcript, fn {id, item} ->
        {id, %{item | text: Enum.map_join(1..20, "\n", &"#{id} row #{&1}")}}
      end)

    state = %{state | read_model: %{state.read_model | transcript: transcript}}
    {scene, _, plan} = paint(state)
    assert screen(plan) =~ "002 row 20"
    refute screen(plan) =~ "001 row"
    main = Enum.find(scene.regions, &(&1.role == :main))
    list = Enum.find(main.blocks, &is_struct(&1, Block.VirtualList))
    assert list.first_index == 1
    assert list.total_count == 2
  end

  test "Markdown transformation errors fall back to admitted literal source without crashing projection" do
    alias SwarmCodeCLI.UI.{SafeText, ScrollMetrics, Transcript}
    state = fixture(:chat, {80, 24})

    for source <- ["**́**", "**́**x", "- a" <> String.duplicate("**́**", 4095)] do
      assert {:ok, safe} = SafeText.external(source, SafeText.Limits.content())
      item = %{state.read_model.transcript["002"] | text: source}

      state = %{
        state
        | read_model: %{
            state.read_model
            | transcript: %{item.id => item},
              order: %{workspace: [item.id]}
          },
          scrolls:
            Map.put(state.scrolls, :main, %{
              state.scrolls.main
              | follow?: false,
                anchor: {item.id, 0, :top}
            })
      }

      rows = Transcript.rows(item, :chat, 80, state.capabilities) |> Enum.to_list()

      assert Enum.map_join(rows, &Enum.map_join(&1.units, fn unit -> unit.text end)) ==
               SafeText.value(safe)

      assert ScrollMetrics.height(state, :main, item.id) == length(rows)
      {_, _, plan} = paint(state)
      assert screen(plan) =~ "**́**"
    end
  end
end
