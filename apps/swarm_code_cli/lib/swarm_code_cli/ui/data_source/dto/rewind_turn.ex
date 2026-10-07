defmodule SwarmCodeCLI.UI.DataSource.DTO.RewindTurn do
  @moduledoc """
  cli020 C16: one turn the conversation can be rewound to (`rewind.turns`):
  the user message, its position, the turn number of the run it launched (nil
  for none), the first line of the prompt (120 characters), when it was sent
  (ms), that run, and how many files the turn changed.
  """
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      message_id: :id,
      position: :count,
      turn: {:optional, :count},
      prompt: {:text, 512},
      at: :count,
      run_id: {:optional, :id},
      files: :count
    ],
    defaults: [
      message_id: nil,
      position: 0,
      turn: nil,
      prompt: "",
      at: 0,
      run_id: nil,
      files: 0
    ]
end
