defmodule SwarmCodeCLI.UI.DataSource.DTO.Question do
  @moduledoc "Bounded, closed Question presentation facts."
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      prompt: :text,
      options: {:list, {:dto, SwarmCodeCLI.UI.DataSource.DTO.QuestionOption}},
      multiple: :boolean
    ],
    defaults: [
      prompt: "",
      options: [],
      multiple: false
    ]
end
