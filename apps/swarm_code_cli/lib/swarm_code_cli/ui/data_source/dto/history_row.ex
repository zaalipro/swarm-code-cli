defmodule SwarmCodeCLI.UI.DataSource.DTO.HistoryRow do
  @moduledoc """
  cli020 C20 (competitors-19): one prompt of the project's history
  (`history.search`, Ctrl-R): its first 2 KB, the conversation it was sent in,
  when (ms), and a `detail_ref` for the rest when it is longer (a prompt of
  the open conversation only: details are read in its scope).
  """
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      text: {:text, 2048},
      conversation_id: :id,
      at: :count,
      detail_ref: {:optional, {:dto, SwarmCodeCLI.UI.DataSource.DTO.DetailRef}}
    ],
    wire_defaults: [detail_ref: nil],
    defaults: [text: "", conversation_id: nil, at: 0, detail_ref: nil]
end
