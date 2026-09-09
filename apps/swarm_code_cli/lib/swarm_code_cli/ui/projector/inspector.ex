defmodule SwarmCodeCLI.UI.Projector.Inspector do
  @moduledoc false
  alias SwarmCodeCLI.UI.{SafeText, Theme}
  alias SwarmCodeCLI.UI.Scene.{Block, Span}
  alias SwarmCodeCLI.UI.Projector.{Density, Support}

  def project(state, rect, class) do
    run = Support.run(state)

    agents =
      state.read_model.agents
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.filter(fn {_, a} -> not is_nil(run) and a.run_id == run.id end)

    visible = Enum.take(agents, max(0, div(rect.height - 3, 3)))

    rows =
      visible
      |> Enum.with_index()
      |> Enum.map(fn {{_, agent}, index} -> agent(state, agent, index, rect.width, class) end)

    metadata =
      cond do
        run && run.kind == :research ->
          [Support.chrome(:research_depth), Support.chrome(:representative_only)]

        run && run.kind == :goal ->
          [
            Support.styled("GOAL", :run_goal, state, rect.width),
            Support.text("Checklist facts are shown in the workspace.", state, rect.width)
          ]

        run && run.kind == :consensus ->
          [
            Support.styled("REVIEW BOARD", :run_consensus_judge, state, rect.width),
            Support.text("Plan ↔ changes", state, rect.width),
            Support.text("Use o for full text", state, rect.width)
          ]

        run && run.kind == :ultra ->
          [
            Support.styled("PIPELINE", :run_ultra, state, rect.width),
            Support.text("Plan → Build → Verify", state, rect.width),
            Support.text("Stage details appear as they arrive.", state, rect.width)
          ]

        run && run.kind == :workflow ->
          [
            Support.styled("WORKFLOW", :run_workflow, state, rect.width),
            Support.text("Inputs and stages", state, rect.width),
            Support.text("Open Ctrl-K Features to run another.", state, rect.width)
          ]

        run && run.kind == :research ->
          [
            Support.styled("RESEARCH", :run_research, state, rect.width),
            Support.text("Report + sources", state, rect.width)
          ]

        true ->
          []
      end

    metadata ++ [%Block.AgentList{agents: rows}]
  end

  def agent(state, agent, index, width, class) do
    {lane, _} = Theme.agent_lane(rem(index, 5) + 1)
    {status, role} = Theme.status(agent.state)
    label = SafeText.value(lane) <> " Agent " <> agent.id <> " · " <> SafeText.value(status)

    style =
      Theme.style(
        if(agent.launched_by_superseded, do: :text_muted, else: role),
        state.capabilities
      )

    # The caption already spells out the status, including in monochrome.
    caption = %Block.RichText{
      spans: [
        %Span{
          text: Density.safe(label, state, width),
          style: %{style | role: :plain, prefix: nil}
        }
      ]
    }

    child =
      if agent.launched_by_superseded,
        do: [Support.text(SafeText.chrome(:superseded_child), state, width)],
        else: []

    stop =
      if class not in [:compressed_small, :too_small] and
           Support.allowed?(state, agent, :stop_agent),
         do: [
           Support.action(
             SafeText.chrome(:stop),
             {:intent, {:stop_agent, agent.run_id, agent.id, agent.revision}}
           )
         ],
         else: []

    %Block.ActionDeck{actions: [caption] ++ child ++ stop}
  end
end
