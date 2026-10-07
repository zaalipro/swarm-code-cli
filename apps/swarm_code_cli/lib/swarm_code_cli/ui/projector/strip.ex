defmodule SwarmCodeCLI.UI.Projector.Strip do
  @moduledoc """
  The side panel under 120 columns (pass72 P6, R17, D10; pass 75 SA S5):
  one row under the title, no fill,

      ▌C lets plan how to make…  ! 2 need you ^N   ⋔ 3 of 4 in · ✗ Build check turn limit   $0.87

  the run in chat, what waits on you, the newest swarm's `R of T in`, the
  most recent agent that ran out of turns, and the price (else tokens) on
  the right. A row too narrow drops the stopped agent's name, then cuts the
  title to 12 cells, then drops the price. In hint mode each agent of the
  run in chat carries its badge before its name. Every cell is measured, so
  the row never wraps.
  """
  alias SwarmCodeCLI.UI.Projector.Panel
  alias SwarmCodeCLI.UI.Projector.Panel.{Draw, Model, Name, Shapes}

  # pass 75 (S5): the chat title's cells before the row runs short.
  @title_cells 22

  @doc "The strip's one block for a `width`-cell row."
  def project(state, width) do
    state |> plan(width) |> Enum.map(&elem(&1, 0)) |> Enum.reject(&is_nil/1)
  end

  @doc "The strip's row and the targets it shows (the agents as hidden rows)."
  def plan(state, width) do
    runs = Model.runs(state)

    case runs do
      [] -> []
      [run | _others] -> draw(state, width, run, runs)
    end
  end

  defp draw(state, width, run, runs) do
    views = Map.new(runs, &{&1.id, Model.agents(state, &1)})
    agents = Map.get(views, run.id, [])
    needs = Model.needs(state, runs, views)
    chat = Model.in_chat(state)
    in_chat? = chat && chat.id == run.id

    ctx = %{
      state: state,
      width: width,
      mode: :compact,
      runs: runs,
      chat_id: chat && chat.id,
      views: views,
      needs: needs,
      hint?: is_map(state.hint),
      labels: labels(state)
    }

    head = fn cells ->
      [
        if(in_chat?, do: {Panel.g(ctx, :in_chat), :accent}, else: {" ", :plain}),
        # S5 draws the chat run's mark bold, like its title (final QA-5).
        {Draw.mark(Model.kind(run), state), Model.kind_role(run), [:bold]},
        {" " <> Draw.elide(Model.title(run), cells, state), :text_primary, [:bold]}
      ]
    end

    need =
      case length(needs) do
        0 ->
          []

        n ->
          [
            {"  ", :plain},
            {"! #{n} " <> if(n == 1, do: "needs you", else: "need you"), :warning, [:bold]},
            {" ^N", :text_primary, [:bold]}
          ]
      end

    rows =
      if ctx.hint? do
        hinted(ctx, head.(@title_cells), agents, need)
      else
        # cli020 E29: `Plan 3/7` of the run in front, before the swarm count.
        plan = SwarmCodeCLI.UI.Projector.Panel.PlanSection.strip_part(run)

        fitted(
          ctx,
          head,
          need ++ plan,
          swarm(ctx, runs),
          turn_limit(runs, views),
          money(ctx, runs)
        )
      end

    targets =
      Enum.map(agents, fn v -> {nil, {:agent, v.run_id, v.id, v.needs_you?}, [hidden: true]} end)

    [{rows, {:run, run.id}, []} | targets]
  end

  # The row at its richest that fits (8.2): the stopped agent's name whole,
  # else cut to the cells left (at most 24), else left out; then the title
  # cut to 12 cells; then no price.
  defp fitted(ctx, head, need, swarm, stopped, money) do
    state = ctx.state
    inner = ctx.width - 2

    attempt = fn title_cells, name?, money? ->
      right = if money?, do: money, else: []
      right_cells = if right == [], do: 0, else: cells(right, state) + 1
      left = head.(title_cells) ++ need ++ swarm
      room = inner - cells(left, state) - right_cells
      part = stopped_part(stopped, name?, room, state)
      left = left ++ part
      if cells(left, state) <= inner - right_cells, do: Draw.row(left, right, ctx.width, state)
    end

    Enum.find_value(
      [
        {@title_cells, true, true},
        {@title_cells, false, true},
        {12, false, true},
        {12, false, false}
      ],
      fn {title, name?, money?} -> attempt.(title, name?, money?) end
    ) ||
      Draw.row(
        head.(12) ++ need ++ swarm ++ stopped_part(stopped, false, 0, state),
        [],
        ctx.width,
        state
      )
  end

  # ` · ✗ Build check turn limit`: the name gets the cells left, at most 24,
  # cut at its end only when they are fewer than it needs.
  defp stopped_part(nil, _name?, _room, _state), do: []

  defp stopped_part(view, name?, room, state) do
    x = [{" · ", :text_faint}, {Draw.g(:turn_limit, state), :error}]
    words = [{" turn limit", :error}]
    fixed = cells(x ++ words, state) + 1
    cells = min(24, room - fixed)

    if name? and cells >= min(4, Draw.cells(view.display, state)),
      do: x ++ [{" ", :plain}, {Name.fit(view.display, cells, state), view.name_role}] ++ words,
      else: x ++ words
  end

  # `   ⋔ 3 of 4 in`: the newest swarm among the shown runs.
  defp swarm(ctx, runs) do
    case runs
         |> Enum.filter(&(Model.kind(&1) == :swarm))
         |> Enum.max_by(&{&1.created_sequence, &1.started_at || 0}, fn -> nil end) do
      nil ->
        []

      run ->
        {r, t} = Shapes.reported(run, Map.get(ctx.views, run.id, []))

        [
          {"   ", :plain},
          {Draw.mark(Model.kind(run), ctx.state), Model.kind_role(run)},
          {" #{r} of #{t} in", :text_muted}
        ]
    end
  end

  # The agent that ran out of turns most recently across the shown runs.
  defp turn_limit(runs, views) do
    runs
    |> Enum.flat_map(&Map.get(views, &1.id, []))
    |> Enum.filter(&(&1.state == :turn_limit))
    |> Enum.max_by(&(Map.get(&1, :finished_at) || 0), fn -> nil end)
  end

  # The priced runs' sum (9.1), else every run's tokens.
  defp money(ctx, runs) do
    priced = Enum.filter(runs, &is_number(&1.cost_usd))

    text =
      case priced do
        [] ->
          runs
          |> Enum.map(fn run -> tokens(run, Map.get(ctx.views, run.id, [])) end)
          |> Enum.sum()
          |> Model.tokens()
          |> then(&(&1 && &1 <> " tokens"))

        _ ->
          priced |> Enum.map(& &1.cost_usd) |> Enum.sum() |> Model.money()
      end

    if text, do: [{text, :text_muted}], else: []
  end

  defp tokens(run, views) do
    case Model.token_count(run) do
      0 -> views |> Enum.map(&(&1.tokens || 0)) |> Enum.sum()
      n -> n
    end
  end

  # Hint mode: each agent of the run in chat by its one name and badge, so
  # every letter the hint keys offer is on screen.
  defp hinted(ctx, head, agents, need) do
    state = ctx.state
    fixed = cells(head ++ need, state) + 3
    name_cells = name_cells(agents, ctx, ctx.width - fixed, state)

    agent_segments =
      Enum.flat_map(agents, fn view ->
        badge = Map.get(ctx.labels, {:agent, view.run_id, view.id})

        badge_seg =
          if badge,
            do: [{" " <> badge <> " ", :on_accent, [:bold]}, {" ", :plain}],
            else: []

        badge_seg ++
          [
            {Name.fit(view.display, Map.fetch!(name_cells, view.id), state), view.name_role},
            {Panel.g(ctx, view.state), Model.glyph_role(view.state),
             if(view.needs_you?, do: [:bold], else: [])},
            {" ", :plain}
          ]
      end)

    sep = if agents == [], do: [], else: [{" · ", :text_faint}]
    Draw.row(head ++ sep ++ agent_segments, need, ctx.width, state)
  end

  # Cells per agent name, shortest first: a name shorter than its fair share
  # of `room` keeps its length and leaves the rest to the longer ones (a
  # badge, the glyph and a space are each agent's other cells); 3..24.
  defp name_cells(agents, ctx, room, state) do
    overhead = if ctx.hint?, do: 6, else: 2

    {cells, _, _} =
      agents
      |> Enum.map(&{&1.id, Draw.cells(&1.display, state)})
      |> Enum.sort_by(&elem(&1, 1))
      |> Enum.reduce({%{}, max(0, room), length(agents)}, fn {id, wanted}, {acc, left, n} ->
        share = div(left, max(n, 1)) - overhead
        take = wanted |> min(share) |> min(24) |> max(3)
        {Map.put(acc, id, take), left - take - overhead, n - 1}
      end)

    cells
  end

  defp cells(segments, state) do
    Enum.reduce(segments, 0, fn
      {text, _role}, acc -> acc + Draw.cells(text, state)
      {text, _role, _mods}, acc -> acc + Draw.cells(text, state)
    end)
  end

  defp labels(state) do
    case state.hint do
      %{labels: labels} when is_map(labels) -> Map.new(labels, fn {l, t} -> {hint_key(t), l} end)
      _ -> %{}
    end
  end

  # Hint targets (owner O's `Hint.labels/1`) name an agent as `{:agent, run, node}`;
  # the drawn entries carry the needs-you flag as well. Badges key on the former.
  defp hint_key({:agent, run, node, _needs?}), do: {:agent, run, node}
  defp hint_key(target), do: target
end
