defmodule SwarmCodeCLI.UI.DataSource.DTO.StatusEntry do
  @moduledoc "Fixed presentation catalogue evidence, separate from canonical run state."
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      id: :id,
      state:
        {:enum,
         [
           :connecting,
           :empty,
           :loading,
           :running,
           :streaming,
           :queued,
           :waiting_question,
           :waiting_approval,
           :paused,
           :retrying,
           :done,
           :failed,
           :stopped,
           :interrupted,
           :stale,
           :resyncing,
           :disconnected,
           :superseded,
           :mutation_pending
         ]},
      revision: :revision,
      allowed_actions: :actions,
      page_state: {:enum, [:idle, :loading_before]},
      request_id: {:optional, :id}
    ],
    defaults: [
      id: nil,
      state: :empty,
      revision: 0,
      allowed_actions: [],
      page_state: :idle,
      request_id: nil
    ]
end
