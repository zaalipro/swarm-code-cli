defmodule SwarmCodeCLI.UI.DataSource.DTO.BackgroundCommand do
  @moduledoc """
  pass70 C1: a shell command a run left running in the background (a
  `run_command` past its `yield_ms`). `id` is stable per process; `pid` is the
  OS pid the model polls or stops; times are unix milliseconds.
  """
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      id: :id,
      run_id: :id,
      agent_id: {:optional, :id},
      pid: {:optional, :count},
      command: {:text, 512},
      cwd: {:optional, {:text, 1024}},
      state: {:enum, [:running, :exited, :killed, :unknown]},
      exit_code: {:optional, :count},
      started_at: {:optional, :count},
      output_bytes: :count,
      revision: :revision
    ],
    defaults: [
      id: nil,
      run_id: nil,
      agent_id: nil,
      pid: nil,
      command: "",
      cwd: nil,
      state: :running,
      exit_code: nil,
      started_at: nil,
      output_bytes: 0,
      revision: 0
    ]
end
