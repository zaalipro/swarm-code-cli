defmodule SwarmCodeCLI.UI.Projector.Inspector.Hive do
  @moduledoc """
  The hive: one lane per agent of a run, and the agent cells every run row draws.

  A lane is one line — `⬢ lead     planning           ▬▬▬▬▭▭  1.8k` — the
  agent's glyph and name in its lane colour, its current step, a six-cell gauge
  of its progress and its tokens. The whole line is one action that opens the
  run's agents in the run inspector overlay, which is where the agent can be
  stopped. The runs dashboard and the run palette draw the same agents as a
  strip of cells (`⬢⬢⬢⬡`) through `cells/4`, so a run reads the same at every
  zoom level.

  A run the daemon reports no agents for is still one agent — the assistant
  answering it — so the hive draws a single lane from the run summary rather
  than an empty panel.
  """
  alias SwarmCodeCLI.UI.{SafeText, Theme, Width}
  alias SwarmCodeCLI.UI.DataSource.DTO
  alias SwarmCodeCLI.UI.Scene.{Block, Span}
  alias SwarmCodeCLI.UI.Projector.{Density, RunRow, Support}
  alias SwarmCodeCLI.UI.Projector.Inspector.Words

  @gauge_cells 6
  @tokens_width 5
  @min_name 4
  @max_name 12
  @min_step 8
  # The step keeps at least this when a lane also offers `stop`, so "waiting
  # for you" is never cut; the tokens column yields first.
  @min_step_with_stop 15
  @max_cells 12
  @more_width 3
  @lane_roles 5
  # The deck's two-cell separator and the word.
  @stop_label "stop"
  @stop_cost 6

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
      progress: Map.get(run, :progress) || 0,
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

  # ------------------------------------------------------------------- panel

  @doc """
  The HIVE panel: a header, the summary line, one lane per agent, then what is
  waiting on you and how many files changed while there is room — never a
  zero. Every row is budgeted to `width` and the list stops at `height` rows.

  `stop?: false` withholds the per-lane stop action (compressed classes).
  """
  def panel(state, run, width, height, opts \\ [])

  def panel(state, nil, width, height, _opts) do
    [
      heading("HIVE", "", state, width),
      Support.text("No run selected", state, width),
      blank(state),
      Support.text("Ctrl-G  all runs", state, width),
      Support.text("Ctrl-R  switch run", state, width)
    ]
    |> Enum.take(max(0, height))
  end

  def panel(state, run, width, height, opts) do
    lanes = lanes_for(state, run)

    header = [
      heading("HIVE", run.title, state, width),
      summary(run, lanes, state, width),
      blank(state)
    ]

    footer =
      case footer(run, state, width) do
        [] -> []
        lines -> [blank(state) | lines]
      end

    lane_rows = max(0, height - length(header))
    rows = lanes(state, run, lanes, width, lane_rows, opts)

    rows =
      if lane_rows - length(rows) >= length(footer),
        do: rows ++ footer,
        else: rows

    Enum.take(header ++ rows, max(0, height))
  end

  @doc """
  The lane rows alone, at most `height` of them. Each lane is one action that
  opens the run's agents; an agent that may be stopped gets a `stop` action
  packed on the same row, and a child of a superseded turn says so on the row
  beneath it, in the catalogue's exact words.
  """
  def lanes(state, run, agents, width, height, opts \\ []) do
    stop? = Keyword.get(opts, :stop?, true)

    stops =
      Map.new(agents, fn agent ->
        {agent.id, stop? and Support.allowed?(state, agent, :stop_agent)}
      end)

    any_stop? = Enum.any?(Map.values(stops))
    lane_width = if any_stop?, do: max(0, width - @stop_cost), else: width

    name_width =
      agents
      |> Enum.map(&measure(name(&1), state))
      |> Enum.max(fn -> @min_name end)
      |> max(@min_name)
      |> min(@max_name)

    # One rule for the whole panel, so the columns line up lane to lane.
    tokens? =
      not any_stop? or
        lane_width - (2 + name_width + 1) - (2 + @gauge_cells) - (1 + @tokens_width) >=
          @min_step_with_stop

    agents
    |> Enum.with_index()
    |> Enum.flat_map(fn {agent, index} ->
      spans = lane(agent, index, state, lane_width, name_width, tokens?: tokens?)

      action =
        Support.action_spans(
          spans,
          {:local, {:open_layer, {:run_inspector, run.id, :agents}}}
        )

      row =
        if Map.get(stops, agent.id),
          do: %Block.ActionDeck{actions: [action, stop(agent, state)]},
          else: action

      child =
        if Map.get(agent, :launched_by_superseded, false),
          do: [Support.text(SafeText.chrome(:superseded_child), state, width)],
          else: []

      [row | child]
    end)
    |> Enum.take(max(0, height))
  end

  defp stop(agent, state) do
    Support.action(
      Density.safe(@stop_label, state, measure(@stop_label, state)),
      {:intent, {:stop_agent, agent.run_id, agent.id, agent.revision}},
      Theme.style(:text_muted, state.capabilities)
    )
  end

  @doc "The styled spans of one lane, exactly `width` cells or fewer."
  def lane(agent, index, state, width, name_width, opts \\ []) do
    role = lane_role(agent, index)
    lane_style = %{RunRow.tinted(role, state) | modifiers: [:bold]}
    glyph = Support.glyph(glyph_token(agent), state)

    fixed = measure(SafeText.value(glyph), state) + 1 + name_width + 1
    tokens_extra = 1 + @tokens_width
    gauge_extra = 2 + @gauge_cells

    {gauge?, tokens?, step_width} =
      cond do
        Keyword.get(opts, :tokens?, true) and
            width - fixed - gauge_extra - tokens_extra >= @min_step ->
          {true, true, width - fixed - gauge_extra - tokens_extra}

        width - fixed - gauge_extra >= @min_step ->
          {true, false, width - fixed - gauge_extra}

        true ->
          {false, false, max(0, width - fixed)}
      end

    [
      %Span{text: glyph, style: lane_style},
      RunRow.gap(1, state),
      %Span{text: fit(name(agent), name_width, state), style: lane_style},
      RunRow.gap(1, state),
      %Span{text: fit(step(agent), step_width, state), style: step_style(agent, state)}
    ] ++
      if(gauge?, do: gauge(agent, role, state), else: []) ++
      if(tokens?, do: tokens(agent, state), else: [])
  end

  defp step_style(agent, state) do
    cond do
      Words.waiting?(agent.state) -> RunRow.tinted(:warning, state)
      agent.state == :failed -> RunRow.tinted(:error, state)
      Words.finished?(agent.state) -> Theme.style(:text_faint, state.capabilities)
      true -> Theme.style(:text_muted, state.capabilities)
    end
  end

  # Six cells: the lit run in the lane colour, the rest on the muted track.
  defp gauge(agent, role, state) do
    progress = agent.progress || 0
    lit = (progress / 100 * @gauge_cells) |> round() |> max(0) |> min(@gauge_cells)
    on = SafeText.value(Support.glyph(:gauge_on, state))
    off = SafeText.value(Support.glyph(:gauge_off, state))

    [
      RunRow.gap(2, state),
      %Span{
        text: Density.safe(String.duplicate(on, lit), state, lit),
        style: RunRow.tinted(role, state)
      },
      %Span{
        text: Density.safe(String.duplicate(off, @gauge_cells - lit), state, @gauge_cells - lit),
        style: RunRow.tinted(:ticks_track, state)
      }
    ]
  end

  # Blank rather than "0k": a zero is never shown.
  defp tokens(agent, state) do
    text =
      case agent.tokens_in + agent.tokens_out do
        0 -> ""
        total -> Words.tokens(total)
      end

    [
      RunRow.gap(1, state),
      %Span{
        text: Density.safe(RunRow.pad_leading(text, @tokens_width, state), state, @tokens_width),
        style: Theme.style(:text_faint, state.capabilities)
      }
    ]
  end

  # `HIVE  <title>`: the label in the accent, the title bold, elided to fit.
  defp heading(label, title, state, width) do
    label_width = measure(label, state)
    title_width = max(0, width - label_width - 2)

    %Block.RichText{
      spans: [
        %Span{
          text: Density.safe(label, state, label_width),
          style: %{RunRow.tinted(:accent, state) | modifiers: [:bold]}
        },
        RunRow.gap(min(2, max(0, width - label_width)), state),
        %Span{
          text: Density.safe(title, state, title_width),
          style: %{Theme.style(:text_primary, state.capabilities) | modifiers: [:bold]}
        }
      ]
    }
  end

  # `5 agents · 04:59 · 22.9k tokens`, leaving out what the read model lacks.
  defp summary(run, lanes, state, width) do
    count = max(total(run, state), length(lanes))
    elapsed = Words.elapsed(run.started_at, Words.until(run, state))

    tokens =
      case run.tokens_in + run.tokens_out do
        0 -> Enum.reduce(lanes, 0, &(&1.tokens_in + &1.tokens_out + &2))
        n -> n
      end

    parts =
      [Words.count(count, "agent", "agents"), elapsed] ++
        if(tokens > 0, do: [Words.tokens(tokens) <> " tokens"], else: [])

    text = parts |> Enum.reject(&is_nil/1) |> Enum.join(" · ")

    %Block.RichText{
      spans: [
        %Span{
          text: Density.safe(text, state, width),
          style: Theme.style(:text_faint, state.capabilities)
        }
      ]
    }
  end

  defp footer(run, state, width) do
    # The run summary counts what waits on you even when the interactions
    # themselves have not reached the read model yet.
    pending =
      state.read_model.interactions
      |> Map.values()
      |> Enum.count(&(&1.state == :pending and &1.run_id == run.id))
      |> max(Map.get(run, :needs, 0))

    files =
      state.read_model.changes
      |> Map.values()
      |> Enum.filter(&(&1.run_id == run.id))
      |> Enum.map(& &1.path)
      |> Enum.uniq()
      |> length()
      |> max(Map.get(run, :changes, 0))

    waiting =
      if pending > 0,
        do: [
          %Block.RichText{
            spans: [
              %Span{
                text: Density.safe("WAITING FOR YOU · #{pending}", state, width),
                style: %{RunRow.tinted(:warning, state) | modifiers: [:bold]}
              }
            ]
          }
        ],
        else: []

    changes =
      if files > 0,
        do: [
          %Block.RichText{
            spans: [
              %Span{
                text:
                  Density.safe("CHANGES · " <> Words.count(files, "file", "files"), state, width),
                style: %{Theme.style(:text_faint, state.capabilities) | modifiers: [:bold]}
              }
            ]
          }
        ],
        else: []

    waiting ++ changes
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

  defp cell_role(agent, live_role) do
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
