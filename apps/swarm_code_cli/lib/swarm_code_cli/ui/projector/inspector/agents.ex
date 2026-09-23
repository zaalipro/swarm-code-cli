defmodule SwarmCodeCLI.UI.Projector.Inspector.Agents do
  @moduledoc """
  The Agents tab, card for card after the web app's agent pane.

  The lead card first: who leads the run, its status pill, its model, how far
  the sub-agents are, the tools it has used, its current task with a smooth
  gauge, and its tokens. Then what waits on you, the verdict of a judged run,
  the sub-agents as a grid of mini cards (two columns from 46 cells; one row
  each when narrower or when there are many), and the operations drawer of the
  selected agent: the one you picked, else the newest running one, else the
  lead.

  Every section knows its own height, so a section that does not fit is left
  out whole, drawer first, rather than cut in the middle of a card.
  """
  alias SwarmCodeCLI.UI.{SafeText, Theme}
  alias SwarmCodeCLI.UI.Scene.{Block, Span}
  alias SwarmCodeCLI.UI.Projector.{Density, RunRow, Support}
  alias SwarmCodeCLI.UI.Projector.Inspector.{Hive, Ops, Verdict, Words}

  # Two mini-card columns need this many cells; above this many sub-agents the
  # grid becomes rows.
  @grid_min 46
  @grid_max 10
  @avatar 4
  @max_chips 3
  @card_edges 2
  @sub_card_inner 4
  @gauge_cells 6
  @tokens_width 5
  @min_step 15
  @drawer_min 3

  # ------------------------------------------------------------------- tab

  @doc "The tab's blocks for `run`, budgeted to `width` cells and `height` rows."
  def tab(state, nil, width, height, _opts) do
    [
      Support.text("No run selected", state, width),
      Hive.blank(state),
      Support.text("Ctrl-G  all runs", state, width),
      Support.text("Ctrl-R  switch run", state, width)
    ]
    |> Enum.take(max(0, height))
  end

  def tab(state, run, width, height, opts) do
    [lead | subs] = Hive.lanes_for(state, run)
    selected = selected(state, run, [lead | subs])

    {lead_blocks, lead_rows} = lead_card(state, run, lead, subs, width, height, opts)
    left = height - lead_rows

    {waiting, waiting_rows} = fit(waiting_card(state, run, width), left)
    left = left - waiting_rows

    {verdict, verdict_rows} = fit(Verdict.card(state, run, width), left)
    left = left - verdict_rows

    {subs_blocks, subs_rows} = sub_section(state, subs, width, left)
    left = left - subs_rows

    drawer = if left >= @drawer_min, do: drawer(state, selected, width, left), else: []

    lead_blocks ++ waiting ++ verdict ++ subs_blocks ++ drawer
  end

  # A one-row-per-block section is taken whole or not at all.
  defp fit(blocks, left) when length(blocks) <= left, do: {blocks, length(blocks)}
  defp fit(_blocks, _left), do: {[], 0}

  @doc "The agent whose operations the drawer shows."
  def selected(state, run, agents) do
    chosen = Map.get(state.tabs, :agent)

    Enum.find(agents, &(&1.id == chosen and &1.run_id == run.id)) ||
      Hive.newest_running(agents) || hd(agents)
  end

  # ------------------------------------------------------------- lead card

  # Ten rows inside the edges; the chips and the foot go first when the region
  # is short, so the head, the task and the gauge always survive.
  defp lead_card(state, run, lead, subs, width, height, opts) do
    inner = max(0, width - 2)
    role = Hive.lane_role(lead, 0)
    # An unknown progress invents no percentage: the gauge row is left out.
    progress = if is_integer(lead.progress), do: min(100, max(0, lead.progress)), else: nil

    head = head_row(state, run, lead, inner, opts)
    avatar = avatar_rows(state, run, lead, subs, role, inner)
    chips = chips_row(state, lead, inner)
    divider = divider(state, inner)

    task_head =
      two_sided(
        state,
        inner,
        faint_bold("Current task", state),
        percent(progress || 0, role, state)
      )

    gauge =
      if progress,
        do: [
          %Block.Gauge{
            tone: gauge_tone(lead, role),
            value: progress,
            maximum: 100,
            style: :smooth,
            gradient_to: gradient(lead)
          }
        ],
        else: []

    task = two_sided(state, inner, primary(Hive.step(lead), state), metric(lead, subs, state))
    foot = foot_row(state)
    core = [divider, task_head] ++ gauge ++ [task]

    rows =
      cond do
        height >= 6 + length(core) + @card_edges ->
          [head] ++ avatar ++ [chips] ++ core ++ [foot]

        height >= 5 + length(core) + @card_edges ->
          [head] ++ avatar ++ [chips] ++ core

        true ->
          [head] ++ avatar ++ core
      end

    {[%Block.Surface{blocks: rows, tone: :card, accent: role, edges: :half}],
     length(rows) + @card_edges}
  end

  # `AGENT` at the left, `stop` at the right when the agent may be stopped.
  defp head_row(state, run, lead, inner, opts) do
    label = faint_bold("Agent", state)

    if Keyword.get(opts, :stop?, true) and Support.allowed?(state, lead, :stop_agent) and
         lead.id != run.id do
      stop = "stop"
      stop_width = Hive.measure(stop, state)

      %Block.ActionDeck{
        actions: [
          %Block.RichText{spans: [pad_span(label, max(0, inner - 2 - stop_width), state)]},
          Support.action(
            Density.safe(stop, state, stop_width),
            {:intent, {:stop_agent, lead.run_id, lead.id, lead.revision}},
            Theme.style(:text_muted, state.capabilities)
          )
        ]
      }
    else
      %Block.RichText{spans: [label]}
    end
  end

  # Three rows: the avatar block on the hover surface with the glyph in the
  # middle row; the name and status, the subtitle, the run meta beside it.
  defp avatar_rows(state, run, lead, subs, role, inner) do
    caps = state.capabilities
    hover = Theme.style(:hover, caps).background
    block = %{RunRow.tinted(role, state) | background: hover, modifiers: [:bold]}
    glyph = SafeText.value(Support.glyph(avatar_token(lead), state))
    text_width = max(0, inner - @avatar - 1)

    blank_block = %Span{
      text: Density.safe(String.duplicate(" ", @avatar), state, @avatar),
      style: block
    }

    glyph_block = %Span{text: Density.safe(" " <> glyph <> "  ", state, @avatar), style: block}

    name = %Span{
      text: Density.safe(Hive.name(lead), state, max(1, text_width - 10)),
      style: %{RunRow.tinted(role, state) | modifiers: [:bold]}
    }

    {word, word_role} = status_word(lead)

    status = [
      %Span{text: Support.glyph(:dot, state), style: RunRow.tinted(word_role, state)},
      RunRow.gap(1, state),
      %Span{
        text: Density.safe(word, state, Hive.measure(word, state)),
        style: %{RunRow.tinted(word_role, state) | modifiers: [:bold]}
      }
    ]

    [
      %Block.RichText{
        spans:
          [blank_block, RunRow.gap(1, state)] ++
            two_sided_spans(state, text_width, [name], status)
      },
      %Block.RichText{
        spans: [
          glyph_block,
          RunRow.gap(1, state),
          faint(subtitle(run, lead, state), text_width, state)
        ]
      },
      %Block.RichText{
        spans: [
          blank_block,
          RunRow.gap(1, state),
          faint(run_meta(state, run, lead, subs, text_width), text_width, state)
        ]
      }
    ]
  end

  defp avatar_token(%{role: :assistant}), do: :assistant_mark
  defp avatar_token(%{role: :judge}), do: :judge
  defp avatar_token(%{role: :lead}), do: :agent_lead
  defp avatar_token(_agent), do: :agent_sub

  # `LEAD AGENT · kimi-k2-thinking`, `ASSISTANT · deepseek-v4-pro`, `JUDGE · ROUND 1`.
  defp subtitle(run, agent, state) do
    model = Map.get(run, :model)

    case agent.role do
      :assistant -> join(["Assistant", model])
      :judge -> join(["Judge", round_words(state, run)])
      :lead -> join(["Lead agent", model])
      _ -> join([agent.role |> Atom.to_string() |> String.capitalize(), model])
    end
  end

  defp round_words(state, run) do
    case Verdict.judged?(run) && Verdict.newest(state, run) do
      %{round: round} when round > 0 -> "round #{round}"
      _ -> nil
    end
  end

  # `1/4 sub-agents done · 14:05 · 22k tok`, dropping parts from the end
  # rather than eliding words.
  defp run_meta(state, run, lead, subs, width) do
    done = Enum.count(subs, &(&1.state == :done))

    # Never a zero: before any sub-agent is done the count is the plain total.
    subs_part =
      cond do
        subs == [] -> nil
        done > 0 -> "#{done}/#{length(subs)} sub-agents done"
        true -> Words.count(length(subs), "sub-agent", "sub-agents")
      end

    tokens = run_tokens(run, [lead | subs])

    parts =
      Enum.reject(
        [
          subs_part,
          Words.clock(run.started_at),
          if(tokens > 0, do: Words.tokens(tokens) <> " tok")
        ],
        &is_nil/1
      )

    shrink(parts, width, state)
  end

  defp run_tokens(run, agents) do
    case run.tokens_in + run.tokens_out do
      0 -> Enum.reduce(agents, 0, &(&1.tokens_in + &1.tokens_out + &2))
      n -> n
    end
  end

  defp shrink([], _width, _state), do: ""

  defp shrink(parts, width, state) do
    text = Enum.join(parts, " · ")

    if Hive.measure(text, state) <= width,
      do: text,
      else: shrink(Enum.drop(parts, -1), width, state)
  end

  # ` grep  read_file  +2 `, or `no tools yet` in the ghost colour.
  defp chips_row(state, lead, inner) do
    case Ops.tools(state, lead) do
      [] ->
        %Block.RichText{
          spans: [
            %Span{
              text: Density.safe("no tools yet", state, inner),
              style: Theme.style(:text_ghost, state.capabilities)
            }
          ]
        }

      tools ->
        shown = Enum.take(tools, @max_chips)
        more = length(tools) - length(shown)
        labels = shown ++ if(more > 0, do: ["+#{more}"], else: [])

        spans =
          labels
          |> Enum.map(&Support.chip(&1, :hover, state, Hive.measure(&1, state) + 2))
          |> Enum.intersperse(RunRow.gap(1, state))

        %Block.RichText{spans: clip_spans(spans, inner, state)}
    end
  end

  defp divider(state, inner) do
    dash = SafeText.value(Support.glyph(:dash_rule, state))

    %Block.RichText{
      spans: [
        %Span{
          text: Density.safe(String.duplicate(dash, inner), state, inner),
          style: RunRow.tinted(:ticks_track, state)
        }
      ]
    }
  end

  defp percent(0, _role, _state), do: []

  defp percent(progress, role, state) do
    text = Integer.to_string(progress) <> "%"

    [
      %Span{
        text: Density.safe(text, state, Hive.measure(text, state)),
        style: %{RunRow.tinted(role, state) | modifiers: [:bold]}
      }
    ]
  end

  # A running agent's gauge takes its lane colour and warms toward the accent;
  # a settled one takes its status colour, flat.
  defp gauge_tone(agent, role) do
    if Words.finished?(agent.state) or Words.waiting?(agent.state),
      do: Words.role(agent.state),
      else: role
  end

  defp gradient(agent) do
    if Words.finished?(agent.state) or Words.waiting?(agent.state), do: nil, else: :accent
  end

  # `lead 7.6k · subs 15k` beside the task, or `7.6k tokens`; nothing for zero.
  defp metric(lead, subs, state) do
    own = lead.tokens_in + lead.tokens_out
    others = Enum.reduce(subs, 0, &(&1.tokens_in + &1.tokens_out + &2))

    text =
      cond do
        subs != [] and own + others > 0 ->
          "lead #{Words.tokens(own)} · subs #{Words.tokens(others)}"

        own > 0 ->
          Words.tokens(own) <> " tokens"

        true ->
          nil
      end

    if text, do: [faint(text, Hive.measure(text, state), state)], else: []
  end

  defp foot_row(state) do
    lanes = SafeText.value(Support.glyph(:clock_mark, state)) <> " lanes"
    diff = SafeText.value(Support.glyph(:branch_mark, state)) <> " diff"
    style = Theme.style(:text_faint, state.capabilities)

    %Block.ActionDeck{
      actions: [
        Support.action(
          Density.safe(lanes, state, Hive.measure(lanes, state)),
          {:local, {:set_tab, :timeline}},
          style
        ),
        Support.action(
          Density.safe(diff, state, Hive.measure(diff, state)),
          {:local, {:set_tab, :changes}},
          style
        )
      ]
    }
  end

  # --------------------------------------------------------- waiting card

  # The first interaction of the run that waits on you, as a card whose head
  # row opens it: `? judge asks a question`, then the question or the command.
  defp waiting_card(state, run, width) do
    state.read_model.interactions
    |> Map.values()
    |> Enum.filter(&(&1.state == :pending and &1.run_id == run.id))
    |> Enum.sort_by(&{&1.created_at, &1.id})
    |> List.first()
    |> case do
      nil -> []
      item -> [waiting_surface(state, run, item, width)]
    end
  end

  defp waiting_surface(state, run, item, width) do
    inner = max(0, width - 2)

    agent =
      state.read_model.agents
      |> Map.values()
      |> Enum.find(
        &(&1.id == item.node_id or
            (&1.run_id == run.id and &1.state in [:waiting_question, :waiting_approval]))
      )

    who = if agent, do: Hive.name(agent), else: "the run"

    {verb, line, words} =
      case item do
        %{kind: :approval} ->
          facts = SwarmCodeCLI.UI.Projector.Composer.approval_facts(item)

          subject =
            cond do
              facts.command -> "$ " <> facts.command
              facts.path -> facts.path
              true -> facts.subject
            end

          {"wants to " <> approval_verb(facts), subject, "decide in the composer below"}

        %{question: %{prompt: prompt}} when is_binary(prompt) ->
          {"asks a question", prompt, "answer it to let the agent continue"}

        _ ->
          {"needs your permission", "", ""}
      end

    head =
      Support.action_spans(
        [
          %Span{
            text: Density.safe(if(item.kind == :approval, do: "!", else: "?"), state, 1),
            style: %{RunRow.tinted(:warning, state) | modifiers: [:bold]}
          },
          RunRow.gap(1, state),
          %Span{
            text: Density.safe(who, state, min(inner - 2, Hive.measure(who, state))),
            style: %{RunRow.tinted(:warning, state) | modifiers: [:bold]}
          },
          RunRow.gap(1, state),
          %Span{
            text: Density.safe(verb, state, max(0, inner - 3 - Hive.measure(who, state))),
            style: Theme.style(:text_primary, state.capabilities)
          }
        ],
        {:local, {:open_interaction, item.id}}
      )

    body = [
      %Block.RichText{
        spans: [
          %Span{
            text: Density.safe(line, state, inner),
            style: %{RunRow.tinted(:text_primary, state) | modifiers: [:bold]}
          }
        ]
      },
      %Block.RichText{spans: [faint(words, inner, state)]}
    ]

    %Block.Surface{
      blocks: [head | body],
      tone: :card,
      accent: :warning,
      rounded: true,
      edges: :corners
    }
  end

  defp approval_verb(%{tool: "run_command"}), do: "run a command"

  defp approval_verb(%{tool: tool}) when tool in ["edit_file", "write_file", "edit_files"],
    do: "change a file"

  defp approval_verb(%{tool: tool}) when is_binary(tool) and tool != "",
    do: "use " <> String.replace(tool, "_", " ")

  defp approval_verb(_), do: "do something that needs your permission"

  # --------------------------------------------------------- sub-agents

  defp sub_section(_state, [], _width, _left), do: {[], 0}

  defp sub_section(state, subs, width, left) do
    heading = [Hive.blank(state), sub_heading(state, subs, width)]
    grid? = width >= @grid_min and length(subs) <= @grid_max
    pairs = div(length(subs) + 1, 2)
    grid_rows = 2 + pairs * (@sub_card_inner + @card_edges)
    superseded = Enum.count(subs, &Map.get(&1, :launched_by_superseded, false))
    row_rows = 2 + length(subs) + superseded

    cond do
      grid? and left >= grid_rows + @drawer_min ->
        {heading ++ sub_cards(state, subs, width), grid_rows}

      left >= row_rows ->
        {heading ++ sub_rows(state, subs, width), row_rows}

      true ->
        {[], 0}
    end
  end

  # `SUB-AGENTS                 1 of 4 done · 1 waiting`
  defp sub_heading(state, subs, width) do
    done = Enum.count(subs, &(&1.state == :done))
    waiting = Enum.count(subs, &Words.waiting?(&1.state))
    failed = Enum.count(subs, &(&1.state == :failed))

    parts =
      Enum.reject(
        [
          if(done > 0, do: "#{done} of #{length(subs)} done"),
          if(waiting > 0, do: "#{waiting} waiting"),
          if(failed > 0, do: "#{failed} failed")
        ],
        &is_nil/1
      )

    text = shrink(parts, max(0, width - 12), state)

    two_sided(
      state,
      width,
      faint_bold("Sub-agents", state),
      if(text == "", do: [], else: [faint(text, Hive.measure(text, state), state)])
    )
  end

  # Two columns of mini cards, each four rows inside its edges.
  defp sub_cards(state, subs, width) do
    column = div(width - 1, 2)

    subs
    |> Enum.with_index(1)
    |> Enum.chunk_every(2)
    |> Enum.map(fn pair ->
      columns =
        Enum.map(pair, fn {agent, index} ->
          %{width: column, blocks: [sub_card(state, agent, index, column)]}
        end)

      %Block.Columns{columns: columns, gap: 1}
    end)
  end

  defp sub_card(state, agent, index, column) do
    inner = max(0, column - 2)
    role = Hive.lane_role(agent, index)
    progress = min(100, max(0, agent.progress || 0))
    tokens = agent.tokens_in + agent.tokens_out
    ops = length(Ops.items(state, agent))

    name =
      Support.action_spans(
        two_sided_spans(
          state,
          inner,
          [
            %Span{
              text: Support.glyph(sub_token(agent), state),
              style: %{RunRow.tinted(role, state) | modifiers: [:bold]}
            },
            RunRow.gap(1, state),
            %Span{
              text: Density.safe(Hive.name(agent), state, max(1, inner - 4)),
              style: %{RunRow.tinted(role, state) | modifiers: [:bold]}
            }
          ],
          [mark(agent, role, state)]
        ),
        {:local, {:select_agent, agent.id}}
      )

    depth = if is_integer(agent.depth) and agent.depth > 1, do: "depth #{agent.depth}"
    kind = join([sub_word(agent), depth, flag(agent)])

    metrics =
      two_sided(
        state,
        inner,
        if(tokens > 0, do: [faint(Words.tokens(tokens) <> " tok", inner, state)], else: []),
        if(ops > 0, do: [faint(Words.count(ops, "op", "ops"), inner, state)], else: [])
      )

    # A child of a superseded turn says so in the catalogue's exact words, in
    # place of its metrics.
    last =
      if Map.get(agent, :launched_by_superseded, false),
        do: %Block.RichText{
          spans: [
            %Span{
              text:
                Density.safe(SafeText.value(SafeText.chrome(:superseded_child)), state, inner),
              style: Theme.style(:text_muted, state.capabilities)
            }
          ]
        },
        else: metrics

    %Block.Surface{
      blocks: [
        name,
        %Block.RichText{spans: [faint(kind, inner, state)]},
        %Block.Gauge{
          tone: gauge_tone(agent, role),
          value: progress,
          maximum: 100,
          style: :smooth
        },
        last
      ],
      tone: :card,
      accent: role,
      rounded: true,
      edges: :corners
    }
  end

  # One row per sub-agent: `› ✦ scout-1   grep "Repo\."   ▐▐▐▐▐▐  3.8k`.
  defp sub_rows(state, subs, width) do
    name_width =
      subs
      |> Enum.map(&Hive.measure(Hive.name(&1), state))
      |> Enum.max(fn -> 4 end)
      |> max(4)
      |> min(12)

    subs
    |> Enum.with_index(1)
    |> Enum.map(fn {agent, index} ->
      role = Hive.lane_role(agent, index)
      tokens = agent.tokens_in + agent.tokens_out
      fixed = 2 + 2 + name_width + 1
      # "waiting for you" is never cut: the tokens column yields first.
      with_tokens = width - fixed - (1 + @gauge_cells) - (1 + @tokens_width)
      tokens? = with_tokens >= @min_step

      step_width =
        max(0, if(tokens?, do: with_tokens, else: width - fixed - (1 + @gauge_cells)))

      spans =
        [
          %Span{
            text: Support.glyph(:chevron, state),
            style: Theme.style(:text_faint, state.capabilities)
          },
          RunRow.gap(1, state),
          %Span{
            text: Support.glyph(sub_token(agent), state),
            style: %{RunRow.tinted(role, state) | modifiers: [:bold]}
          },
          RunRow.gap(1, state),
          %Span{
            text: Hive.fit(Hive.name(agent), name_width, state),
            style: %{RunRow.tinted(role, state) | modifiers: [:bold]}
          },
          RunRow.gap(1, state),
          %Span{
            text: Hive.fit(Hive.step(agent), step_width, state),
            style: step_style(agent, state)
          }
        ] ++
          ticks(agent, role, state) ++
          if tokens?,
            do: [
              RunRow.gap(1, state),
              faint(
                RunRow.pad_leading(
                  if(tokens > 0, do: Words.tokens(tokens), else: ""),
                  @tokens_width,
                  state
                ),
                @tokens_width,
                state
              )
            ],
            else: []

      row =
        Support.action_spans(clip_spans(spans, width, state), {:local, {:select_agent, agent.id}})

      if Map.get(agent, :launched_by_superseded, false),
        do: [row, Support.text(SafeText.chrome(:superseded_child), state, width)],
        else: [row]
    end)
    |> List.flatten()
  end

  defp sub_token(%{role: :judge}), do: :judge
  defp sub_token(%{state: :queued}), do: :hex_empty
  defp sub_token(_agent), do: :agent_sub

  defp sub_word(%{role: :judge}), do: "judge"
  defp sub_word(_agent), do: "sub"

  defp flag(agent) do
    cond do
      agent.state == :waiting_approval -> "approval"
      agent.state == :waiting_question -> "question"
      agent.state == :failed -> "failed"
      agent.state == :done -> "done"
      Map.get(agent, :launched_by_superseded, false) -> "superseded"
      true -> nil
    end
  end

  # The state mark at the right of a mini card: done, running, waiting, failed, queued.
  defp mark(agent, role, state) do
    {token, mark_role} =
      cond do
        agent.state == :done -> {:check_mark, :success}
        agent.state == :failed -> {:close_mark, :error}
        Words.waiting?(agent.state) -> {:waiting, :warning}
        agent.state == :queued -> {:hex_empty, :ticks_track}
        Words.finished?(agent.state) -> {:dot, :text_faint}
        true -> {:dot, role}
      end

    %Span{
      text: Support.glyph(token, state),
      style: %{RunRow.tinted(mark_role, state) | modifiers: [:bold]}
    }
  end

  defp step_style(agent, state) do
    cond do
      Words.waiting?(agent.state) -> RunRow.tinted(:warning, state)
      agent.state == :failed -> RunRow.tinted(:error, state)
      Words.finished?(agent.state) -> Theme.style(:text_faint, state.capabilities)
      true -> Theme.style(:text_muted, state.capabilities)
    end
  end

  # Six stripes: the lit run in the lane colour, the rest on the track.
  defp ticks(agent, role, state) do
    progress = min(100, max(0, agent.progress || 0))
    lit = (progress / 100 * @gauge_cells) |> round() |> max(0) |> min(@gauge_cells)
    on = SafeText.value(Support.glyph(:stripe, state))
    off = SafeText.value(Support.glyph(:stripe_off, state))

    [
      RunRow.gap(1, state),
      %Span{
        text: Density.safe(String.duplicate(on, lit), state, lit),
        style: RunRow.tinted(gauge_tone(agent, role), state)
      },
      %Span{
        text: Density.safe(String.duplicate(off, @gauge_cells - lit), state, @gauge_cells - lit),
        style: RunRow.tinted(:ticks_track, state)
      }
    ]
  end

  # ------------------------------------------------------------- drawer

  # `OPERATIONS · builder-4                 2 ops`, then the rows.
  defp drawer(state, agent, width, left) do
    ops = length(Ops.items(state, agent))
    index = Enum.find_index(Hive.lanes_for(state, Support.run(state)), &(&1.id == agent.id)) || 0
    role = Hive.lane_role(agent, index)
    name = Hive.name(agent)

    heading =
      two_sided(
        state,
        width,
        [
          faint_bold("Operations · ", state),
          %Span{
            text: Density.safe(name, state, max(1, width - 20)),
            style: %{RunRow.tinted(role, state) | modifiers: [:bold]}
          }
        ],
        if(ops > 0, do: [faint(Words.count(ops, "op", "ops"), width, state)], else: [])
      )

    rows =
      case Ops.rows(state, agent, width, left - 2) do
        [] ->
          [
            %Block.RichText{
              spans: [
                %Span{
                  text: Density.safe("nothing yet", state, width),
                  style: Theme.style(:text_ghost, state.capabilities)
                }
              ]
            }
          ]

        rows ->
          rows
      end

    [Hive.blank(state), heading | rows]
  end

  # ------------------------------------------------------------ helpers

  defp status_word(agent) do
    cond do
      agent.state == :waiting_approval -> {"approval", :warning}
      agent.state == :waiting_question -> {"waiting", :warning}
      agent.state == :done -> {"done", :success}
      agent.state == :failed -> {"failed", :error}
      agent.state in [:stopped, :interrupted, :superseded] -> {"stopped", :text_muted}
      agent.state == :paused -> {"paused", :warning}
      agent.state == :retrying -> {"retrying", :warning}
      agent.state == :queued -> {"queued", :text_muted}
      true -> {"active", :success}
    end
  end

  defp join(parts), do: parts |> Enum.reject(&(is_nil(&1) or &1 == "")) |> Enum.join(" · ")

  defp faint(text, width, state),
    do: %Span{
      text: Density.safe(text, state, max(0, width)),
      style: Theme.style(:text_faint, state.capabilities)
    }

  defp faint_bold(text, state),
    do: %Span{
      text: Density.safe(text, state, Hive.measure(text, state)),
      style: %{Theme.style(:text_faint, state.capabilities) | modifiers: [:bold]}
    }

  defp primary(text, state),
    do: %Span{
      text: Density.safe(text, state, Hive.measure(text, state)),
      style: Theme.style(:text_primary, state.capabilities)
    }

  defp pad_span(%Span{} = span, width, state) do
    text = SafeText.value(span.text)
    %{span | text: Density.safe(RunRow.pad(text, width, state), state, width)}
  end

  # Left spans, then right spans against the right edge; the last left span
  # yields when the row is too narrow, and the right side goes before it does.
  defp two_sided(state, width, left, right),
    do: %Block.RichText{spans: two_sided_spans(state, width, List.wrap(left), List.wrap(right))}

  defp two_sided_spans(state, width, left, right) do
    left_cells = cells(left, state)
    right_cells = cells(right, state)

    cond do
      right == [] or left_cells + 1 + right_cells > width ->
        clip_spans(left, width, state)

      true ->
        left ++ [RunRow.gap(width - left_cells - right_cells, state)] ++ right
    end
  end

  # Spans clipped to `width` cells in order; a span that does not fit is cut.
  defp clip_spans(spans, width, state) do
    {taken, _} =
      Enum.reduce(spans, {[], 0}, fn span, {acc, used} ->
        room = width - used
        span_cells = Hive.measure(SafeText.value(span.text), state)

        cond do
          room <= 0 ->
            {acc, used}

          span_cells <= room ->
            {[span | acc], used + span_cells}

          true ->
            {[%{span | text: Density.safe(SafeText.value(span.text), state, room)} | acc], width}
        end
      end)

    Enum.reverse(taken)
  end

  defp cells(spans, state),
    do: Enum.reduce(spans, 0, &(Hive.measure(SafeText.value(&1.text), state) + &2))
end
