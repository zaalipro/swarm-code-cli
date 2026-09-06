defmodule SwarmCodeCLI.UI.DataSource.DTO.QuestionOption do
  @moduledoc "Bounded, closed QuestionOption presentation facts."
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      id: :id,
      label: :text
    ],
    defaults: [
      id: nil,
      label: ""
    ]
end
