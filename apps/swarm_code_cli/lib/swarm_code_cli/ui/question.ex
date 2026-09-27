defmodule SwarmCodeCLI.UI.Question do
  @moduledoc "Revision-exact option and custom-text answers, isolated from conversation drafts."
  alias SwarmCodeCLI.UI.{MutationState, Editor, FieldEditors}

  @type row :: SwarmCodeCLI.UI.DataSource.DTO.PendingInteraction.t()
  @type ask :: %{
          node_id: binary(),
          run_id: binary(),
          revision: integer(),
          rows: [row()],
          total: pos_integer(),
          deadline: non_neg_integer(),
          requested_at: integer() | nil,
          agent_id: binary() | nil,
          legacy?: boolean()
        }
  @type interview :: %{
          step: non_neg_integer(),
          picks: %{binary() => binary()},
          last_focus: %{binary() => binary()},
          sending: [binary()],
          refused: %{binary() => binary()}
        }

  @new_interview %{step: 0, picks: %{}, last_focus: %{}, sending: [], refused: %{}}
  @timeout_ms 1_800_000

  @doc "The one ordering key of pending interactions: creation, asker, question index, id."
  @spec order_key(row()) :: {integer(), binary(), integer(), binary()}
  def order_key(row), do: {row.created_at, row.node_id, index(row), row.id}

  defp index(%{kind: :question, question: %{index: i}}), do: i
  defp index(_), do: 0

  @doc "The layer id of a pending row: the asking op's node for a question, the row for an approval."
  @spec ask_id(row()) :: binary()
  def ask_id(%{kind: :question, node_id: node}), do: node
  def ask_id(row), do: row.id

  @doc "Pending question rows grouped into asks (one per asking node), rows in index order."
  @spec asks(map()) :: [ask()]
  def asks(state) do
    state.read_model.interactions
    |> Map.values()
    |> Enum.filter(&(&1.kind == :question and &1.state == :pending))
    |> Enum.group_by(& &1.node_id)
    |> Enum.map(fn {node_id, group} ->
      revision = group |> Enum.map(& &1.expected_revision) |> Enum.max()

      rows =
        group
        |> Enum.filter(&(&1.expected_revision == revision))
        |> Enum.sort_by(&order_key/1)

      first = hd(rows)
      # A row without its question body still counts as waiting.
      question = first.question || %SwarmCodeCLI.UI.DataSource.DTO.Question{}

      %{
        node_id: node_id,
        run_id: first.run_id,
        revision: revision,
        rows: rows,
        total: max(question.total, length(rows)),
        deadline: first.deadline,
        requested_at: question.requested_at,
        agent_id: question.agent_id,
        legacy?: question.total == 0
      }
    end)
    |> Enum.sort_by(&order_key(hd(&1.rows)))
  end

  @doc "The pending ask of `node_id`, or nil."
  @spec ask(map(), binary()) :: ask() | nil
  def ask(state, node_id), do: Enum.find(asks(state), &(&1.node_id == node_id))

  @doc "Every pending approval plus the first row of every ask, in `order_key/1` order."
  @spec needs(map()) :: [row()]
  def needs(state) do
    approvals =
      state.read_model.interactions
      |> Map.values()
      |> Enum.filter(&(&1.kind == :approval and &1.state == :pending))

    (approvals ++ Enum.map(asks(state), &hd(&1.rows)))
    |> Enum.sort_by(&order_key/1)
  end

  @doc "A question's header, or `Question N` (N = index + 1)."
  @spec header(row()) :: binary()
  def header(row),
    do: row.question.header || "Question " <> Integer.to_string(row.question.index + 1)

  @doc "The held interview of an ask, or a fresh one."
  @spec interview(map(), binary()) :: interview()
  def interview(state, node_id), do: Map.get(state.interviews, node_id, @new_interview)

  @doc "The row the interview's step points at."
  @spec current(ask(), interview()) :: row() | nil
  def current(ask, interview),
    do: Enum.at(ask.rows, min(interview.step, length(ask.rows) - 1))

  @doc "The focus ids of a question: its option ids, then `\"other\"`."
  @spec focus_ids(row()) :: [binary()]
  def focus_ids(row), do: Enum.map(row.question.options, & &1.id) ++ ["other"]

  @doc """
  What the final Enter would send for `row`, or nil.

  Single-select: non-blank "other" text replaces the pick; else the explicit pick, else the
  focused option of the current step. Multi-select: the ticks (in option order) plus the
  "other" text.
  """
  @spec answer(map(), ask(), row()) :: %{option_ids: [binary()], custom_text: binary()} | nil
  def answer(state, ask, row) do
    text = other_text(state, row)
    blank? = String.trim(text) == ""

    if row.question.multiple do
      ticked = Map.get(state.selection, {:question, row.id}, [])
      ticks = for option <- row.question.options, option.id in ticked, do: option.id

      if ticks == [] and blank?, do: nil, else: %{option_ids: ticks, custom_text: text}
    else
      pick =
        Map.get(interview(state, ask.node_id).picks, row.id) || focused_option(state, ask, row)

      cond do
        not blank? -> %{option_ids: [], custom_text: text}
        pick != nil -> %{option_ids: [pick], custom_text: ""}
        true -> nil
      end
    end
  end

  defp focused_option(state, ask, row) do
    if current(ask, interview(state, ask.node_id)) == row and
         Enum.any?(row.question.options, &(&1.id == state.focus)),
       do: state.focus
  end

  @doc "Every row of the ask with its answer (or nil), in index order."
  @spec answers(map(), ask()) :: [{row(), map() | nil}]
  def answers(state, ask), do: Enum.map(ask.rows, &{&1, answer(state, ask, &1)})

  @spec complete?(map(), ask()) :: boolean()
  def complete?(state, ask), do: Enum.all?(answers(state, ask), fn {_, a} -> a != nil end)

  @doc "The position in `ask.rows` of the first unanswered row, else 0."
  @spec first_unanswered(map(), ask()) :: non_neg_integer()
  def first_unanswered(state, ask),
    do: Enum.find_index(answers(state, ask), fn {_, a} -> a == nil end) || 0

  @doc "One `:answer_question` intent per answered row, in index order."
  @spec intents(map(), ask()) :: [tuple()]
  def intents(state, ask) do
    for {row, answer} <- answers(state, ask), answer != nil do
      {:answer_question, row.run_id, row.node_id, row.id, row.expected_revision, answer}
    end
  end

  @doc "The `You will send` ledger: one `{glyph_state, header, words}` per asked index."
  @spec ledger(map(), ask()) :: [{:done | :current | :open | :earlier, binary(), binary()}]
  def ledger(state, ask) do
    current = current(ask, interview(state, ask.node_id))

    for i <- 0..(ask.total - 1)//1 do
      case Enum.find(ask.rows, &(&1.question.index == i)) do
        nil ->
          {:earlier, "Question " <> Integer.to_string(i + 1), "answered earlier"}

        row ->
          answer = answer(state, ask, row)

          glyph =
            cond do
              row == current -> :current
              answer != nil -> :done
              true -> :open
            end

          {glyph, header(row), answer_words(row, answer)}
      end
    end
  end

  defp answer_words(_row, nil), do: "not answered yet"

  defp answer_words(row, %{option_ids: ids, custom_text: text}) do
    labels =
      for option <- row.question.options, option.id in ids, do: option.label

    parts =
      [Enum.join(labels, ", "), if(String.trim(text) != "", do: ~s("#{text}"), else: "")]
      |> Enum.reject(&(&1 == ""))

    Enum.join(parts, " + ")
  end

  @doc "The words after `Enter` on the note's keys row."
  @spec enter_words(ask(), interview(), binary()) :: binary()
  def enter_words(ask, interview, name) do
    last = length(ask.rows) - 1
    step = min(interview.step, last)

    cond do
      ask.total == 1 -> "send to " <> the(name)
      step < last -> "next: " <> header(Enum.at(ask.rows, step + 1))
      last == 0 -> "send 1 answer"
      true -> "send " <> Integer.to_string(last + 1) <> " answers"
    end
  end

  @doc "The note's bottom-left words and their role."
  @spec deadline_words(ask(), integer(), binary()) :: {binary(), :text_faint | :warning}
  def deadline_words(%{deadline: 0, legacy?: true}, _now_ms, name),
    do: {"Esc later: " <> the(name) <> " keeps waiting", :text_faint}

  def deadline_words(%{deadline: 0}, _now_ms, name),
    do: {"Esc later: " <> the(name) <> " waits until you answer or stop", :text_faint}

  def deadline_words(%{deadline: deadline}, now_ms, name) do
    left = deadline - now_ms
    minutes = max(div(left, 60_000), 0)

    {"Esc later: " <>
       the(name) <> " keeps waiting, " <> Integer.to_string(minutes) <> " min left",
     if(left < 300_000, do: :warning, else: :text_faint)}
  end

  @doc "The notice when every row of an ask left before the CLI sent anything."
  @spec vanish_notice(ask(), integer(), binary()) :: binary()
  def vanish_notice(%{deadline: deadline}, now_ms, name)
      when deadline > 0 and now_ms >= deadline,
      do:
        capital(the(name)) <>
          " stopped waiting: no answer after " <>
          Integer.to_string(div(@timeout_ms, 60_000)) <> " min"

  def vanish_notice(_ask, _now_ms, name),
    do: capital(the(name)) <> " is no longer waiting for your answers"

  # "the Lead"; the default speakers already carry their article ("The
  # assistant", "An agent", `ApprovalCard.who/2`), so they read "the
  # assistant" and "an agent", never "the The assistant".
  defp the("The " <> rest), do: "the " <> rest
  defp the("An " <> rest), do: "an " <> rest
  defp the("A " <> rest), do: "a " <> rest
  defp the(name), do: "the " <> name

  defp capital(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest

  def other_text(state, item),
    do:
      state.field_editors
      |> FieldEditors.fetch({:question_other, item.id, item.expected_revision})
      |> Editor.text()

  def answer_intent(state, item, option_id) do
    with %{state: :pending, kind: :question, question: %{options: options, multiple: multiple}} =
           current <- Map.get(state.read_model.interactions, item.id),
         true <- current == item,
         true <- :answer_question in current.allowed_actions,
         false <-
           MutationState.pending?(
             Map.get(state.mutations, {:interaction, item.id, item.expected_revision})
           ),
         false <-
           match?(
             {:settled, _, :accepted},
             Map.get(state.mutations, {:interaction, item.id, item.expected_revision})
           ),
         selected =
           if(multiple,
             do: Map.get(state.selection, {:question, item.id}, []),
             else: if(option_id in ["other", "submit"], do: [], else: [option_id])
           ),
         custom = other_text(state, item),
         true <-
           (selected != [] or String.trim(custom) != "") and byte_size(custom) <= 4_000 and
             Enum.all?(selected, fn id -> Enum.any?(options, &(&1.id == id)) end) do
      payload = if custom == "", do: selected, else: %{option_ids: selected, custom_text: custom}
      {:answer_question, item.run_id, item.node_id, item.id, item.expected_revision, payload}
    else
      _ -> :ignore
    end
  end
end
