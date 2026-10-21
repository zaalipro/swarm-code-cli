defmodule SwarmCodeCLI.UI.DataSource.DTO.SlashExtras do
  @moduledoc """
  C-FEAT-1 / C-FEAT-8: what the daemon knows of the project that the terminal's
  builtin command catalogue does not: its custom commands and workflows, at
  most 200 in all (the daemon keeps them sorted by name). Part of the workspace
  metadata; an older daemon sends none, which reads as two empty lists.
  """
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      custom: {:list, {:dto, SwarmCodeCLI.UI.DataSource.DTO.SlashCommand}, 200},
      workflows: {:list, {:dto, SwarmCodeCLI.UI.DataSource.DTO.SlashWorkflow}, 200}
    ],
    defaults: [
      custom: [],
      workflows: []
    ]
end
