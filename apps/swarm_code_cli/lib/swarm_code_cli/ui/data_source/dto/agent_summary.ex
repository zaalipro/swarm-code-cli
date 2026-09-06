defmodule SwarmCodeCLI.UI.DataSource.DTO.AgentSummary do
  @moduledoc "Bounded, closed AgentSummary presentation facts."
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      id: :id,
      run_id: :id,
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
      launched_by_superseded: :boolean
    ],
    defaults: [
      id: nil,
      run_id: nil,
      revision: 0,
      state: :queued,
      allowed_actions: [],
      launched_by_superseded: false
    ]
end
