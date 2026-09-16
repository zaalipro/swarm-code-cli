defmodule SwarmCodeCLI.UI.DataSource.DTO.ModelOption do
  @moduledoc "One model a conversation may switch to: the provider that serves it and its id."
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      provider_id: :id,
      provider: {:text, 200},
      model: {:text, 200}
    ],
    defaults: [
      provider_id: nil,
      provider: "",
      model: ""
    ]
end
