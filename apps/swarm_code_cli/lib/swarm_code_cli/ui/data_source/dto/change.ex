defmodule SwarmCodeCLI.UI.DataSource.DTO.Change do
  @moduledoc "Bounded, closed changes-ledger entry: one checkpoint of a run."
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    wire_defaults: [
      agent_id: nil,
      restorable: false,
      at: 0,
      op_id: nil,
      file_state: "unknown",
      added: nil,
      removed: nil,
      diff_ref: nil
    ],
    fields: [
      id: :id,
      run_id: :id,
      agent_id: {:optional, :id},
      path: {:text, 1024},
      restorable: :boolean,
      at: :count,
      # pass70 C1: the write op that made the change, whether the file was
      # created, modified or deleted, its line counts, and its unified diff on
      # demand (`detail` with `diff_ref.id`, `"<checkpoint_id>:diff"`).
      op_id: {:optional, :id},
      file_state: {:enum, [:created, :modified, :deleted, :unknown]},
      added: {:optional, :count},
      removed: {:optional, :count},
      diff_ref: {:optional, {:dto, SwarmCodeCLI.UI.DataSource.DTO.DetailRef}},
      revision: :revision
    ],
    defaults: [
      id: nil,
      run_id: nil,
      agent_id: nil,
      path: "",
      restorable: false,
      at: 0,
      op_id: nil,
      file_state: :unknown,
      added: nil,
      removed: nil,
      diff_ref: nil,
      revision: 0
    ]
end
