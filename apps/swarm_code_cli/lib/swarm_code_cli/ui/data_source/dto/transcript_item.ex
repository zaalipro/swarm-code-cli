defmodule SwarmCodeCLI.UI.DataSource.DTO.TranscriptItem do
  @moduledoc "Bounded, closed TranscriptItem presentation facts."
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    wire_defaults: [
      created_sequence: 0,
      attachment_refs: [],
      detail_ref: nil,
      reasoning_detail_ref: nil,
      target_kind: "main",
      target_id: nil
    ],
    fields: [
      created_sequence: :revision,
      attachment_refs: {:list, :id},
      detail_ref: {:optional, {:dto, SwarmCodeCLI.UI.DataSource.DTO.DetailRef}},
      reasoning_detail_ref: {:optional, {:dto, SwarmCodeCLI.UI.DataSource.DTO.DetailRef}},
      target_kind: {:enum, [:main, :reply, :thread, :revise, :command, :goal, :research, :steer]},
      target_id: {:optional, :id},
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
      created_sequence: 0,
      attachment_refs: [],
      detail_ref: nil,
      reasoning_detail_ref: nil,
      target_kind: :main,
      target_id: nil,
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
