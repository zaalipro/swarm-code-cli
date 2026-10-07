defmodule SwarmCodeCLI.UI.DataSource.DTO.CommandResult do
  @moduledoc """
  cli020 C14/C16/C20: what an accepted conversation command answers beside
  its identifiers (`Outcome.result`). `kind` says which fields are set:

  - `:slot` (`attachment.slot`): `token`, the `path` the terminal writes the
    clipboard PNG to
  - `:attachment` (`attachment.attach_slot`, `/attach`): `attachment`, the
    staged image
  - `:rewound` (`rewind.apply`, `/undo`): `text` (the rewound prompt for the
    composer; nil when only files were rewound), `attachments` (its images,
    staged again), `restored` (files put back), `skipped` (files that could
    not be, with why)
  - `:rewind_turns` (`rewind.turns`): `turns`, newest first
  """
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      kind: {:enum, [:slot, :attachment, :rewound, :rewind_turns, :history]},
      token: {:optional, {:text, 32}},
      path: {:optional, {:text, 4096}},
      attachment: {:optional, {:dto, SwarmCodeCLI.UI.DataSource.DTO.StagedAttachment}},
      text: {:optional, {:text, 262_144}},
      attachments: {:list, {:dto, SwarmCodeCLI.UI.DataSource.DTO.StagedAttachment}, 4},
      restored: {:optional, :count},
      skipped: {:list, {:text, 1024}, 50},
      turns: {:list, {:dto, SwarmCodeCLI.UI.DataSource.DTO.RewindTurn}, 200}
    ],
    wire_defaults: [
      token: nil,
      path: nil,
      attachment: nil,
      text: nil,
      attachments: [],
      restored: nil,
      skipped: [],
      turns: []
    ],
    defaults: [
      kind: :slot,
      token: nil,
      path: nil,
      attachment: nil,
      text: nil,
      attachments: [],
      restored: nil,
      skipped: [],
      turns: []
    ]
end
