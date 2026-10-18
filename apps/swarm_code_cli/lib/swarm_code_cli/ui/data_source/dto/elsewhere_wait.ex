defmodule SwarmCodeCLI.UI.DataSource.DTO.ElsewhereWait do
  @moduledoc """
  pass76: one approval or question that waits on the user in a conversation
  other than the one shown (a row of `DTO.Elsewhere`). `id` is the waiting
  node, which the shown conversation's interaction of the same request also
  carries; `title` is the conversation's.
  """
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      id: :id,
      run_id: :id,
      conversation_id: :id,
      kind: {:enum, [:approval, :question]},
      title: {:text, 256}
    ],
    defaults: [
      id: nil,
      run_id: nil,
      conversation_id: nil,
      kind: :approval,
      title: ""
    ]
end
