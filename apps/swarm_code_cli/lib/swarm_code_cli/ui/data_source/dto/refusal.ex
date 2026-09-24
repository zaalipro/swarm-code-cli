defmodule SwarmCodeCLI.UI.DataSource.DTO.Refusal do
  @moduledoc """
  Why the daemon refused a command, in words (pass73 T3/T8).

  `code` is the service's reason ("nothing_to_compact", "missing_argument",
  "database_busy" …, never turned into an atom); `text` is the sentence the
  terminal shows: what happened and what to do.
  """
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [code: {:text, 64}, text: {:text, 500}],
    defaults: [code: "", text: ""]
end
