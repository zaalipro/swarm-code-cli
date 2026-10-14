defmodule SwarmCodeCLI.UI.DataSource.DTO.HomeMonth do
  @moduledoc "orbit: this month's spend and the monthly budget (nil when none is set), in US dollars."
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [spend_usd: :float, budget_usd: {:optional, :float}],
    defaults: [spend_usd: 0.0, budget_usd: nil]
end
