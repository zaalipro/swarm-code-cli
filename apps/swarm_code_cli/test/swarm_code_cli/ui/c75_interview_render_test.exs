defmodule SwarmCodeCLI.UI.C75InterviewRenderTest do
  # pass 75 (task 253a): the three picked frames are the acceptance: QA1 and
  # QA2 at 176x45 and QA3 at 100x30, row for row, with their roles, size and
  # the ghosted backdrop.
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{
    Editor,
    FieldEditors,
    Paint,
    Pass73Helpers,
    Projector,
    Reducer,
    SafeText,
    Theme
  }

  alias SwarmCodeCLI.UI.Projector.Support
  alias SwarmCodeCLI.UI.DataSource.DTO
  alias SwarmCodeCLI.UI.Paint.{Options, Plan}

  @now 1_000_000_000_000
  @run "run-qa"
  @lead "lead-qa"
  @ask "ask-qa"

  # Task 208's option strings.
  @q1 [
    {"csv", "CSV", "One row per ticket; opens in Excel and Sheets."},
    {"json", "JSON", "Nested comments and tags; the shape a re-import reads."},
    {"both", "CSV and JSON", "Two buttons in the toolbar; doubles the export tests."},
    {"xlsx", "XLSX", "A native spreadsheet; adds the elixlsx dependency."}
  ]
  @q2 [
    {"status", "Status and priority", "Always there and cheap, straight from tickets."},
    {"assignee", "Assignee", "Joins users; empty for 6% of tickets."},
    {"email", "Customer email", "Personal data: the export then needs the admin role."},
    {"comments", "Comments", "From ticket_comments; adds ~30 MB to a full export."}
  ]
  @q3 [
    {"download", "Download in the browser", ""},
    {"email_link", "Email a link", ""},
    {"s3", "Upload to S3", ""},
    {"api", "API endpoint", ""}
  ]

  # The frames of Design › Frames › Interview area, the note's columns only.
  @qa1 [
    "╭─ ⋔ Lead asks you ───────────────────── swarm · add ticket export · asked 0:42 ago ─╮",
    "│                                                                                    │",
    "│    \"One decision before I split the work: the rest follows from the scouts.\"       │",
    "│                                                                                    │",
    "│    Which format should the ticket export produce?                        pick one  │",
    "│                                                                                    │",
    "│    1  CSV                                                                          │",
    "│       One row per ticket; opens in Excel and Sheets.                               │",
    "│  ▌ 2  JSON                                                                         │",
    "│  ▌    Nested comments and tags; the shape a re-import reads.                       │",
    "│    3  CSV and JSON                                                                 │",
    "│       Two buttons in the toolbar; doubles the export tests.                        │",
    "│    4  XLSX                                                                         │",
    "│       A native spreadsheet; adds the elixlsx dependency.                           │",
    "│                                                                                    │",
    "│    ›  Something else, in your own words…                              Tab to type  │",
    "│                                                                                    │",
    "│    You will send  JSON                                                             │",
    "│                                                                                    │",
    "│    1-4 pick   ↑↓ move                                      Enter send to the Lead  │",
    "╰─ Esc later: the Lead keeps waiting, 29 min left ────────────────────── ^N reopens ─╯"
  ]

  @qa2 [
    "╭─ ⋔ Lead asks you 3 questions ───────── swarm · add ticket export · asked 1:10 ago ─╮",
    "│                                                                                    │",
    "│    \"Before I split the work I need three decisions from you.\"                      │",
    "│                                                                                    │",
    "│    ✓ Format   ›   ● Fields   ›   ○ Delivery                                2 of 3  │",
    "│                                                                                    │",
    "│    Which fields should each exported row carry?                          pick any  │",
    "│                                                                                    │",
    "│    1  [✓] Status and priority                                                      │",
    "│           Always there and cheap, straight from tickets.                           │",
    "│    2  [✓] Assignee                                                                 │",
    "│           Joins users; empty for 6% of tickets.                                    │",
    "│    3  [ ] Customer email                                                           │",
    "│           Personal data: the export then needs the admin role.                     │",
    "│    4  [ ] Comments                                                                 │",
    "│           From ticket_comments; adds ~30 MB to a full export.                      │",
    "│                                                                                    │",
    "│  ▌ ›  also the SLA breach flag, if tickets has one█          Tab back to the list  │",
    "│                                                                                    │",
    "│    You will send                                                                   │",
    "│    ✓ Format    CSV                                                                 │",
    "│    ● Fields    Status and priority, Assignee + \"also the SLA breach flag, if tic…  │",
    "│    ○ Delivery  not answered yet                                                    │",
    "│                                                                                    │",
    "│    1-4 tick   Space tick   ↑↓ move   ←→ question             Enter next: Delivery  │",
    "╰─ Esc later: the Lead keeps waiting, 28 min left ────────────────────── ^N reopens ─╯"
  ]

  @qa3 [
    "╭─ ⋔ Lead asks you ─────────────────── swarm · add ticket export · asked 0:42 ago ─╮",
    "│                                                                                  │",
    "│    \"One decision before I split the work: the rest follows from the scouts.\"     │",
    "│                                                                                  │",
    "│    Which format should the ticket export produce?                      pick one  │",
    "│                                                                                  │",
    "│    1  CSV                                                                        │",
    "│       One row per ticket; opens in Excel and Sheets.                             │",
    "│  ▌ 2  JSON                                                                       │",
    "│  ▌    Nested comments and tags; the shape a re-import reads.                     │",
    "│    3  CSV and JSON                                                               │",
    "│       Two buttons in the toolbar; doubles the export tests.                      │",
    "│    4  XLSX                                                                       │",
    "│       A native spreadsheet; adds the elixlsx dependency.                         │",
    "│                                                                                  │",
    "│    ›  Something else, in your own words…                            Tab to type  │",
    "│                                                                                  │",
    "│    You will send  JSON                                                           │",
    "│                                                                                  │",
    "│    1-4 pick   ↑↓ move                                    Enter send to the Lead  │",
    "╰─ Esc later: the Lead keeps waiting, 29 min left ──────────────────── ^N reopens ─╯"
  ]

  defp question(id, index, header, prompt, multiple, total, options, requested, deadline) do
    %DTO.PendingInteraction{
      id: id,
      kind: :question,
      state: :pending,
      run_id: @run,
      node_id: @ask,
      conversation_id: "c",
      expected_revision: 3,
      created_at: 5,
      deadline: deadline,
      allowed_actions: [:answer_question],
      question: %DTO.Question{
        prompt: prompt,
        index: index,
        header: header,
        total: total,
        multiple: multiple,
        agent_id: @lead,
        requested_at: requested,
        options:
          for {id, label, description} <- options do
            %DTO.QuestionOption{id: id, label: label, description: description}
          end
      }
    }
  end

  defp q1(total, requested, deadline),
    do:
      question(
        "q1",
        0,
        "Format",
        "Which format should the ticket export produce?",
        false,
        total,
        @q1,
        requested,
        deadline
      )

  # A swarm run whose Lead said `why` just before its ask_user op, and the
  # ask's rows; truecolor at the rich glyph tier, as the frames are drawn.
  defp fixture(columns, rows, why, questions) do
    run = Pass73Helpers.run(@run, :waiting_question, kind: :swarm, title: "add ticket export")
    state = Pass73Helpers.ready([run], columns: columns, rows: rows)

    caps = %{state.capabilities | color_mode: :truecolor, glyph_tier: :rich}
    lead = %DTO.AgentSummary{id: @lead, run_id: @run, name: "Lead", role: :lead}

    said = %DTO.TranscriptItem{
      id: "t10",
      run_id: @run,
      conversation_id: "c",
      node_id: @lead,
      role: :assistant,
      kind: :text,
      created_sequence: 10,
      text: "Scouts are back. " <> why
    }

    op = %DTO.TranscriptItem{
      id: "t11",
      run_id: @run,
      conversation_id: "c",
      node_id: @ask,
      role: :assistant,
      kind: :tool,
      created_sequence: 11,
      text: ""
    }

    model = state.read_model

    state = %{
      state
      | now: @now,
        capabilities: caps,
        read_model: %{
          model
          | agents: Map.put(model.agents, @lead, lead),
            transcript: model.transcript |> Map.put("t10", said) |> Map.put("t11", op),
            interactions: Map.new(questions, &{&1.id, &1})
        }
    }

    update!(state, {:open_interaction, @ask})
  end

  defp update!(state, action), do: elem(Reducer.update(state, action), 0)

  defp qa1(columns, rows) do
    columns
    |> fixture(rows, "One decision before I split the work: the rest follows from the scouts.", [
      q1(1, @now - 42_000, @now + 29 * 60_000 + 30_000)
    ])
    |> update!({:interview, {:pick, @ask, "json"}})
  end

  defp qa2 do
    requested = @now - 70_000
    deadline = @now + 28 * 60_000 + 30_000

    state =
      fixture(176, 45, "Before I split the work I need three decisions from you.", [
        q1(3, requested, deadline),
        question(
          "q2",
          1,
          "Fields",
          "Which fields should each exported row carry?",
          true,
          3,
          @q2,
          requested,
          deadline
        ),
        question(
          "q3",
          2,
          "Delivery",
          "How should people get the export?",
          false,
          3,
          @q3,
          requested,
          deadline
        )
      ])
      |> update!({:interview, {:pick, @ask, "csv"}})
      |> update!({:interview, {:confirm, @ask}})
      |> update!({:interview, {:toggle, @ask, "status"}})
      |> update!({:interview, {:toggle, @ask, "assignee"}})
      |> update!({:interview, {:toggle_other, @ask}})

    key = {:question_other, "q2", 3}

    {:ok, editor} =
      Editor.apply(
        FieldEditors.fetch(state.field_editors, key),
        {:insert, "also the SLA breach flag, if tickets has one"}
      )

    %{state | field_editors: FieldEditors.put(state.field_editors, key, editor)}
  end

  defp paint(state) do
    {scene, _} = Projector.project(state)

    {:ok, plan} =
      Paint.build(scene, %Options{
        color_mode: state.capabilities.color_mode,
        ascii?: state.capabilities.ascii?
      })

    {scene, plan}
  end

  # pass73_qa2_test.exs `screen/1`, on a painted plan.
  defp screen(plan) do
    for y <- 0..(plan.size.rows - 1) do
      for x <- 0..(plan.size.columns - 1), reduce: "" do
        acc ->
          case Plan.cell(plan, x, y) do
            {:glyph, glyph, _, _} -> acc <> glyph
            _ -> acc
          end
      end
    end
  end

  defp note_rows(scene, plan) do
    rect = scene.overlay.rect

    plan
    |> screen()
    |> Enum.slice(rect.y, rect.height)
    |> Enum.map(&(&1 |> String.slice(rect.x, rect.width) |> String.trim_trailing()))
  end

  defp cell_style(plan, x, y) do
    {:glyph, _, _, i} = Plan.cell(plan, x, y)
    elem(plan.palette, i)
  end

  # The x of the first cell of `text` on row `y` at or after `from`.
  defp column(plan, y, text, from) do
    row = Enum.at(screen(plan), y)
    [before | _] = String.split(String.slice(row, from..-1//1), text, parts: 2)
    from + String.length(before)
  end

  defp role?(plan, state, {x, y}, role, bold? \\ false) do
    entry = cell_style(plan, x, y)

    entry.foreground == Theme.style(role, state.capabilities).foreground.value and
      :bold in entry.modifiers == bold?
  end

  test "QA1 at 176x45: 86 wide at x 21, 21 rows, row for row" do
    state = qa1(176, 45)
    {scene, plan} = paint(state)
    rect = scene.overlay.rect

    assert {rect.x, rect.width, rect.height} == {21, 86, 21}
    assert note_rows(scene, plan) == @qa1
  end

  # 409 (sandbox): a swarm Lead's words before its ask are its own `llm` op
  # (kind `:thinking`, role `:tool`, `agent_id` = the Lead), not a message.
  test "QA1: the why row reads the asker's own model turn before the ask (409)" do
    state = qa1(176, 45)

    turn = %DTO.TranscriptItem{
      id: "t10",
      run_id: @run,
      conversation_id: "c",
      node_id: "llm-op",
      agent_id: @lead,
      role: :tool,
      kind: :thinking,
      created_sequence: 10,
      text: "One decision before I split the work: the rest follows from the scouts."
    }

    other = %{turn | id: "t9", agent_id: "someone-else", created_sequence: 9, text: "Not me."}
    model = state.read_model
    transcript = model.transcript |> Map.put("t10", turn) |> Map.put("t9", other)
    state = %{state | read_model: %{model | transcript: transcript}}

    {scene, plan} = paint(state)
    assert note_rows(scene, plan) == @qa1

    alone = %{state | read_model: %{model | transcript: Map.delete(transcript, "t10")}}
    {scene, plan} = paint(alone)
    refute Enum.any?(note_rows(scene, plan), &(&1 =~ "Not me."))
  end

  test "QA1 roles: the name, the rail, the descriptions, the frame and the ghosted chat" do
    state = qa1(176, 45)
    {scene, plan} = paint(state)
    %{x: x, y: y} = scene.overlay.rect

    name = column(plan, y, "⋔ Lead", x)
    assert role?(plan, state, {name, y}, :run_swarm, true)
    assert role?(plan, state, {name + 2, y}, :run_swarm, true)
    assert role?(plan, state, {column(plan, y, "asks you", x), y}, :text_primary)

    assert role?(plan, state, {x + 3, y + 8}, :accent)
    assert Enum.at(screen(plan), y + 8) |> String.slice(x + 3, 1) == "▌"
    assert role?(plan, state, {x + 8, y + 9}, :text_primary)
    assert role?(plan, state, {x + 8, y + 7}, :text_muted)

    for {cx, cy} <- [{x, y}, {x + 85, y}, {x, y + 20}, {x + 85, y + 20}, {x, y + 5}] do
      assert role?(plan, state, {cx, cy}, :text_faint)
    end

    # A chat cell behind the note: ghosted, no modifiers.
    {gx, gy} =
      Enum.find_value(0..(plan.size.rows - 1), fn row_y ->
        row = Enum.at(screen(plan), row_y)

        Enum.find_value(0..(x - 2), fn col ->
          if String.at(row, col) not in [nil, " "], do: {col, row_y}
        end)
      end)

    ghost = cell_style(plan, gx, gy)
    assert ghost.foreground == Theme.style(:text_ghost, state.capabilities).foreground.value
    assert ghost.modifiers == []
  end

  test "QA2 at 176x45: step 2 of 3, ticks, the other text and the ledger" do
    state = qa2()
    {scene, plan} = paint(state)
    rect = scene.overlay.rect
    %{x: x, y: y} = rect

    assert {rect.x, rect.width, rect.height} == {21, 86, 26}

    # The frame draws the "other" caret as `█`; the note draws the CLI's one
    # caret glyph (`Support.glyph(:caret, state)`, task 243b step 4).
    caret = SafeText.value(Support.glyph(:caret, state))
    assert note_rows(scene, plan) == Enum.map(@qa2, &String.replace(&1, "█", caret))

    # Ledger headers are text_muted and never bold, the current row's too.
    for dy <- 20..22 do
      assert role?(plan, state, {x + 7, y + dy}, :text_muted)
    end

    assert role?(plan, state, {column(plan, y + 22, "not answered yet", x), y + 22}, :text_faint)
  end

  test "QA3 at 100x30: 84 wide at x 8, every block kept" do
    state = qa1(100, 30)
    {scene, plan} = paint(state)
    rect = scene.overlay.rect

    assert {rect.x, rect.width, rect.height} == {8, 84, 21}
    assert note_rows(scene, plan) == @qa3
  end
end
