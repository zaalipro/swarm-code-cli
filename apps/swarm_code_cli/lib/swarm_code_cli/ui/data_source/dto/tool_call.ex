defmodule SwarmCodeCLI.UI.DataSource.DTO.ToolCall do
  @moduledoc "Bounded, closed tool call facts carried by a `:tool` transcript item."
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    wire_defaults: [
      title: "",
      detail: "",
      status: "done",
      started_at: nil,
      finished_at: nil,
      duration_ms: nil,
      result_bytes: 0,
      files: []
    ],
    fields: [
      name: {:text, 200},
      title: {:text, 200},
      detail: {:text, 200},
      status:
        {:enum,
         [
           :queued,
           :running,
           :streaming,
           :waiting_question,
           :waiting_approval,
           :paused,
           :retrying,
           :done,
           :failed,
           :stopped,
           :interrupted,
           :superseded
         ]},
      started_at: {:optional, :count},
      finished_at: {:optional, :count},
      duration_ms: {:optional, :count},
      result_bytes: :count,
      files: {:list, {:text, 1024}}
    ],
    defaults: [
      name: "",
      title: "",
      detail: "",
      status: :done,
      started_at: nil,
      finished_at: nil,
      duration_ms: nil,
      result_bytes: 0,
      files: []
    ]
end
