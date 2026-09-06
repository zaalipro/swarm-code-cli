defmodule SwarmCodeCLI.UI.DataSource.DTO.TranscriptItem do
  @moduledoc "Bounded, closed TranscriptItem presentation facts."
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      id: :id,
      run_id: :id,
      conversation_id: :id,
      node_id: :id,
      revision: :revision,
      role: {:enum, [:user, :assistant, :system, :tool]},
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
      text: :text,
      reasoning: :text,
      attempt_id: :id,
      allowed_actions: :actions
    ],
    defaults: [
      id: nil,
      run_id: nil,
      conversation_id: nil,
      node_id: nil,
      revision: 0,
      role: :assistant,
      state: :running,
      text: "",
      reasoning: "",
      attempt_id: nil,
      allowed_actions: []
    ]
end
