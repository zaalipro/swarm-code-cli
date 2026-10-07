defmodule SwarmCodeCLI.UI.DataSource.DTO.StagedAttachment do
  @moduledoc """
  cli020 C14/C16: an image staged for the next message (`/attach`, a pasted
  clipboard image, a rewound turn's images): its id, file name, MIME type and
  size in bytes (nil when the service did not say).
  """
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      id: :id,
      name: {:text, 256},
      mime: {:text, 64},
      bytes: {:optional, :count}
    ],
    wire_defaults: [bytes: nil],
    defaults: [id: nil, name: "", mime: "", bytes: nil]
end
