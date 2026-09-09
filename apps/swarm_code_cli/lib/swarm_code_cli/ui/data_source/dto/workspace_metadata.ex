defmodule SwarmCodeCLI.UI.DataSource.DTO.WorkspaceMetadata do
  @moduledoc "Saved conversation mode and model metadata for the workspace header."
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      conversation_id: :id,
      mode: {:enum, [:build, :plan, :ultra, :workflow, :consensus]},
      chat_model: {:optional, :text},
      swarm_model: {:optional, :text},
      effort: {:optional, :text},
      swarm_effort: {:optional, :text}
    ],
    defaults: [
      conversation_id: nil,
      mode: :build,
      chat_model: nil,
      swarm_model: nil,
      effort: nil,
      swarm_effort: nil
    ]
end
