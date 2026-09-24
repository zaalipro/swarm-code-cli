defmodule SwarmCodeCLI.UI.Projector.Panel.Shapes do
  @moduledoc """
  What each run kind adds around its agents in the full panel (D4): the
  swarm's reported-of-total gauge, the chat turn's quote, produced files and
  context gauge, the workflow's pipeline and phases, the goal's iterations and
  criteria, research's funnel and report sections, and the consensus
  positions. Gauges only for known ratios (R5): a fact the read model does not
  carry is left out, never estimated.

  The pass-72 run facts (owner S) are read with `Map.get/3`: `reported` and
  `total`, `phases` (`[%{name, state}]`), `goal` (`%{iteration, max,
  criteria: [%{text, met_in}], verdicts, last_verdict}`), `research`
  (`%{found, read, used, domains: [%{name, count}], sections: [%{title,
  state}]}`) and `positions`/`round`/`rounds`/`agreement` for consensus.
  """
  alias SwarmCodeCLI.UI.Projector.Panel
  alias SwarmCodeCLI.UI.Projector.Panel.{Draw, Model}

  # ------------------------------------------------------------ headers

  @doc "The dim second header row (D1): mode, team, tokens, cost."
  def meta(ctx, run) do
    state = ctx.state
    views = Map.get(ctx.views, run.id, [])
    tokens = run_tokens(run, views)

    parts =
      case Model.kind(run) do
        :assistant ->
          [mode_words(state), model(run, views), Model.tokens(tokens), Model.money(run.cost_usd)]

        :swarm ->
          [mode_words(state), team(ctx, views), Model.tokens(tokens), Model.money(run.cost_usd)]

        :workflow ->
          phases = phases(run)

          [
            "workflow",
            mode_words(state),
            if(phases != [], do: Panel.count(length(phases), "phase", "phases")),
            Model.tokens(tokens),
            Model.money(run.cost_usd)
          ]

        :goal ->
          goal = Map.get(run, :goal) || %{}
          limit = Map.get(goal, :max)

          [
            "goal",
            mode_words(state),
            if(is_integer(limit), do: "limit #{limit} iterations"),
            Model.money(run.cost_usd)
          ]

        :research ->
          [
            "research",
            Panel.count(length(views), "agent", "agents"),
            Model.tokens(tokens),
            Model.money(run.cost_usd)
          ]

        :consensus_judge ->
          models = Enum.count(views, &(&1.role not in [:judge, :assistant, :lead]))

          [
            "consensus",
            if(models > 0, do: Panel.count(models, "model", "models")),
            Model.tokens(tokens),
            Model.money(run.cost_usd)
          ]

        _ ->
          [mode_words(state), team(ctx, views), Model.tokens(tokens), Model.money(run.cost_usd)]
      end

    parts = Enum.reject(parts, &(is_nil(&1) or &1 == ""))
    room = ctx.width - 4
    joined = Enum.join(parts, " · ")

    # A long model name goes before the tokens and the cost do.
    if Draw.cells(joined, state) > room and length(parts) > 2 do
      model = Map.get(run, :model)
      parts |> Enum.reject(&(&1 == model)) |> Enum.join(" · ")
    else
      joined
    end
  end

  defp run_tokens(run, views) do
    case Model.token_count(run) do
      0 -> views |> Enum.map(& &1.tokens) |> Enum.sum()
      n -> n
    end
  end

  defp model(run, views) do
    Map.get(run, :model) ||
      Enum.find_value(views, fn v -> v.role == :assistant && nil end)
  end

  # `4 × *-review` when the workers share a suffix (R14), else `4 agents`.
  defp team(ctx, views) do
    subs = Enum.reject(views, &(&1.role in [:lead, :assistant]))
    n = length(subs)

    case Model.affixes(Enum.map(subs, & &1.name)) do
      {_prefix, "-" <> _ = suffix} when n > 1 ->
        "#{n} #{Panel.g(ctx, :times)} *#{suffix}"

      _ when n > 0 ->
        Panel.count(n, "agent", "agents")

      _ ->
        nil
    end
  end

  defp mode_words(state) do
    case Map.get(state.read_model.snapshots, :workspace) do
      %{approval_mode: :read_only} -> "read-only"
      %{approval_mode: :auto} -> "auto"
      %{approval_mode: :full_access} -> "full access"
      _ -> nil
    end
  end

  @doc "The known ratio a compact header or an orbit line shows (D5), or nil."
  def ratio(ctx, run) do
    views = Map.get(ctx.views, run.id, [])

    case Model.kind(run) do
      :swarm ->
        {reported, total} = reported(run, views)
        if total > 0, do: "#{reported}/#{total}"

      :workflow ->
        phases = phases(run)
        done = Enum.count(phases, &(&1.state == :done))
        if phases != [], do: "#{done}/#{length(phases)}"

      :goal ->
        goal = Map.get(run, :goal) || %{}

        case {Map.get(goal, :iteration), Map.get(goal, :max)} do
          {i, m} when is_integer(i) and is_integer(m) -> "it #{i}/#{m}"
          _ -> nil
        end

      :consensus_judge ->
        case {Map.get(run, :round), Map.get(run, :rounds)} do
          {r, n} when is_integer(r) and is_integer(n) -> "r #{r}/#{n}"
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @doc "Reviewers reported of spawned (R5: a known ratio): the wire's, else counted."
  def reported(run, views) do
    subs = Enum.reject(views, &(&1.role in [:lead, :assistant]))

    case {Map.get(run, :reported), Map.get(run, :total)} do
      {r, t} when is_integer(r) and is_integer(t) and t > 0 ->
        {r, t}

      _ ->
        {Enum.count(subs, &(&1.state in [:done, :failed, :stopped])), length(subs)}
    end
  end

  # ------------------------------------------------------------ before

  @doc "Rows above the agents: a workflow's pipeline, a goal's iterations, research's funnel."
  def before_agents(ctx, run, views, _extras?) do
    case Model.kind(run) do
      :workflow -> pipeline(ctx, run) ++ live_phase(ctx, run, views)
      :goal -> iterations(ctx, run)
      :research -> funnel(ctx, run)
      :consensus_judge -> positions(ctx, run)
      _ -> []
    end
  end

  defp phases(run) do
    case Map.get(run, :phases) do
      list when is_list(list) ->
        Enum.flat_map(list, fn
          %{name: name, state: st} when is_binary(name) -> [%{name: name, state: st}]
          _ -> []
        end)

      _ ->
        []
    end
  end

  # `scan   plan   implement` over `✓──────✓──────●───`: each phase's glyph
  # under the start of its name.
  defp pipeline(ctx, run) do
    phases = phases(run)

    if phases == [] do
      []
    else
      state = ctx.state
      names = Enum.map(phases, & &1.name)
      widths = Enum.map(names, &max(Draw.cells(&1, state) + 3, 6))
      rule = Panel.g(ctx, :rule)

      rail =
        phases
        |> Enum.zip(widths)
        |> Enum.with_index()
        |> Enum.flat_map(fn {{phase, w}, i} ->
          p3 = phase_state(phase.state)
          glyph = {Panel.g(ctx, p3), Model.glyph_role(p3)}

          if i == length(phases) - 1,
            do: [glyph],
            else: [glyph, {String.duplicate(rule, w - 1), :text_ghost}]
        end)

      label =
        names
        |> Enum.zip(widths)
        |> Enum.map_join("", fn {name, w} -> Draw.pad_to(name, w, state) end)

      [
        Panel.row(ctx, [{"  " <> String.trim_trailing(label), :text_muted}]),
        Panel.row(ctx, [{"  ", :plain} | rail]),
        Panel.blank(ctx)
      ]
    end
  end

  # `implement            3 steps in parallel` over the live phase's agents.
  defp live_phase(ctx, run, views) do
    case Enum.find(phases(run), &(phase_state(&1.state) in [:working, :needs_you])) do
      nil ->
        []

      phase ->
        n = length(views)
        words = if n > 1, do: "#{n} steps in parallel", else: Panel.count(n, "step", "steps")
        [Panel.row(ctx, [{phase.name, :text_muted}], [{words, :text_faint}])]
    end
  end

  defp phase_state(st) when st in [:done, :completed, "done"], do: :done
  defp phase_state(st) when st in [:failed, "failed"], do: :failed
  defp phase_state(st) when st in [:running, :active, "running"], do: :working
  defp phase_state(st) when st in [:waiting, :needs_you], do: :needs_you
  defp phase_state(_), do: :queued

  defp iterations(ctx, run) do
    goal = Map.get(run, :goal) || %{}

    case {Map.get(goal, :iteration), Map.get(goal, :max)} do
      {i, m} when is_integer(i) and is_integer(m) and m > 0 and m <= 12 ->
        verdicts = Map.get(goal, :verdicts) || []
        rule = Panel.g(ctx, :rule)

        rail =
          Enum.flat_map(1..m, fn n ->
            p3 =
              cond do
                n < i -> if Enum.at(verdicts, n - 1) in [:met, "met"], do: :done, else: :failed
                n == i -> :thinking
                true -> :queued
              end

            glyph = {Panel.g(ctx, p3), Model.glyph_role(p3)}
            if n == m, do: [glyph], else: [glyph, {String.duplicate(rule, 6), :text_ghost}]
          end)

        numbers = Enum.map_join(1..m, "", &String.pad_trailing(Integer.to_string(&1), 7))

        [
          Panel.row(ctx, [{"iterations", :text_muted}], [{"#{i} of #{m}", :text_faint}]),
          Panel.row(ctx, [{"  ", :plain} | rail]),
          Panel.row(ctx, [{"  " <> String.trim_trailing(numbers), :text_faint}]),
          Panel.blank(ctx)
        ]

      _ ->
        wire_iteration(ctx, run)
    end
  end

  # Owner S's goal facts: this run's place among the goal's runs (the domain
  # records no maximum, so there is no rail to draw).
  defp wire_iteration(ctx, run) do
    case {Map.get(run, :goal_iteration), Map.get(run, :goal_iterations)} do
      {i, n} when is_integer(i) and is_integer(n) and n >= i ->
        [
          Panel.row(ctx, [{"iteration", :text_muted}], [{"#{i} of #{n} so far", :text_faint}]),
          Panel.blank(ctx)
        ]

      {i, _} when is_integer(i) ->
        [Panel.row(ctx, [{"iteration", :text_muted}], [{"#{i}", :text_faint}]), Panel.blank(ctx)]

      _ ->
        []
    end
  end

  defp funnel(ctx, run) do
    research = Map.get(run, :research) || %{}
    found = Map.get(research, :found)

    if is_integer(found) and found > 0 do
      bar_room = ctx.width - 2 - 2 - 7 - 4
      on = Panel.g(ctx, :gauge_on)

      bars =
        for key <- [:found, :read, :used], n = Map.get(research, key), is_integer(n) do
          cells = max(if(n > 0, do: 1, else: 0), div(n * bar_room, max(found, 1)))
          label = String.pad_trailing(Atom.to_string(key), 5)

          Panel.row(
            ctx,
            [
              {"  " <> label, :text_muted},
              {"  ", :plain},
              {String.duplicate(on, cells), :run_research}
            ],
            [{Integer.to_string(n), :text_primary}]
          )
        end

      [Panel.row(ctx, [{"sources", :text_muted}]) | bars] ++ [Panel.blank(ctx)]
    else
      []
    end
  end

  defp positions(ctx, run) do
    case Map.get(run, :positions) do
      [_ | _] = positions ->
        rows =
          positions
          |> Enum.take(4)
          |> Enum.flat_map(fn
            %{letter: letter, text: text} ->
              [
                Panel.row(ctx, [
                  {"  " <> letter, :text_primary, [:bold]},
                  {"  " <> text, :text_primary}
                ])
              ]

            _ ->
              []
          end)

        [Panel.row(ctx, [{"positions", :text_muted}]) | rows] ++ [Panel.blank(ctx)]

      _ ->
        []
    end
  end

  # ------------------------------------------------------------- after

  @doc "Rows under the agents: the kind's facts; `extras?` adds the optional ones."
  def after_agents(ctx, run, views, extras?) do
    case Model.kind(run) do
      :swarm ->
        swarm_foot(ctx, run, views)

      :assistant ->
        if(extras?, do: chat_foot(ctx, run), else: [])

      :workflow ->
        phases_foot(ctx, run) ++ if(extras?, do: produced(ctx, run, "produced so far"), else: [])

      :goal ->
        criteria(ctx, run) ++
          verdict(ctx, run, "last verdict") ++
          if(extras?, do: produced(ctx, run, "produced"), else: [])

      :research ->
        sections(ctx, run)

      :consensus_judge ->
        agreement(ctx, run) ++ criteria(ctx, run) ++ verdict(ctx, run, "the judge said")

      _ ->
        []
    end
  end

  # `reported  ▰▱▱▱  1 of 4        1 needs you` and what the lead waits for.
  defp swarm_foot(ctx, run, views) do
    {reported, total} = reported(run, views)

    if total == 0 do
      []
    else
      waiting = Enum.filter(views, & &1.needs_you?)
      working = Enum.count(views, &(&1.state in [:working, :thinking]))

      left =
        Enum.filter(
          views,
          &(&1.role not in [:lead, :assistant] and &1.state not in [:done, :failed, :stopped])
        )

      shown = min(total, 12)
      lit = if total > 12, do: div(reported * 12, total), else: reported

      right =
        cond do
          waiting != [] -> [{"#{length(waiting)} needs you", :warning}]
          working > 0 -> [{"#{working} working", :text_faint}]
          true -> []
        end

      why =
        cond do
          waiting != [] -> hd(waiting).display <> " is paused on you"
          reported == total -> "the Lead is merging the findings"
          length(left) == 1 -> "the Lead reports once #{hd(left).display} is in"
          true -> "the Lead reports when all #{total} are in"
        end

      [
        Panel.blank(ctx),
        Panel.row(
          ctx,
          [
            {"reported  ", :text_muted},
            {String.duplicate(Panel.g(ctx, :gauge_on), lit), :success},
            {String.duplicate(Panel.g(ctx, :gauge_off), shown - lit), :text_ghost},
            {"  #{reported} of #{total}", :text_primary}
          ],
          right
        ),
        Panel.row(ctx, [{"          " <> why, :text_faint}])
      ]
    end
  end

  defp chat_foot(ctx, run) do
    # A finished turn's finding row already says it.
    said = if run.state in [:done, :failed, :stopped], do: [], else: said(ctx, run)

    said ++ produced(ctx, run, "produced") ++ context(ctx)
  end

  # `it said`: the newest words of the turn, quoted, and when (D4 chat).
  defp said(ctx, run) do
    item =
      ctx.state.read_model.transcript
      |> Map.values()
      |> Enum.filter(&(&1.run_id == run.id and &1.kind == :text and &1.role == :assistant))
      |> Enum.max_by(&{&1.created_sequence, &1.id}, fn -> nil end)

    case item && Model.sentences(item.text, 2) do
      nil ->
        []

      text ->
        when_said =
          case {item.at, run.started_at} do
            {at, s} when is_integer(at) and is_integer(s) and at >= s + 1_000 ->
              [
                Panel.row(ctx, [
                  {"  said at " <> Model.short_clock(at - s) <> ", shown in the chat above",
                   :text_faint}
                ])
              ]

            _ ->
              []
          end

        [Panel.blank(ctx), Panel.row(ctx, [{"it said", :text_muted}])] ++
          quoted(ctx, text) ++ when_said
    end
  end

  @doc false
  def produced(ctx, run, title) do
    state = ctx.state

    files =
      ctx
      |> Panel.changes(run)
      |> Enum.group_by(& &1.path)
      |> Enum.map(fn {path, changes} ->
        {path, sum(changes, :added), sum(changes, :removed)}
      end)
      |> Enum.sort()

    case files do
      [] ->
        []

      files ->
        shown = Enum.take(files, 3)

        rows =
          Enum.map(shown, fn {path, added, removed} ->
            right =
              [
                if(added > 0, do: {"+#{added}", :success}),
                if(added > 0 and removed > 0, do: {" ", :plain}),
                if(removed > 0, do: {Panel.g(ctx, :minus) <> "#{removed}", :error})
              ]
              |> Enum.reject(&is_nil/1)

            room = ctx.width - 4 - 10

            Panel.row(
              ctx,
              [{"  " <> tail_path(path, room, state), :text_primary}],
              right
            )
          end)

        [
          Panel.blank(ctx),
          Panel.row(ctx, [{title, :text_muted}], [
            {Panel.count(length(files), "file", "files"), :text_faint}
          ])
        ] ++ rows
    end
  end

  # The end of a path that fits: leading directories go first (`…/fake_clock.ex`).
  defp tail_path(path, room, state) do
    parts = Path.split(path)

    Enum.find_value(0..(length(parts) - 1), fn drop ->
      candidate = parts |> Enum.drop(drop) |> Path.join()
      candidate = if drop > 0, do: "…/" <> candidate, else: candidate
      if Draw.cells(candidate, state) <= room, do: candidate
    end) || Draw.elide(path, room, state, :middle)
  end

  defp sum(changes, key), do: changes |> Enum.map(&(Map.get(&1, key) || 0)) |> Enum.sum()

  # The context gauge (R5: used of the window is a known ratio).
  defp context(ctx) do
    case Map.get(ctx.state.read_model.snapshots, :workspace) do
      %{context_used: used, context_window: window}
      when is_integer(used) and is_integer(window) and window > 0 ->
        cells = 16
        lit = min(cells, max(if(used > 0, do: 1, else: 0), div(used * cells, window)))

        [
          Panel.blank(ctx),
          Panel.row(ctx, [{"context", :text_muted}], [
            {"#{Model.tokens(used) || "0"} of #{Model.tokens(window)}", :text_faint}
          ]),
          Panel.row(ctx, [
            {"  " <> String.duplicate(Panel.g(ctx, :gauge_on), lit), :text_muted},
            {String.duplicate(Panel.g(ctx, :gauge_off), cells - lit), :text_ghost}
          ])
        ]

      _ ->
        []
    end
  end

  defp phases_foot(ctx, run) do
    phases = phases(run)

    if phases == [] do
      []
    else
      done = Enum.count(phases, &(phase_state(&1.state) == :done))
      total = length(phases)

      [
        Panel.blank(ctx),
        Panel.row(ctx, [{"phases", :text_muted}], [{"#{done} of #{total} done", :text_faint}]),
        Panel.row(ctx, [
          {"  " <> String.duplicate(Panel.g(ctx, :gauge_on), done), :success},
          {String.duplicate(Panel.g(ctx, :gauge_off), total - done), :text_ghost}
        ])
      ]
    end
  end

  # The criteria (D4 goal): the goal facts when the wire has them, else the
  # judge's newest verdict checks (✓ met, ✗ not met, ○ not scored yet).
  defp criteria(ctx, run) do
    goal = Map.get(run, :goal) || %{}

    items =
      case Map.get(goal, :criteria) do
        [_ | _] = criteria ->
          Enum.map(criteria, fn c ->
            met_in = Map.get(c, :met_in)
            {if(met_in, do: true), Map.get(c, :text) || "", met_in && "met in it #{met_in}"}
          end)

        _ ->
          case verdict_of(ctx, run) do
            %{checks: [_ | _] = checks} ->
              Enum.map(checks, &{&1.ok, &1.key, Model.present(&1.note)})

            _ ->
              []
          end
      end

    case items do
      [] ->
        []

      items ->
        met = Enum.count(items, &(elem(&1, 0) == true))
        total = length(items)

        rows =
          Enum.map(items, fn {ok, text, note} ->
            {glyph, role} =
              case ok do
                true -> {Panel.g(ctx, :done), :success}
                false -> {Panel.g(ctx, :failed), :error}
                nil -> {Panel.g(ctx, :queued), :text_faint}
              end

            Panel.row(
              ctx,
              [{"  " <> glyph, role}, {" " <> text, :text_primary}],
              if(note, do: [{note, :text_faint}], else: [])
            )
          end)

        verdict =
          case Model.present(Map.get(goal, :last_verdict)) do
            nil ->
              []

            text ->
              [Panel.blank(ctx), Panel.row(ctx, [{"last verdict", :text_muted}])] ++
                quoted(ctx, text)
          end

        [
          Panel.blank(ctx),
          Panel.row(ctx, [{"criteria", :text_muted}], [{"#{met} of #{total} met", :text_faint}]),
          Panel.row(ctx, [
            {"  " <> String.duplicate(Panel.g(ctx, :gauge_on), met), :success},
            {String.duplicate(Panel.g(ctx, :gauge_off), total - met), :text_ghost}
          ])
        ] ++ rows ++ verdict
    end
  end

  defp verdict_of(ctx, run) do
    ctx.state.read_model.verdicts
    |> Map.values()
    |> Enum.filter(&(&1.run_id == run.id))
    |> Enum.max_by(&{&1.round, &1.revision, &1.id}, fn -> nil end)
  end

  defp sections(ctx, run) do
    research = Map.get(run, :research) || %{}

    case Map.get(research, :sections) do
      [_ | _] = sections ->
        done = Enum.count(sections, &(phase_state(&1[:state]) == :done))

        rows =
          Enum.map(sections, fn s ->
            p3 = phase_state(s[:state])

            Panel.row(ctx, [
              {"  " <> Panel.g(ctx, p3), Model.glyph_role(p3)},
              {" " <> (s[:title] || ""), :text_primary}
            ])
          end)

        [
          Panel.blank(ctx),
          Panel.row(ctx, [{"report", :text_muted}], [
            {"#{done} of #{length(sections)} sections", :text_faint}
          ])
        ] ++ rows

      _ ->
        []
    end
  end

  # Owner S's `verdict`: the latest judge's own words, quoted (goal, consensus).
  defp verdict(ctx, run, title) do
    goal_quoted? = is_map(Map.get(run, :goal)) and Map.get(run.goal, :last_verdict)

    summary = with %{summary: text} <- verdict_of(ctx, run), do: text

    case Model.present(Map.get(run, :verdict)) || Model.present(summary) do
      nil -> []
      _text when goal_quoted? -> []
      text -> [Panel.blank(ctx), Panel.row(ctx, [{title, :text_muted}])] ++ quoted(ctx, text)
    end
  end

  defp agreement(ctx, run) do
    case Model.present(Map.get(run, :agreement)) do
      nil ->
        []

      text ->
        [Panel.blank(ctx), Panel.row(ctx, [{"agreement", :text_muted}], [{text, :text_faint}])]
    end
  end

  @doc "A quoted text in at most three rows."
  def quoted(ctx, text) do
    open = Panel.g(ctx, :open_quote)
    close = Panel.g(ctx, :close_quote)
    lines = Draw.wrap(open <> text <> close, ctx.width - 5, 3, ctx.state)

    lines
    |> Enum.with_index()
    |> Enum.map(fn {line, i} ->
      Panel.row(ctx, [{if(i == 0, do: "  ", else: "   ") <> line, :text_muted}])
    end)
  end

  # ------------------------------------------------------------ earlier

  @doc "`earlier in this chat` (the chat frame): finished runs, newest first."
  def earlier(ctx) do
    state = ctx.state

    case Model.earlier(state, 3) do
      [] ->
        []

      runs ->
        rows =
          Enum.map(runs, fn run ->
            {mark, role} = Panel.done_mark(ctx, run)
            clock = run |> Model.elapsed(state) |> Model.clock()

            Panel.row(
              ctx,
              [
                {"  " <> mark, role},
                {" ", :plain},
                {Draw.mark(Model.kind(run), state), Model.kind_role(run)},
                {" " <> Model.first_line(run.title), :text_muted}
              ],
              [{clock || "", :text_faint}]
            )
            |> then(fn {b, _t, o} -> {b, {:run, run.id}, o} end)
          end)

        [Panel.blank(ctx), Panel.row(ctx, [{"earlier in this chat", :text_muted}]) | rows]
    end
  end

  # ------------------------------------------------------------ compact

  @doc "A compact run's note: the suffix its names drop (R14), when one run is shown."
  def compact_note(%{runs: [_]} = ctx, _run, views) do
    subs = Enum.reject(views, &(&1.role in [:lead, :assistant]))

    case Model.affixes(Enum.map(subs, & &1.name)) do
      {_, "-" <> _ = suffix} -> [Panel.row(ctx, [{"  names drop " <> suffix, :text_faint}])]
      _ -> []
    end
  end

  def compact_note(_ctx, _run, _views), do: []

  @doc "What an orbit line says for a kind that has its own fact (D6), or nil."
  def orbit_fact(_ctx, run, _views) do
    case Model.kind(run) do
      :goal ->
        goal = Map.get(run, :goal) || %{}

        case Map.get(goal, :criteria) do
          [_ | _] = c ->
            "#{Enum.count(c, &is_integer(Map.get(&1, :met_in)))} of #{length(c)} criteria met"

          _ ->
            nil
        end

      :consensus_judge ->
        Model.present(Map.get(run, :agreement))

      _ ->
        nil
    end
  end
end
