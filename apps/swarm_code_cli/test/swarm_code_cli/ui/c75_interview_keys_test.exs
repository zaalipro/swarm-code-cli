defmodule SwarmCodeCLI.UI.C75InterviewKeysTest do
  # pass 75 (task 251): every key of Requirement 14 on the question note.
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers

  alias SwarmCodeCLI.UI.{Editor, FieldEditors, Input, Keymap, Paint, Projector, Question}
  alias SwarmCodeCLI.UI.DataSource.DTO
  alias SwarmCodeCLI.UI.Keymap.Bindings
  alias SwarmCodeCLI.UI.Paint.{Options, Plan}

  @node "n9"
  @lead "lead-1"

  # The ask of task 250: q0 single, q1 multi, q2 single, rows in hash order.
  defp row(id, index, opts \\ []) do
    {header, multiple, options} =
      case index do
        0 -> {"Format", false, ["CSV", "JSON", "Both", "XLSX"]}
        1 -> {"Fields", true, ["Status", "Assignee", "Email"]}
        2 -> {"Delivery", false, ["A file", "Mail"]}
      end

    %DTO.PendingInteraction{
      id: id,
      kind: :question,
      run_id: "r",
      node_id: @node,
      conversation_id: "c",
      expected_revision: 4,
      created_at: 5,
      allowed_actions: [:answer_question],
      question: %DTO.Question{
        prompt: header <> "?",
        index: index,
        header: header,
        total: Keyword.get(opts, :total, 3),
        multiple: multiple,
        agent_id: @lead,
        options:
          for {label, n} <- Enum.with_index(options, 1) do
            %DTO.QuestionOption{id: "o#{n}-#{index}", label: label}
          end
      }
    }
  end

  defp rows, do: [row("a-q2", 2), row("b-q0", 0), row("c-q1", 1)]

  defp opened(interactions, opts \\ []) do
    state =
      ready([run("r", :waiting_question, kind: :swarm, title: "add ticket export")],
        columns: 176,
        rows: 45,
        snapshot: %{interactions: interactions}
      )

    lead = %DTO.AgentSummary{id: @lead, run_id: "r", name: "Lead", role: :lead}
    state = put_in(state.read_model.agents[@lead], lead)
    if Keyword.get(opts, :grace, false), do: state, else: %{state | interaction_grace: nil}
  end

  defp key(code, mods \\ []), do: Input.key(code, mods)

  defp interview(state), do: Question.interview(state, @node)

  defp ticks(state, row_id), do: Map.get(state.selection, {:question, row_id}, [])

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

  # The note's keys row (the empty chat under it has its own "Enter send").
  defp keys_row(state), do: Enum.find(screen(state), &(&1 =~ " move" and &1 =~ "Enter"))

  test "single select: a digit picks, the pick outlives the focus, Space does nothing" do
    state = opened(rows())
    assert [{:question, @node}] = state.layers

    state = press!(state, letter("2"))
    assert interview(state).picks["b-q0"] == "o2-0"
    assert state.focus == "o2-0"

    state = press!(state, key(:down))
    assert state.focus == "o3-0"
    ask = Question.ask(state, @node)
    current = Question.current(ask, interview(state))
    assert Question.answer(state, ask, current) == %{option_ids: ["o2-0"], custom_text: ""}

    assert press!(state, letter(" ")) == state
  end

  test "multi select: digits and Space tick, Tab visits other and comes back, ←/→ step" do
    state = opened(rows()) |> press!(letter("2")) |> press!(key(:enter))
    assert interview(state).step == 1

    state = state |> press!(letter("1")) |> press!(letter("2"))
    assert ticks(state, "c-q1") == ["o1-1", "o2-1"]

    state = press!(state, key(:down)) |> press!(key(:up))
    assert state.focus == "o2-1"
    state = press!(state, letter(" "))
    assert ticks(state, "c-q1") == ["o1-1"]

    state = press!(state, key(:tab))
    assert state.focus == "other"
    state = type(state, "also")

    assert state.field_editors
           |> FieldEditors.fetch({:question_other, "c-q1", 4})
           |> Editor.text() == "also"

    # ← in "other" moves the caret, the step stays.
    moved = press!(state, key(:left))
    assert interview(moved).step == 1
    assert moved.focus == "other"

    assert moved.field_editors
           |> FieldEditors.fetch({:question_other, "c-q1", 4})
           |> Editor.cursor() == 3

    state = press!(state, key(:tab))
    assert state.focus == "o2-1"

    state = press!(state, key(:left))
    assert interview(state).step == 0
    state = press!(state, key(:right))
    assert interview(state).step == 1
  end

  test "the Enter words name what Enter does now" do
    one = opened([row("b-q0", 0, total: 1)])
    assert keys_row(one) =~ "Enter send to the Lead"

    state = opened(rows()) |> press!(letter("2")) |> press!(key(:enter))
    assert interview(state).step == 1
    assert keys_row(state) =~ "Enter next: Delivery"

    state = state |> press!(letter("1")) |> press!(key(:enter))
    assert interview(state).step == 2
    assert keys_row(state) =~ "Enter send 3 answers"
  end

  test "Esc sets the ask aside; ^N brings it back as it was" do
    state = opened(rows()) |> press!(letter("2")) |> press!(key(:enter))
    state = state |> press!(letter("1")) |> press!(key(:tab)) |> type("also")
    held = state

    state = press!(state, key(:escape))
    assert state.layers == []
    assert {@node, 4} in state.dismissed_interactions

    # The same revision arriving again does not reopen it.
    {state, _} = watch_ready(state, [run("r", :waiting_question)], %{interactions: rows()}, 1)
    assert state.layers == []

    chord = Bindings.fetch(:next_need_chord)
    [{letter, mods} | _] = chord.keys
    state = press!(state, Input.text_fragment(:press, letter, mods))
    assert [{:question, @node} | _] = state.layers
    assert interview(state).step == 1
    assert ticks(state, "c-q1") == ticks(held, "c-q1")

    assert state.field_editors
           |> FieldEditors.fetch({:question_other, "c-q1", 4})
           |> Editor.text() == "also"
  end

  test "PgDn keeps the focus; typing in the grace window goes to the draft" do
    state = opened(rows()) |> press!(key(:down))
    focus = state.focus
    assert press!(state, key(:page_down)).focus == focus

    graced = opened(rows(), grace: true)
    assert graced.interaction_grace != nil
    typed = press!(graced, letter("x"))
    assert text(typed) == "x"
    assert [{:question, @node} | _] = typed.layers

    dismissed = press!(typed, key(:escape))
    assert dismissed.layers == []
    assert {@node, 4} in dismissed.dismissed_interactions
  end

  # One question with sixteen options (the wire's most): at 120x20 the note
  # scrolls its body.
  defp long_opened do
    base = row("b-q0", 0, total: 1)

    options =
      for n <- 1..16, do: %DTO.QuestionOption{id: "o#{n}", label: "Choice #{n}"}

    state = opened([%{base | question: %{base.question | options: options}}])
    assert [{:question, @node}] = state.layers
    %{state | size: %SwarmCodeCLI.UI.Size{columns: 120, rows: 20}}
  end

  defp body_scroll(state), do: elem(Projector.project(state), 0).overlay.body_scroll

  # The number of the first option row the note draws.
  defp first_choice(state) do
    Enum.find_value(screen(state), fn line ->
      case Regex.run(~r/Choice (\d+)\b/, line) do
        [_, n] -> String.to_integer(n)
        nil -> nil
      end
    end)
  end

  test "PgDn and PgUp page a long note; the focus stays, and moving it brings the view back" do
    state = long_opened() |> press!(key(:down))
    focus = state.focus
    assert focus == "o1"
    assert body_scroll(state) == 0
    assert first_choice(state) == 1

    paged = press!(state, key(:page_down))
    assert paged.focus == focus
    assert body_scroll(paged) > 0
    assert first_choice(paged) > 1

    back = press!(paged, key(:page_up))
    assert back.focus == focus
    assert body_scroll(back) == 0
    assert first_choice(back) == 1

    # ↓ moves the focus: the paged offset goes and the focused row is in view.
    moved = press!(paged, key(:down))
    assert moved.focus == "o2"
    refute Map.has_key?(moved.selection, "dialog_scroll")
    assert first_choice(moved) == 1
  end

  test "Enter in the other field sends the words; it does not insert a newline" do
    state = opened([row("b-q0", 0, total: 1)]) |> press!(key(:tab))
    assert state.focus == "other"
    state = type(state, "hi")

    assert {:ok, {:interview, {:confirm, @node}}} = Keymap.resolve(key(:enter), state, %{})
    {sent, effects} = press(state, key(:enter))

    assert Enum.map(requests(effects), & &1.kind) == [
             {:answer_question, "r", @node, "b-q0", 4, %{option_ids: [], custom_text: "hi"}}
           ]

    assert sent.field_editors
           |> FieldEditors.fetch({:question_other, "b-q0", 4})
           |> Editor.text() == "hi"
  end

  test "the keymap table: → is :dialog_right in the dialog, and no key means two things" do
    right = Bindings.fetch(:dialog_right)
    assert {:right, []} in right.keys
    assert Bindings.key_in_context(right, :dialog) == {:right, []}

    pairs =
      for binding <- Bindings.all(),
          context <- binding.contexts,
          key <- binding.keys,
          do: {{context, key}, binding.id}

    duplicates =
      pairs
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.filter(fn {_pair, ids} -> length(Enum.uniq(ids)) > 1 end)

    assert duplicates == []
  end
end
