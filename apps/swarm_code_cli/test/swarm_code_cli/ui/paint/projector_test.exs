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
    ReadModel,
    Size,
    State,
    Width
  }

  alias SwarmCodeCLI.UI.Paint.{Metrics, Options, Plan}
  alias SwarmCodeCLI.UI.Scene.Block
  alias SwarmCodeCLI.UI.Projector.Workspace
  alias SwarmCodeCLI.UI.Projector.Workspace.Turns
  alias SwarmCodeCLI.UI.DataSource.DTO.{PendingInteraction, Question, QuestionOption}
  alias SwarmCodeCLI.UI.DataSource.DTO.WorkspaceSnapshot

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
    # Every painted action is in the table, and every action that is not
    # painted is one the keys reach without a drawn control (the composer-first
    # keyboard, ux M2): the run's controls, the plan gate, the approval's
    # decisions, the full-text openers. The palette lists those too.
    painted = MapSet.new(Map.keys(plan.actions))
    projected = MapSet.new(Map.keys(table))
    assert MapSet.subset?(painted, projected)

    unpainted = MapSet.difference(projected, painted)

    assert MapSet.subset?(unpainted, keyboard_ids(state, scene)),
           "projected actions neither painted nor on the keys: #{inspect(unpainted)}"

    assert Enum.all?(plan.actions, fn {_, rects} -> rects != [] end)
    {scene, table, plan}
  end

  defp keyboard_ids(state, scene) do
    if scene.overlay do
      MapSet.new()
    else
      class = Layout.calculate(state.size, state.preferences).class

      {_, keyboard} =
        SwarmCodeCLI.UI.Projector.Support.finalize(
          %{keyboard: Workspace.keyboard_actions(state, class)},
          state.revision
        )

      MapSet.new(Map.keys(keyboard))
    end
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

        for fact <- ["NO USER DATA", "Build"] do
          assert pixels =~ fact, "#{kind} #{inspect(size)} is missing #{fact}"
        end

        refute pixels =~ "Target: Main"
        refute pixels =~ "Validation: none"
        refute pixels =~ "Focus:"

        # The banner leads the title row and the mode leads the status row.
        assert row(plan, 0) =~ "NO USER DATA"
        assert String.starts_with?(row(plan, plan.size.rows - 1), " Build")

        if scene.layout_class == :compressed_small do
          refute Enum.any?(Map.values(table), &match?({:intent, _}, &1))
          assert {:local, {:open_layer, :help}} in Map.values(table)
        end
      end
    end
  end

  test "empty conversation paints an actionable welcome state and visible composer" do
    state = fixture(:chat, {120, 40})

    workspace = %WorkspaceSnapshot{
      mode: :build,
      chat_model: "deepseek-v4-pro",
      conversation_id: "fixture-conversation",
      transcript: nil,
      state: :idle
    }

    empty = %{
      state
      | destination: {:conversation, "fixture-conversation"},
        read_model: %ReadModel{snapshots: %{workspace: workspace}},
        focus: "composer"
    }

    {scene, _table, plan} = paint(empty)
    pixels = screen(plan)
    main = Enum.find(scene.regions, &(&1.role == :main))
    composer = Enum.find(scene.regions, &(&1.role == :composer))
    title = Enum.find(scene.regions, &(&1.role == :title))

    assert pixels =~ "Ready to build"
    assert pixels =~ "Ask for a change"
    assert pixels =~ "Type a message"
    assert pixels =~ "/ for commands"
    # The navigator is gone: it no longer reports "No runs yet" from a dock, and
    # the title row carries the way into the runs instead.
    refute Enum.any?(scene.regions, &(&1.role == :navigator))
    refute pixels =~ "No runs yet"
    assert pixels =~ "Ctrl-R runs"
    assert composer.rect.height >= 1
    assert main.rect.height > 0

    # Nothing is docked on the left, so main's band is the whole 120-column
    # terminal and main takes all of it. The tab row spans the terminal too.
    assert main.rect.x == 0
    assert main.rect.width == 120
    assert main.rect.x == div(120 - main.rect.width, 2)

    docked =
      for region <- scene.regions,
          region.role not in [:title, :tabline, :status],
          region.rect.x < main.rect.x,
          do: {region.role, region.rect}

    assert docked == [], "a pane is docked to the left of main: #{inspect(docked)}"
    assert title.rect == %SwarmCodeCLI.UI.Scene.Rect{x: 0, y: 0, width: 120, height: 1}
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
      # +3 accounts for the rail (▐ or its ASCII twin) and the two cells after it
      assert plan.cursor.x == composer.rect.x + 3 + Width.cells(prefix, policy)
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
      # In colour the focus is the hover surface, never words.
      assert row(plan, focused.y, focused.x, focused.width) =~ "Cancel"
      refute screen(plan) =~ "FOCUS >"
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
      assert height == max(0, main.rect.height - rows)

      # The transcript fills exactly the rows left under the chrome.
      list = Enum.find(main.blocks, &is_struct(&1, Block.VirtualList))
      assert Metrics.height(list, main.rect.width, options, 200, policy) == {:ok, height}

      assert Enum.any?(main.rect.y..(main.rect.y + main.rect.height - 1), fn y ->
               row(plan, y, main.rect.x, main.rect.width) =~ "transcript line"
             end) == height > 1

      # The notice is a toast and the connection a fact, both on the status row.
      status = row(plan, plan.size.rows - 1)
      if notice, do: assert(status =~ "Input rejected")
      if is_nil(notice), do: assert(status =~ "reconnecting")
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
      assert screen(plan) =~ run.title
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

      # What waits is counted on the status row and opened from the keys; main
      # spends no row on a deck of it.
      refute Enum.any?(main.blocks, &is_struct(&1, Block.ActionDeck))

      for kind <- [:question, :approval] do
        assert {:local, {:open_layer, {kind, Atom.to_string(kind)}}} in Map.values(table)
      end

      assert row(plan, plan.size.rows - 1) =~ "2 waiting"
      chrome = Enum.take_while(main.blocks, &(not is_struct(&1, Block.VirtualList)))
      assert {:ok, height} = Metrics.height(chrome, main.rect.width, %Options{}, 200, policy)

      # The approval card takes its rows from the bottom of main.
      %{growth: card} =
        SwarmCodeCLI.UI.Projector.ApprovalCard.layout(state, main.rect.width)

      assert card > 0

      assert Workspace.content_height(state, main.rect, scene.layout_class) ==
               max(0, main.rect.height - height - card)
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
      content_height = Workspace.content_height(state, main.rect, scene.layout_class)

      if kind == :chat,
        do: assert(actual_rows == content_height),
        else: assert(actual_rows <= content_height)
    end
  end

  test "run status appears once while retry and resume availability remain visible" do
    for status <- [:streaming, :failed, :interrupted, :superseded],
        color <- [:truecolor, :monochrome] do
      state = fixture(:chat, {80, 24}, :narrow, color)
      state = put_in(state.read_model.runs["fixture-run"].state, status)
      state = put_in(state.read_model.runs["fixture-run"].allowed_actions, [:retry, :resume])
      {scene, table, plan} = paint(state)
      main = Enum.find(scene.regions, &(&1.role == :main))

      pixels =
        Enum.map_join(
          main.rect.y..(main.rect.y + main.rect.height - 1),
          "\n",
          &row(plan, &1, main.rect.x, main.rect.width)
        )

      # The run is named once on its tab and once on the side panel's strip
      # (pass72 R17, row 1 under 120 columns); main never repeats it, and its
      # controls are on the keys, where the palette lists them.
      assert length(String.split(screen(plan), "Streaming conversation")) - 1 == 2
      refute pixels =~ "Streaming conversation"
      refute pixels =~ "RUNNING STREAMING"

      assert Enum.any?(Map.values(table), &match?({:intent, {:retry_run, "fixture-run", _}}, &1)) ==
               (status == :failed)

      assert {:intent, {:run_control, :resume, "fixture-run"}} in Map.values(table) ==
               (status == :interrupted)

      # A failed run says so, and says what to do next.
      assert pixels =~ "retry from the palette" == (status == :failed)
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

  test "nothing waiting says nothing, and a pending interaction is announced on the strip" do
    for activity_height <- [0, 1, 2] do
      state = fixture(:chat, {80, 24})
      state = %{state | preferences: %{state.preferences | activity_height: activity_height}}
      {_, _, plan} = paint(state)
      refute screen(plan) =~ "Waiting for you"
      refute row(plan, plan.size.rows - 1) =~ "waiting"

      item = %PendingInteraction{
        id: "pending",
        run_id: "fixture-run",
        node_id: "node",
        conversation_id: "fixture-conversation",
        allowed_actions: []
      }

      state = put_in(state.read_model.interactions[item.id], item)
      {_scene, _, plan} = paint(state)
      assert row(plan, plan.size.rows - 1) =~ "1 waiting"
      refute screen(plan) =~ "Waiting for you"
    end
  end

  # pass72: the side panel names every agent once, the lead first at the top
  # of its tree; its rows are a picture, not controls (P1), so the hint keys
  # and the agent overlay (owner O) reach an agent, not a click on its row.
  test "the side panel names every sub-agent once and the lead heads the tree" do
    for color <- [:truecolor, :monochrome], policy <- [:narrow, :wide] do
      state = fixture(:swarm, {160, 50}, policy, color)
      {scene, _table, plan} = paint(state)
      inspector = Enum.find(scene.regions, &(&1.role == :inspector))
      agents = Map.values(state.read_model.agents)

      rows =
        for y <- inspector.rect.y..(inspector.rect.y + inspector.rect.height - 1),
            do: row(plan, y, inspector.rect.x, inspector.rect.width)

      words = "(working|thinking|waiting|needs you|done|failed|stopped|queued|paused)"

      for agent <- agents, agent.role != :lead do
        name_row = Regex.compile!(" " <> Regex.escape(agent.name) <> " +" <> words)
        assert Enum.count(rows, &(&1 =~ name_row)) == 1, agent.name
      end

      lead_row = Enum.find_index(rows, &(&1 =~ ~r/ Lead +/))
      first_sub = Enum.find_index(rows, &(&1 =~ "scout-1"))
      assert lead_row && first_sub && lead_row < first_sub
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
    # Use 80x30 so all content + labels fit in the viewport
    state = fixture(:chat, {80, 30})
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

    # The first turn has no blank row: the header, the code card's language
    # chip, its line and its closing row (pass71 V2), then the seven prose lines.
    assert ScrollMetrics.height(state, :main, item.id) == 11
    {scene, _, plan} = paint(state)
    main = Enum.find(scene.regions, &(&1.role == :main))
    list = Enum.find(main.blocks, &is_struct(&1, Block.VirtualList))
    # The painted list must occupy EXACTLY the rows the scroll metric predicts. That equality is
    # what keeps anchors, follow and paging exact, so assert it rather than a bound.
    assert Metrics.height(list, main.rect.width) ==
             {:ok, ScrollMetrics.height(state, :main, item.id)}

    assert {:ok, 11} = Metrics.height(list, main.rect.width)
    chrome = Enum.take_while(main.blocks, &(not is_struct(&1, Block.VirtualList)))
    assert {:ok, offset} = Metrics.height(chrome, main.rect.width)

    # The header and the chip take two rows before the content.
    for {line, index} <- Enum.with_index(["a", "" | ~w(b c d e f g h)]) do
      assert String.trim(
               row(plan, main.rect.y + offset + 2 + index, main.rect.x, main.rect.width)
             ) ==
               line
    end

    long = %{item | text: "```\n" <> Enum.map_join(1..250, "\n", &"code #{&1}") <> "\n```"}
    state = put_in(state.read_model.transcript[item.id], long)
    state = put_in(state.scrolls.main.anchor, {item.id, 200, :top})
    assert ScrollMetrics.height(state, :main, item.id) == 253
    {scene, _, plan} = paint(state)
    main = Enum.find(scene.regions, &(&1.role == :main))
    assert screen(plan) =~ "code 199"
    assert screen(plan) =~ "code 206"
    refute screen(plan) =~ "code 198"

    # pass70 Q1: anchored inside the last screen, the view is drawn from the
    # end (the last row on the bottom edge), not over a blank page.
    state = put_in(state.scrolls.main.anchor, {item.id, 242, :top})
    {_scene, _, near_end} = paint(state)
    assert screen(near_end) =~ "code 250"
    assert screen(near_end) =~ "code 240"

    assert length(Enum.find(main.blocks, &is_struct(&1, Block.VirtualList)).items) <=
             main.rect.height
  end

  test "scroll anchors and painted transcript share word-aware rows" do
    alias SwarmCodeCLI.UI.{SafeText, ScrollMetrics}

    for policy <- [:narrow, :wide] do
      state = fixture(:swarm, {160, 50}, policy)

      item = %{
        state.read_model.transcript["002"]
        | text: String.duplicate("Independent permissions stay exact · Unicode 界. ", 200)
      }

      # No agents: a worker that has not started would be a queued line of
      # its own under the header.
      state = %{
        state
        | read_model: %{
            state.read_model
            | transcript: %{item.id => item},
              agents: %{},
              order: %{workspace: [item.id]}
          },
          scrolls:
            Map.put(state.scrolls, :main, %{
              state.scrolls.main
              | follow?: false,
                anchor: {item.id, 4, :top}
            })
      }

      {scene, _, plan} = paint(state)
      main = Enum.find(scene.regions, &(&1.role == :main))
      margin = Turns.body_column()

      lines =
        item.text
        |> String.trim()
        |> SwarmCodeCLI.UI.Projector.Markdown.rows(main.rect.width - margin - 1, policy)
        |> Enum.map(fn row -> Enum.map_join(row.segments, &elem(&1, 0)) end)

      # The first turn has no blank row: the header, then the prose.
      assert ScrollMetrics.height(state, :main, item.id) == length(lines) + 1
      list = Enum.find(main.blocks, &is_struct(&1, Block.VirtualList))

      # Anchor row 4 is the fourth prose line; every painted row starts at the
      # body column and carries exactly one wrapped line.
      expected =
        lines
        |> Enum.drop(3)
        |> Enum.take(Workspace.content_height(state, main.rect, scene.layout_class))

      assert Enum.map_join(hd(list.items).spans, &SafeText.value(&1.text)) ==
               Enum.map_join(expected, "\n", &(String.duplicate(" ", margin) <> &1))

      chrome = Enum.take_while(main.blocks, &(not is_struct(&1, Block.VirtualList)))
      assert {:ok, offset} = Metrics.height(chrome, main.rect.width, %Options{}, 200, policy)

      for {line, index} <- Enum.with_index(expected) do
        assert String.trim_trailing(
                 row(
                   plan,
                   main.rect.y + offset + index,
                   main.rect.x + margin,
                   main.rect.width - margin
                 )
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

    # The header, then 65 000 cells of literal text wrapped at the body column.
    inner = ScrollMetrics.viewport(state, :main).width - Turns.body_column() - 1
    assert ScrollMetrics.height(state, :main, item.id) == div(65_000 + inner - 1, inner) + 1
    {_, _, plan} = paint(state)
    assert screen(plan) =~ String.duplicate("*", inner)
  end

  test "Markdown style survives wrapping and an anchor inside an open fence" do
    alias SwarmCodeCLI.UI.{SafeText, Transcript}
    state = fixture(:chat, {80, 24})
    item = %{state.read_model.transcript["002"] | text: "**alpha beta gamma delta**"}
    # Label rows (blank + role) are included; skip them to check bold content
    {block, _row_count} = Transcript.window(item, :chat, 8, state.capabilities, 2, 10, false)
    spans = Enum.reject(block.spans, &(SafeText.value(&1.text) == "\n"))
    bold_spans = Enum.filter(spans, &(:bold in &1.style.modifiers))
    assert Enum.map_join(bold_spans, &SafeText.value(&1.text)) == "alpha beta gamma delta"
    item = %{item | text: "```\na\nb\nc\n```\noutside"}
    # Labels wrap at width 8; compute actual label+fence offset dynamically
    all_rows = Transcript.rows(item, :chat, 8, state.capabilities) |> Enum.to_list()

    a_index =
      Enum.find_index(all_rows, fn row ->
        Enum.map_join(row.units, & &1.text) == "a"
      end)

    {block, 2} = Transcript.window(item, :chat, 8, state.capabilities, a_index + 1, 2, false)
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
    # Skip label rows (offset 2) to get only content rows
    {block, _} = Transcript.window(item, :chat, 500, state.capabilities, 2, 2, false)
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
    alias SwarmCodeCLI.UI.{SafeText, ScrollMetrics}
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

      # A marker beside a combining mark is literal text: nothing is dropped
      # or split, and the painted rows are the rows the scroll metric counts.
      assert SafeText.value(safe) =~ "**́**"
      {scene, _, plan} = paint(state)
      assert screen(plan) =~ "**́**"
      refute screen(plan) =~ "COMBINING"
      main = Enum.find(scene.regions, &(&1.role == :main))
      list = Enum.find(main.blocks, &is_struct(&1, Block.VirtualList))

      if ScrollMetrics.height(state, :main, item.id) <= main.rect.height do
        assert Metrics.height(list, main.rect.width) ==
                 {:ok, ScrollMetrics.height(state, :main, item.id)}
      end
    end
  end
end
