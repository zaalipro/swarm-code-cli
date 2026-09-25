defmodule SwarmCodeCLI.UI.DataSource.DTO.WorkspaceMetadata do
  @moduledoc "Saved conversation mode and model metadata for the workspace header."
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    wire_defaults: [
      project: nil,
      models: [],
      approval_mode: nil,
      trusted: nil,
      chat_provider: nil,
      chat_provider_usable: nil,
      context_used: nil,
      context_window: nil,
      cost_usd: nil,
      title: nil,
      queued: 0,
      queued_texts: []
    ],
    fields: [
      conversation_id: :id,
      mode: {:enum, [:build, :plan, :ultra, :workflow, :consensus]},
      project: {:optional, {:text, 200}},
      chat_model: {:optional, :text},
      swarm_model: {:optional, :text},
      effort: {:optional, :text},
      swarm_effort: {:optional, :text},
      # pass74 S1-11 (R5): the service sends up to 400 models.
      models: {:list, {:dto, SwarmCodeCLI.UI.DataSource.DTO.ModelOption}, 400},
      # pass70 C1 (see WorkspaceSnapshot): project approval mode and trust,
      # the chat model's provider, the context gauge, the conversation's
      # spend and title.
      approval_mode: {:optional, {:enum, [:read_only, :auto, :full_access]}},
      trusted: {:optional, :boolean},
      chat_provider: {:optional, {:text, 200}},
      # pass74 S1-11 (D11): whether that provider can answer (a key, or a
      # private-host base URL); false with no provider; nil when not known.
      chat_provider_usable: {:optional, :boolean},
      context_used: {:optional, :count},
      context_window: {:optional, :count},
      cost_usd: {:optional, :float},
      title: {:optional, {:text, 256}},
      # pass71 S5: prompts of this conversation queued behind its live turn.
      queued: :count,
      # pass73 T3/T8: what waits there, oldest first (at most 20, 2 KB each).
      queued_texts: {:list, {:text, 2048}}
    ],
    defaults: [
      conversation_id: nil,
      mode: :build,
      project: nil,
      chat_model: nil,
      swarm_model: nil,
      effort: nil,
      swarm_effort: nil,
      models: [],
      approval_mode: nil,
      trusted: nil,
      chat_provider: nil,
      chat_provider_usable: nil,
      context_used: nil,
      context_window: nil,
      cost_usd: nil,
      title: nil,
      queued: 0,
      queued_texts: []
    ]
end
