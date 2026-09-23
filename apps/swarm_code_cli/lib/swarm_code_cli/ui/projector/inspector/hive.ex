defmodule SwarmCodeCLI.UI.Projector.Inspector.Hive do
  @moduledoc """
  The agents of a run, and the agent cells every run row draws.

  The Agents tab (`Inspector.Agents`) draws the cards; this module holds what
  the cards and the rest of the screen share: the run's agents in lane order,
  the assistant standing in for a run that reports no agents, each agent's
  lane colour, glyph, name and step in plain words, the count of what waits on
  you, and the strip of cells (`⬢⬢⬢⬡`) the runs dashboard and the run palette
  draw through `cells/4`, so a run reads the same at every zoom level.
  """
  alias SwarmCodeCLI.UI.{SafeText, Theme, Width}
  alias SwarmCodeCLI.UI.DataSource.DTO
  alias SwarmCodeCLI.UI.Scene.{Block, Span}
  alias SwarmCodeCLI.UI.Projector.{Density, RunRow, Support}
  alias SwarmCodeCLI.UI.Projector.Inspector.Words

  @max_cells 12
  @more_width 3
  @lane_roles 5

  # ------------------------------------------------------------------ agents

  @doc """
  The run's agents in lane order: the lead first, then by depth, then by when
  they started, with the id breaking ties so a map's hash order never decides.
  """
  def agents(state, run_id) do
    state.read_model.agents
    |> Map.values()
    |> Enum.filter(&(&1.run_id == run_id))
    |> Enum.sort_by(
      &{if(&1.role == :lead, do: 0, else: 1), &1.depth, &1.started_at || :none, &1.id}
    )
  end

  @doc "The lanes to draw: the run's agents, or the assistant itself when there are none."
  def lanes_for(_state, nil), do: []

  def lanes_for(state, run) do
    case agents(state, run.id) do
      [] -> [assistant_lane(run)]
      agents -> agents
    end
  end

  # A chat or goal run has no agent node of its own; the run summary carries
  # everything the lane needs to say about the one assistant answering it.
  defp assistant_lane(run) do
    %DTO.AgentSummary{
      id: run.id,
      run_id: run.id,
      revision: run.revision,
      state: run.state,
      name: "assistant",
      role: :assistant,
      step: "",
      # `nil` stays `nil`: an unknown progress is never drawn as zero percent.
      progress: Map.get(run, :progress),
      tokens_in: run.tokens_in,
      tokens_out: run.tokens_out,
      cost_usd: run.cost_usd,
      started_at: run.started_at,
      finished_at: run.finished_at,
      error: run.error
    }
  end

  @doc "How many agents the run has: the summary's count, the read model's, or one."
  def total(run, state) do
    known = state.read_model.agents |> Map.values() |> Enum.count(&(&1.run_id == run.id))
    Enum.max([Map.get(run, :agents_total, 0), known, 1])
  end

  @doc "The catalogue glyph that marks an agent: judge, queued, or a filled cell."
  def glyph_token(%{role: :judge}), do: :judge
  def glyph_token(%{state: :queued}), do: :hex_empty
  def glyph_token(_agent), do: :hex_full

  @doc """
  The theme role a lane is drawn in: its index colour, unless the agent is
  waiting on you (warning), failed (error), the judge, or a child of a turn
  that has since been superseded (muted).
  """
  def lane_role(agent, index) do
    cond do
      Map.get(agent, :launched_by_superseded, false) -> :text_muted
      Words.waiting?(agent.state) -> :warning
      agent.state == :failed -> :error
      agent.role == :judge -> :run_consensus_judge
      true -> elem(Theme.agent_lane(rem(index, @lane_roles) + 1), 1)
    end
  end

  @doc "The agent's name, or its id when the daemon sent none."
  def name(%{name: name}) when is_binary(name) and name != "", do: name
  def name(%{id: id}) when is_binary(id), do: id
  def name(_agent), do: "agent"

  @doc "What the lane says the agent is doing, in plain words."
  def step(agent) do
    cond do
      Words.waiting?(agent.state) -> "waiting for you"
      agent.state == :failed -> agent.error || "failed"
      is_binary(agent.step) and agent.step != "" -> agent.step
      true -> Words.state(agent.state)
    end
  end

  @doc "The running agent that started most recently, or `nil`."
  def newest_running(agents) do
    agents
    |> Enum.filter(&Words.running?(&1.state))
    |> Enum.sort_by(&{-(&1.started_at || 0), &1.id})
    |> List.first()
  end

  @doc """
  What a run row says beside its cells: the newest running agent and its step
  when the read model has one, else the run's state in plain words.
  """
  def run_words(run, state) do
    agents = agents(state, run.id)

    cond do
      Words.waiting?(run.state) ->
        "waiting for you"

      Words.running?(run.state) ->
        case newest_running(agents) do
          %{step: step} = agent when is_binary(step) and step != "" ->
            name(agent) <> " " <> step

          _ ->
            case total(run, state) do
              1 -> Words.state(run.state)
              n -> "running · " <> Words.count(n, "agent", "agents")
            end
        end

      run.state == :failed ->
        if is_binary(run.error) and run.error != "",
          do: "failed · " <> run.error,
          else: "failed"

      run.state == :done ->
        case Map.get(run, :changes, 0) do
          0 -> "done"
          n -> "done · " <> Words.count(n, "file changed", "files changed")
        end

      true ->
        Words.state(run.state)
    end
  end

  # ---------------------------------------------------------------- waiting

  @doc """
  How many interactions of `run` wait on you. Counts the pending interactions
  in the read model, and never fewer than the run's own `needs`, since the run
  summary can arrive before the interactions themselves.
  """
  def pending(_state, nil), do: 0

  def pending(state, run) do
    state.read_model.interactions
    |> Map.values()
    |> Enum.count(&(&1.state == :pending and &1.run_id == run.id))
    |> max(Map.get(run, :needs, 0))
  end

  # ------------------------------------------------------------------- cells

  @doc """
  One cell per agent of a run, exactly `width` cells wide: `⬢` for an agent
  running or finished, `⬡` for one still queued, `⚖` for the judge, capped at
  twelve cells and then `+N`. Agents the read model does not hold are drawn
  from the summary's counts: the running ones lit, the rest queued, or all
  finished once the run is.
  """
  def cells(run, state, width, live_role) do
    known = agents(state, run.id)
    total = total(run, state)
    unknown = max(0, total - length(known))
    running_known = Enum.count(known, &Words.running?(&1.state))
    running_unknown = (Map.get(run, :agents_running, 0) - running_known) |> max(0) |> min(unknown)

    rest =
      if Words.finished?(run.state),
        do: {:hex_full, :text_muted},
        else: {:hex_empty, :ticks_track}

    entries =
      Enum.map(known, &{glyph_token(&1), cell_role(&1, live_role)}) ++
        List.duplicate({:hex_full, live_role}, running_unknown) ++
        List.duplicate(rest, unknown - running_unknown)

    cap =
      if width >= @max_cells + @more_width,
        do: @max_cells,
        else: max(0, width - @more_width)

    shown_count = if total <= min(width, @max_cells), do: total, else: cap
    shown = Enum.take(entries, shown_count)
    more = total - length(shown)

    glyphs =
      Enum.map(shown, fn {token, role} ->
        %Span{text: Support.glyph(token, state), style: RunRow.tinted(role, state)}
      end)

    used =
      Enum.reduce(shown, 0, fn {token, _}, acc ->
        acc + measure(SafeText.value(Support.glyph(token, state)), state)
      end)

    room = max(0, width - used)
    more_text = if more > 0, do: "+#{more}", else: ""

    glyphs ++
      [
        %Span{
          text: Density.safe(RunRow.pad(more_text, room, state), state, room),
          style: Theme.style(:text_faint, state.capabilities)
        }
      ]
  end

  @doc false
  def cell_role(agent, live_role) do
    cond do
      Words.waiting?(agent.state) -> :warning
      agent.state == :failed -> :error
      agent.role == :judge -> :run_consensus_judge
      agent.state == :queued -> :ticks_track
      agent.state == :done -> :text_muted
      Words.finished?(agent.state) -> :text_faint
      true -> live_role
    end
  end

  # ----------------------------------------------------------------- helpers

  @doc "A blank row: a single space, since an empty text carries no cells and is dropped."
  def blank(state), do: %Block.Text{text: Density.safe(" ", state, 1)}

  @doc "Elides `value` to `width` cells and pads it to exactly that width."
  def fit(value, width, state) do
    elided = value |> Density.safe(state, width) |> SafeText.value()
    Density.safe(RunRow.pad(elided, width, state), state, width)
  end

  @doc "Cells of `text` under the state's own width policy."
  def measure(text, state), do: Width.cells(text, state.capabilities.ambiguous_width)
end
