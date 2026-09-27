defmodule SwarmCodeCLI.UI.DataSource.DTO.Question do
  @moduledoc """
  Bounded, closed Question presentation facts.

  pass75 interview: index, header, total, agent_id, requested_at
  """
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    wire_defaults: [
      index: 0,
      header: nil,
      total: 0,
      agent_id: nil,
      requested_at: nil
    ],
    fields: [
      prompt: :text,
      options: {:list, {:dto, SwarmCodeCLI.UI.DataSource.DTO.QuestionOption}},
      multiple: :boolean,
      index: :count,
      header: {:optional, {:text, 64}},
      total: :count,
      agent_id: {:optional, :id},
      requested_at: {:optional, :count}
    ],
    defaults: [
      prompt: "",
      options: [],
      multiple: false,
      index: 0,
      header: nil,
      total: 0,
      agent_id: nil,
      requested_at: nil
    ]
end
