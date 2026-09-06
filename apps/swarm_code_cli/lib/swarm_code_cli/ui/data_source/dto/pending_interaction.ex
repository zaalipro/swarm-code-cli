defmodule SwarmCodeCLI.UI.DataSource.DTO.PendingInteraction do
  @moduledoc "Bounded, closed PendingInteraction presentation facts."
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      id: :id,
      run_id: :id,
      node_id: :id,
      conversation_id: :id,
      kind: {:enum, [:question, :approval]},
      expected_revision: :revision,
      state: {:enum, [:pending, :resolved]},
      question: {:optional, {:dto, SwarmCodeCLI.UI.DataSource.DTO.Question}},
      allowed_actions: :actions,
      urgency: {:enum, [:normal, :high, :urgent]},
      deadline: :revision,
      created_at: :revision
    ],
    defaults: [
      id: nil,
      run_id: nil,
      node_id: nil,
      conversation_id: nil,
      kind: :question,
      expected_revision: 0,
      state: :pending,
      question: nil,
      allowed_actions: [],
      urgency: :normal,
      deadline: 0,
      created_at: 0
    ]
end
