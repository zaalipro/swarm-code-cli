defmodule SwarmCodeCLI.UI.DataSource.DTO.Connection do
  @moduledoc "Bounded, closed Connection presentation facts."
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      state: {:enum, [:connecting, :connected, :stale, :resyncing, :disconnected, :closed]},
      source_epoch: :id
    ],
    defaults: [
      state: :connected,
      source_epoch: nil
    ]
end
