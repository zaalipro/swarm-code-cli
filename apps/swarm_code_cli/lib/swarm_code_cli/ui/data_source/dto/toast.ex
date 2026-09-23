defmodule SwarmCodeCLI.UI.DataSource.DTO.Toast do
  @moduledoc """
  pass70 C1: a transient notice (`toast` delta, shell watch only): a run
  finished or waits for you, a workflow resumed, a setting changed. `run_id` and
  `conversation_id` name what it is about when it is about one; `at` is unix
  milliseconds. Toasts have no snapshot: a client that missed one lost nothing
  it cannot see elsewhere.
  """
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      id: :id,
      level: {:enum, [:info, :success, :waiting, :warning, :error]},
      title: {:text, 200},
      text: {:text, 1024},
      run_id: {:optional, :id},
      conversation_id: {:optional, :id},
      at: :count,
      revision: :revision
    ],
    defaults: [
      id: nil,
      level: :info,
      title: "",
      text: "",
      run_id: nil,
      conversation_id: nil,
      at: 0,
      revision: 0
    ]
end
