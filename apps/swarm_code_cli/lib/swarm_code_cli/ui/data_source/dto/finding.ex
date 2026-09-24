defmodule SwarmCodeCLI.UI.DataSource.DTO.Finding do
  @moduledoc """
  pass72 S: one numbered finding of an agent's result, as the result lists it:
  its severity only when the result names one, and the first `path:line` it
  cites.
  """
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      n: :count,
      severity: {:optional, {:enum, [:high, :medium, :low]}},
      text: {:text, 400},
      ref: {:optional, {:text, 200}}
    ],
    defaults: [n: 0, severity: nil, text: "", ref: nil]
end
