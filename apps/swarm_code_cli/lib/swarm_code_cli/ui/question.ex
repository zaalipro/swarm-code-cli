defmodule SwarmCodeCLI.UI.Question do
  @moduledoc "Revision-exact option and custom-text answers, isolated from conversation drafts."
  alias SwarmCodeCLI.UI.{MutationState, Editor, FieldEditors}

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
