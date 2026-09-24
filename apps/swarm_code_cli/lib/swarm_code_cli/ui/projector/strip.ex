defmodule SwarmCodeCLI.UI.Projector.Strip do
  @moduledoc """
  The side panel under 120 columns (pass72 P6, R17, D10): one row under the
  title,

      ▌⋔ architecture review 1/4 · Lead◌ engine● data◐ llm✓ web!  +1 run   ! 1 needs you ^N

  the run in chat with its known ratio, each agent as its short name and
  state glyph, the other live runs as a count and their marks, and what waits
  on you on the right. In hint mode each agent carries its badge before its
  name. Every cell is measured, so the row never wraps.
  """
  alias SwarmCodeCLI.UI.Projector.Panel
  alias SwarmCodeCLI.UI.Projector.Panel.{Draw, Model, Name, Shapes}

  # pass73 T10: the strip names each agent by its one name, cut at its end.
  @strip_name 12

  @doc "The strip's one block for a `width`-cell row."
  def project(state, width) do
    state |> plan(width) |> Enum.map(&elem(&1, 0)) |> Enum.reject(&is_nil/1)
  end

  @doc "The strip's row and the targets it shows (the agents as hidden rows)."
  def plan(state, width) do
    runs = Model.runs(state)

    case runs do
      [] -> []
      [run | others] -> draw(state, width, run, others, runs)
    end
  end

  defp draw(state, width, run, others, runs) do
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

    ratio = Shapes.ratio(ctx, run)

    head =
      [
        if(in_chat?, do: {Panel.g(ctx, :in_chat), :accent}, else: {" ", :plain}),
        {Draw.mark(Model.kind(run), state), Model.kind_role(run)},
        {" " <> Draw.elide(Model.title(run), 28, state), :text_primary, [:bold]},
        ratio && {" " <> ratio, :text_muted},
        agents != [] && {" · ", :text_ghost}
      ]
      |> Enum.reject(&(&1 in [nil, false]))

    more =
      case others do
        [] ->
          []

        others ->
          marks = Enum.map(others, &{Draw.mark(Model.kind(&1), state), Model.kind_role(&1)})

          [
            {" +#{length(others)} " <> if(length(others) == 1, do: "run ", else: "runs "),
             :text_faint}
          ] ++
            marks
      end

    right =
      case length(needs) do
        0 ->
          []

        n ->
          [
            {"! #{n} " <> if(n == 1, do: "needs you", else: "need you"), :warning, [:bold]},
            {" ^N", :text_primary}
          ]
      end

    # pass73 T10: each agent by its one name; the names share what the row
    # has left after the run, the other runs and what waits on you, so a
    # long name is cut at its end with `…`, never swapped for a shorter word.
    fixed = Draw.cells(Enum.map_join(head ++ more ++ right, &elem(&1, 0)), state) + 3
    name_cells = name_cells(agents, ctx, width - fixed, state)

    agent_segments =
      agents
      |> Enum.flat_map(fn view ->
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

    row = Draw.row(head ++ agent_segments ++ more, right, width, state, background: :surface)

    targets =
      Enum.map(agents, fn v -> {nil, {:agent, v.run_id, v.id, v.needs_you?}, [hidden: true]} end)

    [{row, {:run, run.id}, []} | targets]
  end

  # Cells per agent name, shortest first: a name shorter than its fair share
  # of `room` keeps its length and leaves the rest to the longer ones (a
  # badge, the glyph and a space are each agent's other cells); 3..12.
  defp name_cells(agents, ctx, room, state) do
    overhead = if ctx.hint?, do: 6, else: 2

    {cells, _, _} =
      agents
      |> Enum.map(&{&1.id, Draw.cells(&1.display, state)})
      |> Enum.sort_by(&elem(&1, 1))
      |> Enum.reduce({%{}, max(0, room), length(agents)}, fn {id, wanted}, {acc, left, n} ->
        share = div(left, max(n, 1)) - overhead
        take = wanted |> min(share) |> min(@strip_name) |> max(3)
        {Map.put(acc, id, take), left - take - overhead, n - 1}
      end)

    cells
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
