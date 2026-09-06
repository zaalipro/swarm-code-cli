defmodule SwarmCodeCLI.UI.DataSource.DTO.DetailRef do
  @moduledoc "Closed bounded canonical text detail facts."
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [id: :id, total_bytes: :revision],
    defaults: [id: nil, total_bytes: 0]
end
