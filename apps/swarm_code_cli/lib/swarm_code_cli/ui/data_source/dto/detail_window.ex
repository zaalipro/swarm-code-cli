defmodule SwarmCodeCLI.UI.DataSource.DTO.DetailWindow do
  @moduledoc "Closed bounded canonical text detail facts."
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      detail_ref: {:optional, {:dto, SwarmCodeCLI.UI.DataSource.DTO.DetailRef}},
      state: {:enum, [:idle, :error]},
      error: {:optional, :error},
      offset: :revision,
      text: :text,
      next_offset: {:optional, :revision},
      through_sequence: :revision,
      request_id: :id
    ],
    defaults: [
      detail_ref: nil,
      state: :idle,
      error: nil,
      offset: 0,
      text: "",
      next_offset: nil,
      through_sequence: 0,
      request_id: nil
    ]
end
