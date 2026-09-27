defmodule SwarmCodeCLI.UI.C75InterviewModelTest do
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{Editor, FieldEditors, Pass73Helpers, Question}
  alias SwarmCodeCLI.UI.DataSource.DTO

  @run "11111111-1111-4111-8111-111111111111"
  @node "22222222-2222-4222-8222-222222222222"
  @deadline 1_790_000_000_000

  # QA2's ask: Format (single), Fields (multi), Delivery (single). The ids sort as
  # index 2, 0, 1, so only `order_key/1` can put them in index order.
  defp row(id, index, header, multiple, options, opts) do
    %DTO.PendingInteraction{
      id: id,
      run_id: @run,
      node_id: @node,
      conversation_id: "c",
      kind: :question,
      state: :pending,
      expected_revision: 4,
      allowed_actions: [:answer_question],
      deadline: Keyword.get(opts, :deadline, @deadline),
      created_at: 1_789_999_000_000,
      question: %DTO.Question{
        prompt: header <> "?",
        multiple: multiple,
        index: index,
        header: header,
        total: Keyword.get(opts, :total, 3),
        agent_id: nil,
        requested_at: 1_789_998_930_000,
        options:
          Enum.map(options, fn {oid, label} ->
            %DTO.QuestionOption{id: oid, label: label, description: ""}
          end)
      }
    }
  end

  defp rows(opts \\ []) do
    [
      row("a-delivery", 2, "Delivery", false, [{"file", "A file"}, {"mail", "Mail"}], opts),
      row("b-format", 0, "Format", false, [{"csv", "CSV"}, {"json", "JSON"}], opts),
      row(
        "c-fields",
        1,
        "Fields",
        true,
        [
          {"o1", "Status and priority"},
          {"o2", "Assignee"},
          {"o3", "Customer email"},
          {"o4", "Comments"}
        ],
        opts
      )
    ]
  end

  defp state(rows, interviews \\ %{}) do
    state = Pass73Helpers.ready()

    state
    |> Map.put(:read_model, %{
      state.read_model
      | interactions: Map.new(rows, &{&1.id, &1})
    })
    |> Map.put(:interviews, interviews)
  end

  defp other(state, row_id, text) do
    {:ok, editor} = Editor.apply(Editor.new(max_bytes: 4_000), {:insert, text})

    %{
      state
      | field_editors: FieldEditors.put(state.field_editors, {:question_other, row_id, 4}, editor)
    }
  end

  defp interview(step, picks \\ %{}),
    do: %{@node => %{step: step, picks: picks, last_focus: %{}, sending: [], refused: %{}}}

  test "asks group one node's rows in index order; needs lists the ask once" do
    state = state(rows())

    assert [ask] = Question.asks(state)
    assert ask.node_id == @node
    assert ask.total == 3
    assert Enum.map(ask.rows, & &1.question.index) == [0, 1, 2]
    assert ask.legacy? == false
    assert [%{id: "b-format"}] = Question.needs(state)
    assert Question.ask_id(hd(Question.needs(state))) == @node
  end

  test "single-select follows focus, then an explicit pick, then the other text" do
    state = state(rows(), interview(0))
    ask = Question.ask(state, @node)
    format = Enum.at(ask.rows, 0)

    assert Question.answer(%{state | focus: "dialog"}, ask, format) == nil

    assert Question.answer(%{state | focus: "json"}, ask, format) ==
             %{option_ids: ["json"], custom_text: ""}

    picked = %{state | interviews: interview(0, %{"b-format" => "csv"}), focus: "json"}
    assert Question.answer(picked, ask, format) == %{option_ids: ["csv"], custom_text: ""}

    typed = other(picked, "b-format", "  my own ")
    assert Question.answer(typed, ask, format) == %{option_ids: [], custom_text: "  my own "}
  end

  test "multi-select answers the ticks in option order plus the other text" do
    state = state(rows(), interview(1))
    ask = Question.ask(state, @node)
    fields = Enum.at(ask.rows, 1)

    assert Question.answer(state, ask, fields) == nil

    ticked = %{state | selection: Map.put(state.selection, {:question, "c-fields"}, ["o2", "o1"])}

    assert Question.answer(ticked, ask, fields) ==
             %{option_ids: ["o1", "o2"], custom_text: ""}

    typed = other(ticked, "c-fields", "also the SLA breach flag, if tickets has one")

    assert Question.answer(typed, ask, fields) == %{
             option_ids: ["o1", "o2"],
             custom_text: "also the SLA breach flag, if tickets has one"
           }
  end

  test "the ledger, the intents and the completeness agree (QA2)" do
    state = state(rows(), interview(1, %{"b-format" => "csv"}))

    state =
      %{state | selection: Map.put(state.selection, {:question, "c-fields"}, ["o1", "o2"])}
      |> other("c-fields", "also the SLA breach flag, if tickets has one")

    ask = Question.ask(state, @node)

    assert Question.ledger(state, ask) == [
             {:done, "Format", "CSV"},
             {:current, "Fields",
              ~s(Status and priority, Assignee + "also the SLA breach flag, if tickets has one")},
             {:open, "Delivery", "not answered yet"}
           ]

    refute Question.complete?(state, ask)
    assert Question.first_unanswered(state, ask) == 2

    done = %{state | interviews: interview(1, %{"b-format" => "csv", "a-delivery" => "mail"})}
    assert Question.complete?(done, ask)

    assert [
             {:answer_question, @run, @node, "b-format", 4,
              %{option_ids: ["csv"], custom_text: ""}},
             {:answer_question, @run, @node, "c-fields", 4,
              %{
                option_ids: ["o1", "o2"],
                custom_text: "also the SLA breach flag, if tickets has one"
              }},
             {:answer_question, @run, @node, "a-delivery", 4,
              %{option_ids: ["mail"], custom_text: ""}}
           ] = Question.intents(done, ask)
  end

  test "a row the ask no longer carries reads answered earlier" do
    state = state(Enum.reject(rows(), &(&1.id == "b-format")), interview(0))
    ask = Question.ask(state, @node)

    assert [{:earlier, "Question 1", "answered earlier"}, {:current, "Fields", _}, {:open, _, _}] =
             Question.ledger(state, ask)
  end

  test "Enter words" do
    state = state(rows())
    ask = Question.ask(state, @node)
    iv = fn step -> interview(step)[@node] end

    one = state([row("q", 0, "Format", false, [{"csv", "CSV"}], total: 1)])

    assert Question.enter_words(Question.ask(one, @node), iv.(0), "Lead") ==
             "send to the Lead"

    assert Question.enter_words(ask, iv.(1), "Lead") == "next: Delivery"
    assert Question.enter_words(ask, iv.(2), "Lead") == "send 3 answers"

    left = state([Enum.at(rows(), 0)])
    assert Question.enter_words(Question.ask(left, @node), iv.(0), "Lead") == "send 1 answer"
  end

  test "deadline words and vanish notices" do
    ask = Question.ask(state(rows()), @node)

    assert Question.deadline_words(ask, @deadline - 29 * 60_000 - 1, "Lead") ==
             {"Esc later: the Lead keeps waiting, 29 min left", :text_faint}

    assert Question.deadline_words(ask, @deadline - 4 * 60_000, "Lead") ==
             {"Esc later: the Lead keeps waiting, 4 min left", :warning}

    assert Question.deadline_words(ask, @deadline + 60_000, "Lead") ==
             {"Esc later: the Lead keeps waiting, 0 min left", :warning}

    none = Question.ask(state(rows(deadline: 0)), @node)

    assert Question.deadline_words(none, 0, "Lead") ==
             {"Esc later: the Lead waits until you answer or stop", :text_faint}

    legacy = Question.ask(state(rows(deadline: 0, total: 0)), @node)
    assert legacy.legacy? and legacy.total == 3

    assert Question.deadline_words(legacy, 0, "Lead") ==
             {"Esc later: the Lead keeps waiting", :text_faint}

    assert Question.vanish_notice(ask, @deadline, "Lead") ==
             "The Lead stopped waiting: no answer after 30 min"

    assert Question.vanish_notice(ask, @deadline - 1, "Lead") ==
             "The Lead is no longer waiting for your answers"

    assert Question.vanish_notice(none, @deadline, "Lead") ==
             "The Lead is no longer waiting for your answers"
  end
end
