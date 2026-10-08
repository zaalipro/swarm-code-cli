defmodule SwarmCodeCLI.UI.DataSource.DTO.ModelSpeed do
  @moduledoc """
  cli021 C2: the output speed of one model slot of the shown conversation, from
  the synced engine's speed monitor (`Domain.LLM.Speed`, the desktop's sidebar
  speed rows).

  `slot` is the role the model runs in (`main` the chat or orchestrator model,
  `worker` the swarm workers, `validator` the mission checker) or `other` for a
  model the conversation's runs used outside those slots. `tps` is the newest
  output tokens per second and nil while nothing was measured yet (an idle
  model); `live` says it is the estimate of a call still streaming, `ttft_ms`
  the first-token wait of that call and `at` the unix-millisecond instant of
  the exact measurement (nil for an estimate). `history` holds the exact
  rates of the most recent finished calls, oldest first, at most 12, for a
  sparkline.
  """
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      slot: {:enum, [:main, :worker, :validator, :other]},
      model: {:text, 256},
      tps: {:optional, :count},
      live: :boolean,
      ttft_ms: {:optional, :count},
      at: {:optional, :count},
      history: {:list, :count, 12}
    ],
    defaults: [
      slot: :main,
      model: "",
      tps: nil,
      live: false,
      ttft_ms: nil,
      at: nil,
      history: []
    ]
end
