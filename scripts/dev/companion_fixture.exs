# Writes the companion page's fixtures from the real view builder, so the
# page's `?fixture=1` preview and the live view can never drift apart.
#
#   cd apps/swarm_code_cli && mise exec -- mix run ../../scripts/dev/companion_fixture.exs
#
# `fixture.json` is the representative swarm session (named agents, tool
# calls, changes, a verdict, one approval waiting); `fixture-empty.json` is a
# freshly initialised session with nothing in it.
alias SwarmCodeCLI.Companion.View
alias SwarmCodeCLI.UI.{Capabilities, Fixtures, Init, Reducer, Size}

size = %Size{columns: 170, rows: 40}
caps = %Capabilities{size: size, color_mode: :truecolor}
# The fixtures' own clock, five minutes after the representative run started.
now = 1_788_436_800_000

dir = Path.join([File.cwd!(), "priv", "companion"])

write = fn name, view ->
  path = Path.join(dir, name)
  File.write!(path, Jason.encode!(view, pretty: true) <> "\n")
  IO.puts("wrote #{path}")
end

alias SwarmCodeCLI.UI.DataSource.DTO
alias SwarmCodeCLI.UI.Projector.Support

swarm = :swarm |> Fixtures.representative(size, caps) |> Map.put(:now, now)
run = Support.run(swarm)

# The swarm fixture has agents, tool calls and changes; the consensus one has
# the verdict. The page should show all of it at once, so the verdict is
# borrowed and re-keyed to the swarm run, and one approval is left waiting.
verdict =
  :consensus
  |> Fixtures.representative(size, caps)
  |> Map.fetch!(:read_model)
  |> Map.fetch!(:verdicts)
  |> Map.values()
  |> hd()
  |> Map.put(:run_id, run.id)

approval = %DTO.PendingInteraction{
  id: "approval-1",
  run_id: run.id,
  node_id: "agent-4",
  conversation_id: run.conversation_id,
  kind: :approval,
  expected_revision: run.revision,
  approval: %DTO.Approval{
    tool: "run_command",
    permission: :execute,
    arguments_preview: "mix test test/swarm_code/repo_test.exs"
  },
  allowed_actions: [:approve, :deny, :always_allow]
}

swarm =
  swarm
  |> put_in([Access.key(:read_model), Access.key(:verdicts)], %{verdict.id => verdict})
  |> put_in([Access.key(:read_model), Access.key(:interactions)], %{approval.id => approval})

rich = View.build(swarm, now, project: "swarm-code-cli", started_at: now - 300_000)

{empty_state, _effects} =
  Reducer.init(%Init{size: size, capabilities: caps, source_epoch: "fixture", now: now})

empty = View.build(empty_state, now, project: "swarm-code-cli", started_at: now)

write.("fixture.json", rich)
write.("fixture-empty.json", empty)

IO.puts(
  "rich: #{length(rich.agents)} agents, #{length(rich.transcript)} items, " <>
    "#{length(rich.changes.files)} changes, verdict=#{inspect(rich.verdict != nil)}, " <>
    "needs=#{length(rich.needs)}, tabs=#{length(rich.tabs)}"
)
