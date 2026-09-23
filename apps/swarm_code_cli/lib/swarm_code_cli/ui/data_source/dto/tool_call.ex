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
      files: [],
      added: nil,
      removed: nil,
      diff_ref: nil,
      exit_code: nil,
      background: false,
      hunk: nil,
      diff_lines: 0
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
      files: {:list, {:text, 1024}},
      # pass70 C1: lines an edit added and removed, the op's unified diff on
      # demand (`detail` with `diff_ref.id`, `"<node_id>:diff"`), a shell
      # command's exit code, and whether it was handed to the background.
      added: {:optional, :count},
      removed: {:optional, :count},
      diff_ref: {:optional, {:dto, SwarmCodeCLI.UI.DataSource.DTO.DetailRef}},
      exit_code: {:optional, :count},
      background: :boolean,
      # pass71 F5: an edit's first hunk (from its first `@@`, at most 13 lines)
      # and the body lines of its whole diff, for the inline preview (R5).
      hunk: {:optional, {:text, 4096}},
      diff_lines: :count
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
      files: [],
      added: nil,
      removed: nil,
      diff_ref: nil,
      exit_code: nil,
      background: false,
      hunk: nil,
      diff_lines: 0
    ]
end
