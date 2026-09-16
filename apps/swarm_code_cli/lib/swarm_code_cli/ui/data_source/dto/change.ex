defmodule SwarmCodeCLI.UI.DataSource.DTO.Change do
  @moduledoc "Bounded, closed changes-ledger entry: one checkpoint of a run."
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    wire_defaults: [agent_id: nil, restorable: false, at: 0],
    fields: [
      id: :id,
      run_id: :id,
      agent_id: {:optional, :id},
      path: {:text, 1024},
      restorable: :boolean,
      at: :count,
      revision: :revision
    ],
    defaults: [
      id: nil,
      run_id: nil,
      agent_id: nil,
      path: "",
      restorable: false,
      at: 0,
      revision: 0
    ]
end
