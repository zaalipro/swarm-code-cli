defmodule SwarmCodeCLI.UI.DataSource.DTO.OpLine do
  @moduledoc "pass72 S: one raw operation of an agent, for the overlay's `o` view."
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      id: :id,
      op_type: {:text, 64},
      title: {:text, 200},
      status: {:enum, [:running, :waiting, :done, :failed, :stopped, :queued]},
      started_at: {:optional, :count},
      duration_ms: {:optional, :count}
    ],
    defaults: [
      id: nil,
      op_type: "",
      title: "",
      status: :done,
      started_at: nil,
      duration_ms: nil
    ]
end
