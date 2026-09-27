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

      %{
        node_id: node_id,
        run_id: first.run_id,
        revision: revision,
        rows: rows,
        total: max(first.question.total, length(rows)),
        deadline: first.deadline,
        requested_at: first.question.requested_at,
        agent_id: first.question.agent_id,
        legacy?: first.question.total == 0
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
