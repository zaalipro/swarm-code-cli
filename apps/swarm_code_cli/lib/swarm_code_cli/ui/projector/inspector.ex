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
      if run && run.kind == :research,
        do: [Support.chrome(:research_depth), Support.chrome(:representative_only)],
        else: []

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
