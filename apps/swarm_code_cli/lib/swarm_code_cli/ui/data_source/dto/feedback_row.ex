defmodule SwarmCodeCLI.UI.DataSource.DTO.FeedbackRow do
  @moduledoc """
  cli020 C8/C9/C18: one row of a structured command answer (`Feedback.rows`).
  Which fields are set depends on the feedback's `subject`:

  - `:search`: `conversation_id`, `title`, `snippet`, `at` (Enter resumes it)
  - `:agents`: `name`, `source`, `model`, `description`
  - `:cost`: `model`, `runs`, `tokens_in`, `tokens_out`, `cost_usd` (nil when
    a price is unknown)
  """
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      conversation_id: {:optional, :id},
      title: {:optional, {:text, 256}},
      snippet: {:optional, {:text, 512}},
      at: {:optional, :count},
      name: {:optional, {:text, 200}},
      source: {:optional, {:text, 64}},
      model: {:optional, {:text, 200}},
      description: {:optional, {:text, 512}},
      runs: {:optional, :count},
      tokens_in: {:optional, :count},
      tokens_out: {:optional, :count},
      cost_usd: {:optional, :float}
    ],
    defaults: [
      conversation_id: nil,
      title: nil,
      snippet: nil,
      at: nil,
      name: nil,
      source: nil,
      model: nil,
      description: nil,
      runs: nil,
      tokens_in: nil,
      tokens_out: nil,
      cost_usd: nil
    ]
end
