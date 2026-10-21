defmodule SwarmCodeCLI.UI.DataSource.DTO.SlashCommand do
  @moduledoc """
  C-FEAT-1: one custom command of the project (or the user) the `/` popup and
  /help list: its name, one line of description, and whether its prompt takes
  arguments (`$ARGUMENTS`, `$1`..`$9`). Never its body: the daemon runs it.
  """
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      name: {:text, 64},
      description: {:text, 200},
      args: :boolean
    ],
    defaults: [
      name: "",
      description: "",
      args: false
    ]
end
