defmodule SwarmCodeCLI.UI.DataSource.DTO.RunSummary do
  @moduledoc "Bounded, closed RunSummary presentation facts."
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
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
      progress: :progress
    ],
    defaults: [
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
