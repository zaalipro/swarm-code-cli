defmodule SwarmCodeCLI.UI.DataSource.DTO.RunSummary do
  @moduledoc "Bounded, closed RunSummary presentation facts."
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    wire_defaults: [created_sequence: 0, parent_run_id: nil, seen_revision: 0],
    fields: [
      created_sequence: :revision,
      parent_run_id: {:optional, :id},
      seen_revision: :revision,
      id: :id,
      conversation_id: :id,
      kind: {:enum, [:chat, :goal, :swarm, :workflow, :research, :consensus, :ultra]},
      title: :text,
      revision: :revision,
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
      allowed_actions: :actions,
      progress: {:optional, :progress}
    ],
    defaults: [
      created_sequence: 0,
      parent_run_id: nil,
      seen_revision: 0,
      id: nil,
      conversation_id: nil,
      kind: :chat,
      title: "",
      revision: 0,
      state: :queued,
      allowed_actions: [],
      progress: 0
    ]
end
