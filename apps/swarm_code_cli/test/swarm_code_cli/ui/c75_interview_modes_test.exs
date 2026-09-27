defmodule SwarmCodeCLI.UI.C75InterviewModesTest do
  # pass 75 (task 253b): the note degrades by rule, not by accident: short
  # screens drop blanks before content, narrow screens drop the backdrop,
  # ASCII keeps every meaning, and every control has exactly one target.
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{
    Editor,
    FieldEditors,
    Paint,
    Pass73Helpers,
    Projector,
    Question,
    Reducer,
    Theme
  }

  alias SwarmCodeCLI.UI.Projector.Interview
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

  defp cell_style(plan, x, y) do
    {:glyph, _, _, i} = Plan.cell(plan, x, y)
    elem(plan.palette, i)
  end

  defp overlay_row(scene, plan, dy) do
    rect = scene.overlay.rect
    plan |> screen() |> Enum.at(rect.y + dy) |> String.slice(rect.x, rect.width)
  end

  test "short screens drop the blank rows bottom-most first, then the why row" do
    state = qa1(176, 45)
    ask = Question.ask(state, @ask)
    interview = Question.interview(state, @ask)
    rows = Interview.rows(state, :wide, ask, interview, 78)
    tags = Enum.map(rows, &elem(&1, 0))

    assert length(rows) == 19
    assert Enum.count(tags, &(&1 == :blank)) == 6
    assert hd(tags) == :blank

    {kept, 0} = Interview.fit(rows, 14, {:option, "json"})
    kept_tags = Enum.map(kept, &elem(&1, 0))
    assert length(kept) == 14
    assert Enum.take(kept_tags, 2) == [:blank, :why]
    assert Enum.count(kept_tags, &(&1 == :blank)) == 1

    {kept, _scroll} = Interview.fit(rows, 12, {:option, "json"})
    kept_tags = Enum.map(kept, &elem(&1, 0))
    assert length(kept) == 12
    refute :blank in kept_tags
    refute :why in kept_tags
    assert {:option, "json"} in kept_tags
  end

  test "narrow: the note fills the screen, with no air and no ghosted backdrop" do
    state = qa1(80, 24)
    {scene, plan} = paint(state)
    note = scene.overlay

    assert scene.layout_class == :narrow
    assert {note.rect.x, note.rect.y, note.rect.width, note.rect.height} == {0, 0, 80, 24}
    assert note.air == false
    assert note.backdrop == :plain
    assert plan |> screen() |> hd() =~ "Lead asks you"
  end

  test "ASCII and monochrome keep every meaning" do
    ascii = fn state ->
      %{state | capabilities: %{state.capabilities | ascii?: true, color_mode: :monochrome}}
    end

    state = ascii.(qa2())
    {scene, plan} = paint(state)
    rows = Enum.map(0..(scene.overlay.rect.height - 1), &overlay_row(scene, plan, &1))
    text = Enum.join(rows, "\n")

    assert String.starts_with?(hd(rows), "+-")
    assert String.ends_with?(hd(rows), "-+")
    assert Enum.all?(Enum.slice(rows, 1..-2//1), &String.starts_with?(&1, "|"))
    refute text =~ ~r/[╭╮╰╯│─▌✓●○]/u

    assert text =~ "[v] Status and priority"
    assert text =~ "[ ] Customer email"
    assert text =~ "v Format   >   * Fields   >   o Delivery"
    assert Enum.any?(rows, &(&1 =~ ~r/^\|  \| >  also the SLA/))

    state = ascii.(qa1(176, 45))
    {scene, plan} = paint(state)
    rows = Enum.map(0..(scene.overlay.rect.height - 1), &overlay_row(scene, plan, &1))
    assert Enum.any?(rows, &(&1 =~ ~r/^\|  \| 2  FOCUS > JSON/))
    assert length(String.split(Enum.join(rows, "\n"), "FOCUS >")) == 2
  end

  test "the deadline words: minutes, a warning under five, no clock, a legacy daemon" do
    deadline = @now + 29 * 60_000 + 30_000
    state = qa1(176, 45)
    bottom = fn state -> overlay_row(elem(paint(state), 0), elem(paint(state), 1), 20) end

    assert bottom.(state) =~ "Esc later: the Lead keeps waiting, 29 min left"

    late = %{state | now: deadline - 4 * 60_000}
    {scene, plan} = paint(late)
    rect = scene.overlay.rect
    assert overlay_row(scene, plan, 20) =~ "Esc later: the Lead keeps waiting, 4 min left"
    x = rect.x + 3 + String.length("Esc ")
    warning = Theme.style(:warning, late.capabilities).foreground.value
    assert cell_style(plan, x, rect.y + 20).foreground == warning

    no_clock =
      update_in(state.read_model.interactions["q1"], &%{&1 | deadline: 0})

    assert bottom.(no_clock) =~ "later: the Lead waits until you answer or stop"

    legacy =
      update_in(no_clock.read_model.interactions["q1"], fn row ->
        %{row | question: %{row.question | total: 0}}
      end)

    assert bottom.(legacy) =~ "later: the Lead keeps waiting"
    refute bottom.(legacy) =~ "min left"
  end

  test "every control has one target, and none lies outside the note" do
    state = qa2()
    {scene, table} = Projector.project(state)

    {:ok, plan} =
      Paint.build(scene, %Options{
        color_mode: state.capabilities.color_mode,
        ascii?: state.capabilities.ascii?
      })

    rect = scene.overlay.rect
    targets = for {id, _rects} <- plan.actions, do: Map.fetch!(table, id)

    options = for {id, _, _} <- @q2, do: {:local, {:interview, {:toggle, @ask, id}}}
    steps = for i <- 0..2, do: {:local, {:interview, {:goto, @ask, i}}}
    other = {:local, {:interview, {:toggle_other, @ask}}}
    confirm = {:local, {:interview, {:confirm, @ask}}}

    assert Enum.sort(targets) == Enum.sort(options ++ steps ++ [other, confirm])

    for {_id, rects} <- plan.actions, r <- rects do
      assert r.x >= rect.x and r.x + r.width <= rect.x + rect.width
      assert r.y >= rect.y and r.y + r.height <= rect.y + rect.height
    end
  end
end
