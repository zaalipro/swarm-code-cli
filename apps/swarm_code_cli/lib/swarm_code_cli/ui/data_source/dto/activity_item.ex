defmodule SwarmCodeCLI.UI.DataSource.DTO.ActivityItem do
  @moduledoc "Bounded, closed ActivityItem presentation facts."
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      id: :id,
      run_id: :id,
      conversation_id: :id,
      kind: {:enum, [:question, :approval, :running, :paused, :failure, :completion]},
      state:
        {:enum,
         [
           :queued,
           :running,
           :streaming,
           :waiting_question,
           :waiting_approval,
           :paused,
           :retrying,
           :done,
           :failed,
           :stopped,
           :interrupted,
           :superseded
         ]},
      title: :text,
      revision: :revision,
      allowed_actions: :actions,
      interaction: {:optional, {:dto, SwarmCodeCLI.UI.DataSource.DTO.PendingInteraction}},
      deadline: {:optional, :revision},
      created_at: :revision
    ],
    defaults: [
      id: nil,
      run_id: nil,
      conversation_id: nil,
      kind: :running,
      state: :running,
      title: "",
      revision: 0,
      allowed_actions: [],
      interaction: nil,
      deadline: nil,
      created_at: 0
    ]
end
