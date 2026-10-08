defmodule SwarmCodeCLI.UI.DataSource.DTO.Vitals do
  @moduledoc """
  cli021 C2: the side panel's vitals, the body of the shell watch's `vitals`
  delta and the optional `vitals` of its snapshot.

  `models` lists the shown conversation's model slots with their output speed
  (`DTO.ModelSpeed`, at most 8). Memory: `beam_bytes` is the Erlang VM's total
  memory (the daemon and the terminal client run in one VM); `os_rss_bytes` is
  that VM's resident size as the OS reports it and `children_rss_bytes` the
  resident size of the processes it started (the terminal renderer, tool
  commands), both nil until the first reading; `machine_bytes` is the
  machine's memory, the scale a bar draws against (nil when unknown).
  `sampled_at` is a unix-millisecond instant. The daemon sends an update at most
  once a second, only while a client watches.
  """
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      conversation_id: {:optional, :id},
      models: {:list, {:dto, SwarmCodeCLI.UI.DataSource.DTO.ModelSpeed}, 8},
      beam_bytes: :count,
      os_rss_bytes: {:optional, :count},
      children_rss_bytes: {:optional, :count},
      machine_bytes: {:optional, :count},
      sampled_at: :count
    ],
    defaults: [
      conversation_id: nil,
      models: [],
      beam_bytes: 0,
      os_rss_bytes: nil,
      children_rss_bytes: nil,
      machine_bytes: nil,
      sampled_at: 0
    ]
end
