defmodule SwarmCodeCLI.UI.DataSource.DTO.FeatureForm do
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      title: :text,
      submit_label: :text,
      action: {:enum, [:start, :save, :update]},
      fields: {:list, {:dto, SwarmCodeCLI.UI.DataSource.DTO.FormField}}
    ],
    defaults: [title: "", submit_label: "", action: :save, fields: []]
end
