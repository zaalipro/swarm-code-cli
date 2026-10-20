defmodule SwarmCodeCLI.UI.DataSource.DTO.SlashWorkflow do
  @moduledoc """
  C-FEAT-8: one workflow the `/` popup and /help list: its name and one line
  of description. The daemon runs it when the draft names it.
  """
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      name: {:text, 64},
      description: {:text, 200}
    ],
    defaults: [
      name: "",
      description: ""
    ]
end
