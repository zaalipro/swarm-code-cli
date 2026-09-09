defmodule SwarmCodeCLI.UI.DataSource.DTO.Feedback do
  @moduledoc "Bounded user-facing feedback returned by a slash command."
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      kind: {:enum, [:report, :navigate, :notice]},
      feature:
        {:optional,
         {:enum,
          [
            :workflows,
            :research,
            :schedules,
            :settings,
            :usage,
            :changes,
            :checkpoints,
            :mcp,
            :memory
          ]}},
      title: :text,
      text: :text,
      conversation_id: {:optional, :id}
    ],
    defaults: [kind: :notice, feature: nil, title: "", text: "", conversation_id: nil]

  def decode_kind("report"), do: {:ok, :report}
  def decode_kind("navigate"), do: {:ok, :navigate}
  def decode_kind("notice"), do: {:ok, :notice}
  def decode_kind(_), do: :error
end
