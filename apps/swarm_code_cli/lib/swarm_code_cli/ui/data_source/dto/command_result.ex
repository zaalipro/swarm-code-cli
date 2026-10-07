defmodule SwarmCodeCLI.UI.DataSource.DTO.CommandResult do
  @moduledoc """
  cli020 C14/C16/C20: what an accepted conversation command answers beside
  its identifiers (`Outcome.result`). `kind` says which fields are set:

  - `:slot` (`attachment.slot`): `token`, the `path` the terminal writes the
    clipboard PNG to
  - `:attachment` (`attachment.attach_slot`): `attachment`, the staged image
  """
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      kind: {:enum, [:slot, :attachment, :rewound, :rewind_turns, :history]},
      token: {:optional, {:text, 32}},
      path: {:optional, {:text, 4096}},
      attachment: {:optional, {:dto, SwarmCodeCLI.UI.DataSource.DTO.StagedAttachment}}
    ],
    wire_defaults: [token: nil, path: nil, attachment: nil],
    defaults: [kind: :slot, token: nil, path: nil, attachment: nil]
end
