defmodule SwarmCodeCLI.UI.DataSource.DTO.FormField do
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      key: :id,
      label: :text,
      kind: {:enum, [:text, :integer, :number, :boolean, :choice, :json]},
      value: :text,
      required: :boolean,
      choices: {:list, :text},
      hint: :text
    ],
    defaults: [key: "", label: "", kind: :text, value: "", required: false, choices: [], hint: ""]
end
