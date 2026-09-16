defmodule SwarmCodeCLI.UI.DataSource.DTO.WorkspaceMetadata do
  @moduledoc "Saved conversation mode and model metadata for the workspace header."
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    wire_defaults: [project: nil, models: []],
    fields: [
      conversation_id: :id,
      mode: {:enum, [:build, :plan, :ultra, :workflow, :consensus]},
      project: {:optional, {:text, 200}},
      chat_model: {:optional, :text},
      swarm_model: {:optional, :text},
      effort: {:optional, :text},
      swarm_effort: {:optional, :text},
      models: {:list, {:dto, SwarmCodeCLI.UI.DataSource.DTO.ModelOption}}
    ],
    defaults: [
      conversation_id: nil,
      mode: :build,
      project: nil,
      chat_model: nil,
      swarm_model: nil,
      effort: nil,
      swarm_effort: nil,
      models: []
    ]
end
