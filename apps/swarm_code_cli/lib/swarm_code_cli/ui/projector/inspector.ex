defmodule SwarmCodeCLI.UI.Projector.Inspector do
  @moduledoc false
  # The palette chord comes from the binding table at compile time, so a
  # rebind re-spells this text.
  @palette_key SwarmCodeCLI.UI.Projector.KeyLabel.primary(
                 SwarmCodeCLI.UI.Keymap.Bindings.fetch(:command_palette)
               )
  alias SwarmCodeCLI.UI.{SafeText, Theme}
  alias SwarmCodeCLI.UI.Scene.{Block, Span}
  alias SwarmCodeCLI.UI.Projector.{Density, RunRow, Support}

  def project(state, rect, class) do
    run = Support.run(state)

    agents =
      state.read_model.agents
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.filter(fn {_, a} -> not is_nil(run) and a.run_id == run.id end)

    # Heading consumes 1 row; adjust visible agent count accordingly.
    # Previous formula: div(rect.height - 3, 3). Now subtract 1 more for the heading row.
    visible = Enum.take(agents, max(0, div(rect.height - 4, 3)))

    rows =
      visible
      |> Enum.with_index()
      |> Enum.map(fn {{_, agent}, index} -> agent(state, agent, index, rect.width, class) end)

    kind = if(run, do: run.kind)
    heading = [heading_block(kind, state, rect.width)]

    agents_card = agents_card(agents, kind, state, rect.width)
    needs_card = needs_card(run, state, rect.width)

    metadata =
      cond do
        run && run.kind == :research ->
          [Support.chrome(:research_depth), Support.chrome(:representative_only)]

        run && run.kind == :goal ->
          [Support.text("Checklist facts are shown in the workspace.", state, rect.width)]

        run && run.kind == :consensus ->
          [
            Support.text("Plan ↔ changes", state, rect.width),
            Support.text("Use o for full text", state, rect.width)
          ]

        run && run.kind == :ultra ->
          [
            pipeline_text(state, rect.width),
            Support.text("Stage details appear as they arrive.", state, rect.width)
          ]

        run && run.kind == :workflow ->
          [
            Support.text("Inputs and stages", state, rect.width),
            Support.text(
              "Open " <> @palette_key <> " Features to run another.",
              state,
              rect.width
            )
          ]

        true ->
          []
      end

    facts = run_facts(run, agents, state, rect.width)

    heading ++ agents_card ++ metadata ++ facts ++ needs_card ++ [%Block.AgentList{agents: rows}]
  end

  # Faint bold uppercase heading per run kind (decision 8, 27).
  # For swarm, the heading IS "AGENTS", so the agents_card omits the repeated label (decision 32).
  defp heading_block(:research, state, width),
    do: Support.section_heading("RESEARCH", state, width)

  defp heading_block(:goal, state, width),
    do: Support.section_heading("GOAL", state, width)

  defp heading_block(:consensus, state, width),
    do: Support.section_heading("REVIEW BOARD", state, width)

  defp heading_block(:ultra, state, width),
    do: Support.section_heading("PIPELINE", state, width)

  defp heading_block(:workflow, state, width),
    do: Support.section_heading("WORKFLOW", state, width)

  defp heading_block(:swarm, state, width),
    do: Support.section_heading(SafeText.chrome(:agents_label), state, width)

  defp heading_block(_kind, state, width),
    do: Support.section_heading(SafeText.chrome(:live_run_label), state, width)

  # AGENTS card: only when at least one agent exists (decision 30).
  # When the heading already says AGENTS (swarm), skip the repeated label (decision 32).
  defp agents_card(agents, _kind, _state, _width) when agents == [], do: []

  defp agents_card(agents, kind, state, width) do
    active =
      Enum.count(agents, fn {_, a} -> a.state in [:running, :streaming] end)

    waiting =
      Enum.count(agents, fn {_, a} -> a.state in [:waiting_question, :waiting_approval] end)

    count_text = "#{active} active · #{waiting} waiting"

    if kind == :swarm do
      # Heading already says AGENTS — just show the counts line directly (decision 32)
      [Support.text(count_text, state, width)]
    else
      [
        Support.section_heading(SafeText.chrome(:agents_label), state, width),
        Support.text(count_text, state, width)
      ]
    end
  end

  # NEEDS card: only when pending interaction count > 0 (decision 30).
  defp needs_card(nil, _state, _width), do: []

  defp needs_card(run, state, width) do
    pending =
      state.read_model.interactions
      |> Map.values()
      |> Enum.count(fn i -> i.state == :pending and i.run_id == run.id end)

    if pending > 0 do
      [
        Support.section_heading("NEEDS", state, width),
        Support.text("#{pending} pending", state, width)
      ]
    else
      []
    end
  end

  # A run with no agents (an ordinary assistant turn) used to leave this pane
  # empty apart from its heading — a tall column of nothing. Show the facts the
  # read model actually holds, and nothing it does not.
  defp run_facts(nil, _agents, _state, _width), do: []
  defp run_facts(_run, agents, _state, _width) when agents != [], do: []

  defp run_facts(run, _agents, state, width) do
    {word, role} = Theme.status(run.state)

    progress =
      case run.progress do
        nil -> []
        value -> [Support.text("Progress · #{value}%", state, width)]
      end

    [
      status_line(word, role, state, width),
      Support.text("Kind · #{run.kind}", state, width)
    ] ++
      progress ++
      [
        Support.text(" ", state, width),
        Support.text("Ctrl-G  all runs", state, width),
        Support.text("Ctrl-R  switch run", state, width)
      ]
  end

  # The status roles carry a text prefix cue — :accent prints "RUNNING" — which
  # is how a colourless terminal still reads the state. Styling the status word
  # with its own role therefore prints the state twice ("RUNNING STREAMING").
  # Borrow the role's colour onto the cue-free :plain role, exactly as the runs
  # dashboard does for its kind marks, so the line reads as one word.
  defp status_line(word, role, state, width) do
    %Block.RichText{
      spans: [
        %Span{
          text: Density.safe(SafeText.value(word), state, width),
          style: %{RunRow.tinted(role, state) | modifiers: [:bold]}
        }
      ]
    }
  end

  # Ultra pipeline text with safe glyph (decision 29): "Plan ❯ Build ❯ Verify"
  defp pipeline_text(state, width) do
    arrow = SafeText.value(Support.glyph(:pipeline_arrow, state))
    Support.text("Plan #{arrow} Build #{arrow} Verify", state, width)
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
