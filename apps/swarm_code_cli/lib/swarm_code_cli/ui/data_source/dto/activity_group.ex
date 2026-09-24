defmodule SwarmCodeCLI.UI.DataSource.DTO.ActivityGroup do
  @moduledoc """
  pass72 S: consecutive operations of one kind folded into a line of the
  agent overlay's activity column ("read 5 files", "thought ×3" with its
  quoted thought, one command with its last output line, one edit). `said` is
  the agent's own words. `items` are the paths, patterns or commands, at most
  12; `count` how many operations the group folds.
  """
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      kind:
        {:enum,
         [:read, :search, :explore, :think, :said, :command, :edit, :web, :agents, :ask, :other]},
      title: {:text, 200},
      items: {:list, {:text, 200}},
      count: :count,
      started_at: :count,
      duration_ms: :count,
      quote: {:optional, {:text, 400}},
      state: {:enum, [:running, :waiting, :done, :failed]}
    ],
    defaults: [
      kind: :other,
      title: "",
      items: [],
      count: 0,
      started_at: 0,
      duration_ms: 0,
      quote: nil,
      state: :done
    ]
end
