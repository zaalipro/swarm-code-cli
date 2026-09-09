defmodule SwarmCodeCLI.UI.DataSource.DTO.LibraryItem do
  @moduledoc "A bounded feature-library row with explicit operation affordances."
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      id: :id,
      title: :text,
      subtitle: :text,
      status: :text,
      detail: :text,
      form: {:optional, {:dto, SwarmCodeCLI.UI.DataSource.DTO.FeatureForm}},
      actions:
        {:list,
         {:enum,
          [
            :start,
            :pause,
            :resume,
            :stop,
            :delete,
            :export,
            :restore,
            :configure,
            :inspect,
            :retry,
            :report,
            :toggle,
            :run_now,
            :update,
            :diff,
            :clear
          ]}}
    ],
    wire_defaults: [form: nil],
    defaults: [id: nil, title: "", subtitle: "", status: "", detail: "", form: nil, actions: []]
end
