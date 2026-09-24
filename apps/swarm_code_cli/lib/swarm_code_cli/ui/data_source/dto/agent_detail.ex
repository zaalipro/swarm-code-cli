defmodule SwarmCodeCLI.UI.DataSource.DTO.AgentDetail do
  @moduledoc """
  pass72 S: one agent's detail for the agent overlay (plan P8), fetched on
  demand with `{:agent_detail, run_id, node_id}`.

  `brief` is the task it was given (its prompt; `brief_bytes` the whole
  size), `needs_you` what it waits on (the approval's reason is "why it
  asks"), `findings` the numbered findings of its result (else `[]`, and
  `result` holds the result's head), `activity` its operations grouped oldest
  first, `operations` the raw ones (newest 200, oldest first), `life` its
  whole-life lane (≤ 120 buckets of `life_bucket_ms` from `life_started_at`;
  `think_ms` the time it spent thinking), the files it read, searched for and
  changed, tokens, the context it last sent against the model's working
  window, and its turn budget (`turn` of `max_turns`) when one is set.
  Neighbours in panel order are the client's (`PanelOrder`). `agent_error`
  is the agent's own failure; `state`/`error` are the request's (a failed
  request is `state: :error` with an `AdmissionError`, like every page).
  """
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      state: {:enum, [:idle, :error]},
      request_id: {:optional, :id},
      error: {:optional, :error},
      run_id: {:optional, :id},
      agent_id: {:optional, :id},
      name: {:text, 200},
      role: {:enum, [:lead, :sub, :worker, :assistant, :judge, :unknown]},
      model: {:optional, {:text, 200}},
      panel_state:
        {:enum,
         [:working, :thinking, :waiting, :needs_you, :done, :failed, :stopped, :queued, :paused]},
      now: {:text, 80},
      parent_name: {:optional, {:text, 200}},
      brief: {:text, 4096},
      brief_bytes: :count,
      needs_you: {:list, {:dto, SwarmCodeCLI.UI.DataSource.DTO.NeedsYou}},
      findings: {:list, {:dto, SwarmCodeCLI.UI.DataSource.DTO.Finding}},
      result: {:text, 8192},
      result_bytes: :count,
      agent_error: {:optional, {:text, 400}},
      activity: {:list, {:dto, SwarmCodeCLI.UI.DataSource.DTO.ActivityGroup}},
      operations: {:list, {:dto, SwarmCodeCLI.UI.DataSource.DTO.OpLine}},
      life: {:list, {:enum, [:think, :tools, :write, :wait_you, :idle]}},
      life_started_at: {:optional, :count},
      life_bucket_ms: :count,
      think_ms: :count,
      files_read: {:list, {:text, 200}},
      files_searched: {:list, {:text, 200}},
      files_changed: {:list, {:text, 200}},
      changes_stat: {:optional, {:text, 200}},
      tokens_in: :count,
      tokens_out: :count,
      cost_usd: {:optional, :float},
      context_used: {:optional, :count},
      context_window: {:optional, :count},
      turn: {:optional, :count},
      max_turns: {:optional, :count},
      started_at: {:optional, :count},
      finished_at: {:optional, :count}
    ],
    defaults: [
      state: :idle,
      request_id: nil,
      error: nil,
      run_id: nil,
      agent_id: nil,
      name: "",
      role: :unknown,
      model: nil,
      panel_state: :working,
      now: "",
      parent_name: nil,
      brief: "",
      brief_bytes: 0,
      needs_you: [],
      findings: [],
      result: "",
      result_bytes: 0,
      agent_error: nil,
      activity: [],
      operations: [],
      life: [],
      life_started_at: nil,
      life_bucket_ms: 0,
      think_ms: 0,
      files_read: [],
      files_searched: [],
      files_changed: [],
      changes_stat: nil,
      tokens_in: 0,
      tokens_out: 0,
      cost_usd: nil,
      context_used: nil,
      context_window: nil,
      turn: nil,
      max_turns: nil,
      started_at: nil,
      finished_at: nil
    ]
end
