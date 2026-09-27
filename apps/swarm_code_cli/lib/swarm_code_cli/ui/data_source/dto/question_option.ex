defmodule SwarmCodeCLI.UI.DataSource.DTO.QuestionOption do
  @moduledoc """
  Bounded, closed QuestionOption presentation facts.

  pass75 interview: description
  """
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    wire_defaults: [description: ""],
    fields: [
      id: :id,
      label: :text,
      description: {:text, 512}
    ],
    defaults: [
      id: nil,
      label: "",
      description: ""
    ]
end
