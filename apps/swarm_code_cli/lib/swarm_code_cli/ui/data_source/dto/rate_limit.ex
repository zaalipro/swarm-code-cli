defmodule SwarmCodeCLI.UI.DataSource.DTO.RateLimit do
  @moduledoc """
  pass70 C1: a provider's rate-limit window as its last response reported it
  (`used_percent` of the busiest scope, when it `resets_at`), and `retry_at`
  while a request waits out a 429. Times are unix milliseconds. One per
  provider; the delta's `entity_id` is `provider_id`.
  """
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      provider_id: :id,
      provider: {:text, 200},
      scope: {:text, 64},
      used_percent: :float,
      resets_at: {:optional, :count},
      retry_at: {:optional, :count},
      revision: :revision
    ],
    defaults: [
      provider_id: nil,
      provider: "",
      scope: "",
      used_percent: 0.0,
      resets_at: nil,
      retry_at: nil,
      revision: 0
    ]
end
