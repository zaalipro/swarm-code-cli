defmodule SwarmCodeCLI.UI.Question do
  @moduledoc "Revision-exact question intents. Other text is isolated until a domain DTO supports it."
  alias SwarmCodeCLI.UI.MutationState

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
           if(multiple, do: Map.get(state.selection, {:question, item.id}, []), else: [option_id]),
         true <-
           selected != [] and Enum.all?(selected, fn id -> Enum.any?(options, &(&1.id == id)) end) do
      {:answer_question, item.run_id, item.node_id, item.id, item.expected_revision, selected}
    else
      _ -> :ignore
    end
  end
end
