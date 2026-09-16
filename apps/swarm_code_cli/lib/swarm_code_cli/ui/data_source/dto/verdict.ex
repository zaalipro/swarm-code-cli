defmodule SwarmCodeCLI.UI.DataSource.DTO.Verdict do
  @moduledoc "Bounded, closed judge verdict parsed from a consensus run's judge node."
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    wire_defaults: [round: 0, status: "done", checks: [], summary: ""],
    fields: [
      id: :id,
      run_id: :id,
      round: :count,
      status:
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
      checks: {:list, {:dto, SwarmCodeCLI.UI.DataSource.DTO.VerdictCheck}},
      summary: {:text, 400},
      revision: :revision
    ],
    defaults: [
      id: nil,
      run_id: nil,
      round: 0,
      status: :done,
      checks: [],
      summary: "",
      revision: 0
    ]
end
