defmodule SwarmCodeCLI.UI.DataSource.DTO.Approval do
  @moduledoc "The actual tool operation awaiting a scoped user decision."
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      tool: :text,
      permission: {:enum, [:write, :execute]},
      arguments_preview: :text,
      arguments_detail_ref: {:optional, {:dto, SwarmCodeCLI.UI.DataSource.DTO.DetailRef}}
    ],
    defaults: [tool: "", permission: :write, arguments_preview: "", arguments_detail_ref: nil]
end
