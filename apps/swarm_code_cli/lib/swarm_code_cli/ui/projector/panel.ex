defmodule SwarmCodeCLI.UI.Projector.Panel do
  @moduledoc """
  The side agent panel, direction D "Constellation with a pulse" (pass72;
  `docs/superpowers/specs/2026-09-23-side-panel/D2.html`, critique §5-6).

  The panel is a picture of what the chat is doing. Per agent it says who,
  its state (glyph and word), one sentence, elapsed and tokens, what it
  produced and whether it needs you (R1): no operations, tool chips, branch
  names or ids. From the top:

    * row 0 when more than one run is live: `5 runs · 17 agents · 14 live · $1.82`;
    * the needs-you band (R3, D2): the literal request, oldest first, `^N answer`;
    * the run in chat, marked `▌` and "in chat" (R4), unfolded; its agents as
      two-row blocks in full (name row, then the 60-second lane and the
      sentence, D3) or one row each in compact (D5);
    * the other live runs, folded to an orbit line and their priority
      sentence (D6) in full, unfolded in compact until the rows run out;
    * the kind's own facts (reported of total, the context gauge, what was
      produced, earlier runs);
    * the lane legend, a rule and the keys.

  Hint mode (state `hint`, owner O) puts a badge before every run and agent
  (P7, D7); the glyphs stay. Every row is exactly the pane's width
  (`Panel.Draw.row/5`), so nothing reaches past the pane's edge.

  `plan/3` returns the rows with the target each one stands for, which
  `PanelOrder.entries/1` reads, so the hint keys and the rows never disagree.
  """
  alias SwarmCodeCLI.UI.Projector.Panel.{Draw, Model, Shapes}
  alias SwarmCodeCLI.UI.Projector.Inspector.Changes

  @type target ::
          {:run, binary()} | {:agent, binary(), binary(), boolean()} | nil
  @type row :: {SwarmCodeCLI.UI.Scene.Block.RichText.t(), target(), keyword()}

  @doc "The panel's blocks for a `rect` (the inspector region)."
  def project(state, rect, _class) do
    state |> plan(rect.width, rect.height) |> Enum.map(&elem(&1, 0)) |> Enum.reject(&is_nil/1)
  end

  @doc "The panel mode the state asks for (owner O's `panel_mode`), `:full` by default."
  def mode(state) do
    case state.panel_mode do
      :compact -> :compact
      _ -> :full
    end
  end

  @doc """
  The panel's rows for a `width` x `height` pane: `{block, target, opts}`,
  where `target` is the run or agent the row stands for (its first row only)
  and `opts` carries `band: true` on the needs-you band's rows.
  """
  @spec plan(map(), non_neg_integer(), non_neg_integer()) :: [row()]
  def plan(state, width, height) do
    ctx = context(state, width)

    if ctx.runs == [] do
      empty(ctx, height)
    else
      layout(ctx, height)
    end
  end

  # ------------------------------------------------------------ context

  defp context(state, width) do
    runs = Model.runs(state)
    chat = Model.in_chat(state)
    views = Map.new(runs, &{&1.id, Model.agents(state, &1)})
    needs = Model.needs(state, runs, views)

    hint = state.hint

    labels =
      case hint do
        %{labels: labels} when is_map(labels) ->
          Map.new(labels, fn {l, t} -> {hint_key(t), l} end)

        _ ->
          %{}
      end

    %{
      state: state,
      width: width,
      mode: mode(state),
      runs: runs,
      chat_id: chat && chat.id,
      views: views,
      needs: needs,
      hint?: is_map(hint),
      labels: labels
    }
  end

  # -------------------------------------------------------------- layout

  # Candidates from the richest to the most folded; the first that fits wins,
  # and the last one is cut to the height with a count of what is left out.
  # Each candidate is a function, built only when the richer ones did not
  # fit: most frames stop at the first.
  # pass 75 V2 (7.6): every candidate ends with the keys row and the rows
  # are top-anchored; blank rows fill the pane below them.
  defp layout(ctx, height) do
    all = candidates(ctx)

    Enum.find_value(all, fn build ->
      rows = build.()
      if length(drawn(rows)) <= height, do: fill(rows, height, ctx)
    end) ||
      (
        # The spent, earlier and keys rows stay whole under the cut rows.
        {body, [_blank | tail]} =
          Enum.split(List.last(all).(), -length(tail_rows(ctx, ctx.mode == :full)))

        cut(body, tail, height, ctx)
      )
  end

  defp fill(rows, height, ctx),
    do: rows ++ List.duplicate(blank(ctx), max(0, height - length(drawn(rows))))

  # The last candidate still does not fit: keep what fits and say how many
  # agents are left out; the footer goes first when even that is too tall.
  defp cut(rows, footer, height, ctx) do
    footer = if height >= 8, do: footer, else: []
    room = max(0, height - length(footer))

    # pass73 T9 (K's `panel_scroll`, the wheel over the panel): the drawn
    # rows scroll by what the wheel asked, as far as the overflow goes; the
    # needs-you band stays pinned (R3).
    drawn = Enum.count(rows, &(elem(&1, 0) != nil))

    skip =
      min(max(0, Map.get(ctx.state, :panel_scroll, 0) || 0), max(0, drawn - max(room - 1, 0)))

    rows = scrolled(rows, skip)

    {kept, _} =
      Enum.reduce_while(rows, {[], 0}, fn r, {acc, n} ->
        cond do
          is_nil(elem(r, 0)) -> {:cont, {[r | acc], n}}
          n < room - 1 -> {:cont, {[r | acc], n + 1}}
          true -> {:halt, {acc, n}}
        end
      end)

    kept = Enum.reverse(kept)
    shown = kept |> Enum.map(&elem(&1, 1)) |> MapSet.new()

    left =
      rows
      |> Enum.count(fn {b, target, _o} ->
        b != nil and match?({:agent, _, _, _}, target) and not MapSet.member?(shown, target)
      end)

    words =
      cond do
        left > 0 and skip > 0 -> "+#{left} more · more above · Ctrl-G all runs"
        left > 0 -> "+#{left} more · Ctrl-G all runs"
        skip > 0 -> "more above · Ctrl-G all runs"
        true -> "more below · Ctrl-G all runs"
      end

    more = if room >= 1, do: [row(ctx, [{words, :text_faint}], [])], else: []
    kept ++ more ++ footer
  end

  defp scrolled(rows, 0), do: rows

  defp scrolled(rows, skip) do
    {kept, _} =
      Enum.flat_map_reduce(rows, skip, fn {block, _target, opts} = row, left ->
        if left == 0 or block == nil or Keyword.get(opts, :band, false),
          do: {[row], left},
          else: {[], left - 1}
      end)

    kept
  end

  # Where the band goes: inside the full body, after the headers (V2, S3);
  # first in compact.
  defp candidates(%{mode: :full} = ctx), do: bodies(ctx, [])

  defp candidates(ctx) do
    case band_rows(ctx) do
      [] -> bodies(ctx, [])
      band -> Enum.map(bodies(ctx, []), fn build -> fn -> band ++ [blank(ctx) | build.()] end end)
    end
  end

  # pass 75 V2 (D2): one body for every shown run: the in-chat run's header,
  # one row per other run, the band, the kind sections, the found blocks,
  # one agents block, then the spent, earlier and keys rows. Tighter
  # candidates drop the finished agents' conclusions, then the why-lines and
  # the kind sections.
  defp bodies(%{mode: :full} = ctx, _band) do
    [chat | others] = runs = ordered(ctx)
    pairs = Enum.map(runs, &{&1, Map.get(ctx.views, &1.id, [])})
    headers = run_header_full(ctx, chat) ++ Enum.map(others, &launched_row(ctx, &1))

    band = band_rows(ctx)
    kinds = kind_rows(ctx, pairs)
    agents = agent_rows(ctx, pairs)
    tail = tail_rows(ctx, true)

    # One blank row between the blocks that are drawn (air, not rules). In the
    # full candidate one also parts a run's found block from the next (task
    # 145: "then a blank row"), so a run's refs never run into the next
    # `found`; the tighter ones are the found, gauge and why rows only (147a).
    for level <- [:full, :summary, :bare] do
      fn ->
        found =
          runs
          |> Enum.map(&found_rows(ctx, &1, level))
          |> Enum.reject(&(&1 == []))
          |> Enum.intersperse(if level == :full, do: [blank(ctx)], else: [])
          |> Enum.concat()

        kinds = if level == :bare, do: [], else: kinds

        [headers, band, kinds, found, agents]
        |> Enum.reject(&(&1 == []))
        |> Enum.intersperse([blank(ctx)])
        |> Enum.concat()
        |> Kernel.++(tail)
      end
    end
  end

  defp bodies(%{mode: :compact} = ctx, _band) do
    [chat | others] = ordered(ctx)

    # Fold the other runs from the last one up (D5), then drop earlier runs.
    # The unfolded rows of each run are drawn once and shared by the folds.
    chat_rows = unfold_compact(ctx, chat)
    open_rows = Map.new(others, &{&1.id, unfold_compact(ctx, &1)})

    folds =
      for k <- 0..length(others) do
        fn ->
          {open, folded} = Enum.split(others, length(others) - k)

          chat_rows ++
            Enum.flat_map(open, &Map.fetch!(open_rows, &1.id)) ++
            Enum.map(folded, &run_header_compact(ctx, &1))
        end
      end

    with_earlier = Enum.map(folds, fn build -> fn -> build.() ++ tail_rows(ctx, true) end end)
    without = Enum.map(folds, fn build -> fn -> build.() ++ tail_rows(ctx, false) end end)
    with_earlier ++ without
  end

  # Review P-1 (spec Blockers, 153b, the owner's decision): the kind sections
  # stay for workflow and consensus runs only: a workflow's phases (the
  # pipeline, the live phase, `phases N of M done`) and a consensus run's
  # positions, agreement, criteria and the judge's words. Goal and research
  # runs draw none. One blank row parts the parts of a section (never two)
  # and one run's section from the next.
  defp kind_rows(ctx, pairs) do
    b = blank(ctx)

    pairs
    |> Enum.filter(fn {run, _views} -> Model.kind(run) in [:workflow, :consensus_judge] end)
    |> Enum.map(fn {run, views} ->
      (Shapes.before_agents(ctx, run, views, false) ++
         Shapes.after_agents(ctx, run, views, false))
      |> Enum.reduce([], fn
        ^b, [] -> []
        ^b, [^b | _] = acc -> acc
        row, acc -> [row | acc]
      end)
      |> Enum.drop_while(&(&1 == b))
      |> Enum.reverse()
    end)
    |> Enum.reject(&(&1 == []))
    |> Enum.intersperse([b])
    |> Enum.concat()
  end

  # The panel's tail (7.4-7.6): a blank row, what the shown runs spent, the
  # earlier row, the keys.
  defp tail_rows(ctx, earlier?) do
    [blank(ctx), spent_row(ctx)] ++
      if(earlier?, do: earlier_rows(ctx), else: []) ++ footer_rows(ctx)
  end

  # pass 75 (7.4, 9.3): `spent $0.82 · 4.1M tokens · 2 runs`, the priced
  # runs' sum and every run's tokens; tokens only when no run is priced.
  defp spent_row(ctx) do
    pairs = Enum.map(ctx.runs, &{&1, Map.get(ctx.views, &1.id, [])})
    priced = Enum.filter(ctx.runs, &is_number(&1.cost_usd))
    tokens = pairs |> Enum.map(fn {run, views} -> tokens(run, views) end) |> Enum.sum()
    tokens = Model.tokens(tokens) || "0"
    words = count(length(ctx.runs), "run", "runs")

    left =
      case priced do
        [] ->
          [{"spent ", :text_faint}, {"#{tokens} tokens · " <> words, :text_muted}]

        _ ->
          money = priced |> Enum.map(& &1.cost_usd) |> Enum.sum() |> Model.money()

          plus =
            case plus(pairs) do
              "" -> []
              mark -> [{mark, :text_faint}]
            end

          [{"spent ", :text_faint}, {money, :text_primary}] ++
            plus ++ [{" · #{tokens} tokens · " <> words, :text_muted}]
      end

    row(ctx, left, [])
  end

  # The run in chat first (when no run is in chat, the newest live run
  # leads), then the other shown runs in the order they started (V2, 6.1).
  defp ordered(%{runs: [first | others]}),
    do: [first | Enum.sort_by(others, &{&1.started_at || 0, &1.created_sequence, &1.id})]

  # --------------------------------------------------------------- rows

  @doc false
  def row(ctx, left, right \\ [], opts \\ []) do
    {Draw.row(left, right, ctx.width, ctx.state, Keyword.take(opts, [:background, :margin])), nil,
     Keyword.drop(opts, [:background, :margin])}
  end

  @doc false
  def blank(ctx), do: {Draw.blank(ctx.width, ctx.state), nil, []}

  # Rows that are drawn (a folded run's hidden needs-you targets are not).
  defp drawn(rows), do: Enum.reject(rows, &is_nil(elem(&1, 0)))

  defp target({block, _t, opts}, target), do: {block, target, opts}

  @doc false
  def g(ctx, token), do: Draw.g(token, ctx.state)

  defp empty(ctx, height) do
    rows = [
      row(ctx, [{"No run in this chat yet", :text_muted}], []),
      blank(ctx),
      row(ctx, [{"Ctrl-G", :text_muted}, {"  all runs", :text_faint}], [])
    ]

    fill(Enum.take(rows ++ footer_rows(ctx), height), height, ctx)
  end

  # ------------------------------------------------------------ the band

  defp band_rows(%{needs: []}), do: []

  # pass 75 V2 (7.2, SA S3): one band for every shown run, oldest first:
  # `! 2 need you · oldest first   ^N answer`, then per request its agent
  # (` │ ⋔ Docs accuracy wants to run   0:41`), up to two rows of what it
  # asks and one row of why. No fill.
  defp band_rows(ctx) do
    n = length(ctx.needs)
    cap = if ctx.mode == :compact, do: 2, else: 3
    shown = Enum.take(ctx.needs, cap)
    right = if ctx.hint?, do: again_key(ctx), else: answer_key(ctx)
    words = if n == 1, do: " 1 needs you", else: " #{n} need you"

    head =
      row(
        ctx,
        [
          {"!", :warning, [:bold]},
          {words, :warning, [:bold]},
          {" · oldest first", :text_muted}
        ],
        right,
        band: true
      )

    items = Enum.flat_map(shown, fn {ask, run, view} -> band_request(ctx, ask, run, view) end)

    more =
      if n > cap,
        do: [
          row(ctx, [{"  +#{n - cap} more · ^N goes through them", :text_faint}], [], band: true)
        ],
        else: []

    [head | items] ++ more
  end

  defp band_request(ctx, ask, run, view) do
    state = ctx.state
    bar = {g(ctx, :pipe), :warning}
    name = (view && view.display) || "Lead"
    role = (view && view.name_role) || :text_primary
    verb = if ask.verb == :question, do: " asks", else: " wants to run"
    age = band_age(ask, state)
    age_cells = if age, do: Draw.cells(age, state) + 1, else: 0

    lead =
      case badge_for(ctx, view) do
        nil -> [bar, {" ", :plain}]
        badge -> [bar, {" ", :plain}] ++ badge_segments(ctx, badge)
      end

    room = ctx.width - 2 - cells(lead, state) - 2 - Draw.cells(verb, state) - age_cells

    first =
      row(
        ctx,
        lead ++
          [
            {Draw.mark(Model.kind(run), state), Model.kind_role(run)},
            {" ", :plain},
            {Draw.elide(name, max(4, room), state), role},
            {verb, :text_muted}
          ],
        if(age, do: [{age, :text_faint}], else: []),
        band: true
      )

    inner = ctx.width - 2 - 4
    {text, reason} = band_words(ask, run, ctx)

    body =
      text
      |> Draw.wrap(inner, 2, state)
      |> Enum.map(&row(ctx, [bar, {"   " <> &1, :text_primary}], [], band: true))

    why =
      if reason, do: [row(ctx, [bar, {"   " <> reason, :text_faint}], [], band: true)], else: []

    band_target([first | body] ++ why, view)
  end

  # What a request asks and why (7.2, 18.3): a command flattened, a
  # question by its headers and how it may be answered.
  defp band_words(%{verb: :question} = ask, _run, _ctx) do
    k = Map.get(ask, :options, 0)

    reason =
      cond do
        k >= 2 -> "#{k} options, or your own words"
        k == 1 -> "1 option, or your own words"
        true -> "your own words"
      end

    case Map.get(ask, :questions, []) do
      [] -> {ask.text, reason}
      [header] -> {"1 question: " <> header, reason}
      headers -> {"#{length(headers)} questions: " <> Enum.join(headers, ", "), nil}
    end
  end

  defp band_words(ask, run, ctx) do
    reason =
      if dangerous?(ask, ctx.state),
        do: "dangerous: asks even in full access",
        else: reason(ask, run, ctx)

    {Model.flat(ask.text), reason}
  end

  defp dangerous?(ask, state) do
    Enum.any?(Map.values(state.read_model.interactions), fn interaction ->
      interaction.state == :pending and
        (interaction.id == ask.id or
           (is_binary(ask.node_id) and interaction.node_id == ask.node_id)) and
        match?(%{classification: c} when c in [:dangerous, "dangerous"], interaction.approval)
    end)
  end

  # M10: how long ago a request came, `0:41`, only for a wire entry whose
  # unix-ms time is at or before now and under a day old.
  defp band_age(%{source: :wire, at: at}, %{now: now})
       when is_integer(at) and is_integer(now) and at <= now and now - at < 86_400_000,
       do: Model.short_clock(now - at)

  defp band_age(_ask, _state), do: nil

  # pass72 G8 (QA Q9): a band row is the drawn entry of its agent, so the
  # hint letters follow what the band shows, oldest first; a request past the
  # band's cap ("+2 more") gets no letter and is reached with ^N.
  defp band_target([first | rest], %{run_id: run, id: id}),
    do: [target(first, {:agent, run, id, true}) | rest]

  defp band_target(rows, _view), do: rows

  defp answer_key(%{hint?: true} = ctx), do: again_key(ctx)
  defp answer_key(_ctx), do: [{"^N", :text_primary, [:bold]}, {" answer", :text_muted}]
  defp again_key(_ctx), do: [{"^F", :text_primary, [:bold]}, {" again", :text_muted}]

  # Why it asks: what it wants to do and the project's approval mode. A
  # question never reaches here: `band_words/3` answers it first (18.3).
  defp reason(ask, _run, ctx) do
    verb =
      case ask.verb do
        :command -> "run a command"
        :edit -> "edit a file"
        # pass73 G2 (QA Q2-07): not "use workflow run".
        :workflow -> "run a workflow"
        {:tool, tool} -> "use " <> tool
        _ -> "go ahead"
      end

    case approval_mode(ctx.state) do
      :read_only -> verb <> " · read-only asks"
      # pass72 G19 (QA Q19): short enough to stand beside "^N answer".
      :auto -> verb <> " · auto asks"
      _ -> verb
    end
  end

  defp approval_mode(state) do
    case Map.get(state.read_model.snapshots, :workspace) do
      %{approval_mode: mode} -> mode
      _ -> nil
    end
  end

  # ----------------------------------------------------------- badges

  defp badge_for(%{hint?: false}, _view), do: nil
  defp badge_for(_ctx, nil), do: nil

  defp badge_for(ctx, view),
    do: Map.get(ctx.labels, {:agent, view.run_id, view.id})

  defp run_badge(%{hint?: false}, _run), do: nil
  defp run_badge(ctx, run), do: Map.get(ctx.labels, {:run, run.id})

  defp badge_segments(ctx, label) do
    text = Draw.pad_to(" " <> label, 3, ctx.state)
    [{text, :on_accent, [:bold]}, {" ", :plain}]
  end

  # -------------------------------------------------------- run headers

  # pass 75 V2 (7.1): the in-chat run's two rows. Row 1 has no margin: the
  # accent `▌` at column 0, the mark at 1, the bold title at 3 (end-cut, so
  # the pane's last cell stays its margin). Row 2 from column 3: kind, place,
  # tokens and the price when there is one, the clock on the right.
  defp run_header_full(ctx, run) do
    state = ctx.state
    clock = run |> Model.elapsed(state) |> Model.clock()
    views = Map.get(ctx.views, run.id, [])

    words =
      [
        "#{kind_word(run)}",
        if(run.id == ctx.chat_id, do: "in chat"),
        Model.tokens(tokens(run, views))
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    words =
      case Model.money(run.cost_usd) do
        nil -> words
        money -> words <> " · " <> money <> plus([{run, views}])
      end

    indent = if run_badge(ctx, run), do: "      ", else: "  "
    right = if clock && not ctx.hint?, do: [{clock, :text_muted}], else: []
    [header_row(ctx, run), row(ctx, [{indent <> words, :text_faint}], right)]
  end

  # Row 1 of a header (full and compact): `▌` (the in-chat run) or a blank,
  # the mark and the bold title, target the run; the hint badge first.
  defp header_row(ctx, run) do
    state = ctx.state
    in_chat? = run.id == ctx.chat_id
    badge = run_badge(ctx, run)
    lead = if badge, do: badge_segments(ctx, badge), else: []
    bar = if in_chat?, do: [{g(ctx, :in_chat), :accent}], else: [{" ", :plain}]
    title_role = if ctx.hint?, do: :text_faint, else: :text_primary
    title_mods = if ctx.hint?, do: [], else: [:bold]
    room = ctx.width - cells(lead, state) - 3 - 1

    row(
      ctx,
      lead ++
        bar ++
        [
          {Draw.mark(Model.kind(run), state), Model.kind_role(run), [:bold]},
          {" ", :plain},
          {Draw.elide(Model.title(run), max(4, room), state), title_role, title_mods}
        ],
      [],
      margin: 0
    )
    |> target({:run, run.id})
  end

  defp run_header_compact(ctx, run), do: header_row(ctx, run)

  # pass 75 V2 (7.1): a shown run that is not the in-chat run, on one row:
  # its mark at 1, its title muted at 3, a swarm's `R of T in`, the clock.
  defp launched_row(ctx, run) do
    state = ctx.state
    views = Map.get(ctx.views, run.id, [])
    clock = run |> Model.elapsed(state) |> Model.clock()
    badge = run_badge(ctx, run)
    lead = if badge, do: badge_segments(ctx, badge), else: []

    count =
      case Model.kind(run) do
        :swarm ->
          {reported, total} = Shapes.reported(run, views)
          [{"  ", :plain}, {"#{reported} of #{total} in", :text_faint}]

        _ ->
          []
      end

    right = if clock && not ctx.hint?, do: [{clock, :text_muted}], else: []
    right_cells = if right == [], do: 0, else: Draw.cells(clock, state) + 1
    room = ctx.width - 2 - cells(lead, state) - 2 - cells(count, state) - right_cells

    row(
      ctx,
      lead ++
        [
          {Draw.mark(Model.kind(run), state), Model.kind_role(run)},
          {" ", :plain},
          {Draw.elide(Model.title(run), max(4, room), state),
           if(ctx.hint?, do: :text_faint, else: :text_muted)}
        ] ++ count,
      right
    )
    |> target({:run, run.id})
  end

  # The run kind as a word: `consensus`, `chat`, `swarm`, `workflow`, …
  defp kind_word(run) do
    case Model.kind(run) do
      :consensus_judge -> "consensus"
      :assistant -> "chat"
      kind -> Atom.to_string(kind)
    end
  end

  # A run's tokens: its own count, else its agents'.
  defp tokens(run, views) do
    case Model.token_count(run) do
      0 -> views |> Enum.map(&(&1.tokens || 0)) |> Enum.sum()
      n -> n
    end
  end

  # 9.3: a price that leaves out an agent with tokens but no price of its
  # own reads `$0.01+`.
  defp plus(pairs) do
    unpriced? =
      Enum.any?(pairs, fn {run, views} ->
        is_number(run.cost_usd) and
          Enum.any?(views, &(is_integer(&1.tokens) and &1.tokens > 0 and is_nil(&1.cost)))
      end)

    if unpriced?, do: "+", else: ""
  end

  # --------------------------------------------------------- found

  # pass 75 V2 (7.3): what the run has produced so far. `found  R of T in`,
  # the gauge, why the report is not in yet (not at `level` `:bare`); then,
  # at `:full`, each finished agent's `✓` row, its conclusion and its refs,
  # and the Lead's report once it is done. Nothing without sub agents.
  defp found_rows(ctx, run, level) do
    state = ctx.state
    views = Map.get(ctx.views, run.id, [])
    subs = Enum.reject(views, &(&1.role in [:lead, :assistant]))

    if subs == [] do
      []
    else
      {r, t} = Shapes.reported(run, views)
      ratio = "#{r} of #{t} in"
      files = " · " <> files_words(Map.get(run, :files_changed))

      # `R of T in` at column 17; the gap gives way first where a wide `·`
      # would push the files words past the row.
      slack = ctx.width - 2 - Draw.cells("found" <> ratio <> files, state)
      pad = String.duplicate(" ", max(1, min(16 - Draw.cells("found", state), slack)))

      count =
        row(ctx, [
          {"found" <> pad, :text_muted},
          {ratio, :text_muted},
          {files, :text_faint}
        ])

      gauge =
        row(
          ctx,
          [{Draw.mark(Model.kind(run), state), Model.kind_role(run)}, {" ", :plain}] ++
            Shapes.report_gauge(subs, ctx.width, state)
        )

      why =
        case level != :bare && Shapes.why_line(run, subs, state) do
          words when is_binary(words) -> [row(ctx, [{"  " <> words, :text_faint}])]
          _ -> []
        end

      details = if level == :full, do: found_details(ctx, run, views, subs), else: []
      details = if details == [], do: [], else: [blank(ctx) | details]

      Enum.map([count, gauge | why], &target(&1, {:run, run.id})) ++ details
    end
  end

  defp files_words(n) when is_integer(n) and n > 0, do: count(n, "file changed", "files changed")
  defp files_words(_), do: "no files changed"

  # Each finished sub agent in the order it finished, one blank row between,
  # then the Lead's report.
  defp found_details(ctx, run, views, subs) do
    done =
      subs
      |> Enum.filter(&(&1.state == :done))
      |> Enum.sort_by(&finished_key/1)
      |> Enum.map(&found_agent(ctx, run, &1))

    lead =
      case Enum.find(views, &(&1.role == :lead and &1.state == :done)) do
        nil -> []
        view -> [found_lead(ctx, run, view)]
      end

    (done ++ lead) |> Enum.intersperse([blank(ctx)]) |> List.flatten()
  end

  defp finished_key(view) do
    case Map.get(view, :finished_at) do
      at when is_integer(at) -> {0, at}
      _ -> {1, 0}
    end
  end

  defp found_agent(ctx, run, view) do
    state = ctx.state
    target = {:agent, run.id, view.id, false}

    head =
      row(
        ctx,
        found_lead_in(ctx, view) ++ [{view.display, view.name_role}],
        found_meta(view)
      )

    headline =
      case view.finding do
        nil ->
          []

        finding ->
          Enum.map(
            Draw.wrap(finding, ctx.width - 6, 2, state),
            &row(ctx, [{"    " <> &1, :text_primary}])
          )
      end

    refs =
      case {view.finding, view.refs} do
        {finding, [_ | _] = refs} when is_binary(finding) ->
          [row(ctx, [{"    " <> Enum.join(refs, " · "), :text_faint}])]

        _ ->
          []
      end

    Enum.map([head | headline], &target(&1, target)) ++ refs
  end

  # The Lead's report (S4): `✓ Lead · the report`, its headline, where to read it.
  defp found_lead(ctx, run, view) do
    state = ctx.state

    head =
      row(
        ctx,
        found_lead_in(ctx, view) ++
          [{"Lead", :text_primary, [:bold]}, {" · the report", :text_muted}],
        found_meta(view)
      )
      |> target({:agent, run.id, view.id, false})

    headline =
      case view.finding do
        nil ->
          []

        finding ->
          Enum.map(
            Draw.wrap(finding, ctx.width - 6, 2, state),
            &row(ctx, [{"    " <> &1, :text_primary}])
          )
      end

    reported =
      row(ctx, [
        {"    reported · ", :text_faint},
        {"^F", :text_muted, [:bold]},
        {" reads it", :text_faint}
      ])

    not_covered =
      case Map.get(run, :not_covered) do
        n when is_integer(n) and n > 0 and run.state == :done ->
          [row(ctx, [{"    not covered", :text_muted}], [{Integer.to_string(n), :text_muted}])]

        _ ->
          []
      end

    [head | headline] ++ [reported | not_covered]
  end

  # `  ✓ ` before a finished agent's name, or its hint badge.
  defp found_lead_in(ctx, view) do
    case badge_for(ctx, view) do
      nil -> [{"  " <> g(ctx, :done), :success}, {" ", :plain}]
      badge -> badge_segments(ctx, badge) ++ [{g(ctx, :done), :success}, {" ", :plain}]
    end
  end

  # A found row's right side: the clock and the tokens, never money (R9.1).
  defp found_meta(view) do
    case meta(view) do
      nil -> []
      words -> [{words, :text_faint}]
    end
  end

  # -------------------------------------------------------- full blocks

  # ------------------------------------------------------------ agents

  # pass 75 V2 (6.1-6.6): one block for the shown runs, `runs_in_order` the
  # in-chat run first. A title row `agents   N live · M stopped`, then one
  # row per agent that is not done (a done agent is in `found`), each run's
  # rows sorted by attention, ties in wire order. `status?` false drops the
  # status text (compact, 7.9).
  defp agent_rows(ctx, runs_in_order, status? \\ true) do
    rows_by_run =
      Enum.map(runs_in_order, fn {run, views} ->
        shown =
          views
          |> Enum.with_index()
          |> Enum.reject(fn {view, _} -> view.state == :done end)
          |> Enum.sort_by(fn {view, i} -> {view.attention, i} end)
          |> Enum.map(&elem(&1, 0))

        {run, shown}
      end)

    all = Enum.flat_map(rows_by_run, &elem(&1, 1))

    if all == [] do
      []
    else
      live = Enum.count(all, &(&1.state in [:working, :thinking, :needs_you]))
      stopped = Enum.count(all, &(&1.state in [:failed, :turn_limit, :stopped]))

      words =
        [if(live > 0, do: "#{live} live"), if(stopped > 0, do: "#{stopped} stopped")]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" · ")

      col = name_column(all, ctx.state)
      title = row(ctx, [{"agents", :text_muted}], [{words, :text_faint}])

      rows =
        Enum.flat_map(rows_by_run, fn {run, shown} ->
          shown
          |> Enum.with_index()
          |> Enum.map(fn {view, i} -> agent_row(ctx, view, run, col, i == 0, status?) end)
        end)

      [title | rows]
    end
  end

  # The name column: the widest name shown and two cells, at most 24 (6.5).
  defp name_column(views, state) do
    widest = views |> Enum.map(&Draw.cells(&1.display, state)) |> Enum.max(fn -> 0 end)
    min(24, widest + 2)
  end

  # `<mark> <glyph> <name> <status>   <figure>`: the mark on the run's first
  # row only, the name in its hue, the status cut at its end, the figure
  # ending at the row's last cell (6.3-6.6).
  defp agent_row(ctx, view, run, col, first?, status?) do
    state = ctx.state
    {token, glyph_role} = agent_glyph(view.state)
    figure = Map.get(view, :figure)
    figure_cells = if figure, do: Draw.cells(elem(figure, 0), state), else: 0
    gap = if figure, do: 1, else: 0
    dim = fn role -> if ctx.hint?, do: :text_faint, else: role end

    mark =
      case badge_for(ctx, view) do
        nil when ctx.hint? ->
          [{"    ", :plain}]

        nil ->
          [
            {if(first?, do: Draw.mark(Model.kind(run), state), else: " "), Model.kind_role(run)},
            {" ", :plain}
          ]

        badge ->
          badge_segments(ctx, badge)
      end

    glyph_mods = if view.state == :needs_you, do: [:bold], else: []
    # A name wider than the column ends in `…` one cell short of it, so a
    # space always parts it from the status (6.5).
    name = Draw.pad_to(Draw.elide(view.display, min(24, col - 1), state), col, state)

    status =
      if status? do
        {text, role} = view.status_text
        # The prefix before the name: mark, space, glyph, space (4 cells);
        # in hint mode the badge or its blank takes 4 cells, not 2.
        prefix = if ctx.hint?, do: 6, else: 4
        room = max(0, ctx.width - 2 - prefix - col - figure_cells - gap)
        text = if room == 0, do: "", else: Draw.elide(text, room, state)
        [{text, dim.(role)}]
      else
        []
      end

    row(
      ctx,
      mark ++
        [{g(ctx, token), glyph_role, glyph_mods}, {" ", :plain}, {name, dim.(view.name_role)}] ++
        status,
      if(figure, do: [figure], else: [])
    )
    |> target({:agent, run.id, view.id, view.state == :needs_you})
  end

  defp agent_glyph(state) when state in [:working, :thinking], do: {:agent_live, :text_primary}
  defp agent_glyph(:needs_you), do: {:bang, :warning}
  defp agent_glyph(:turn_limit), do: {:turn_limit, :error}
  defp agent_glyph(state) when state in [:failed, :stopped], do: {:failed, :error}
  defp agent_glyph(_waiting_queued_or_paused), do: {:waiting, :text_primary}

  # The run's clock and tokens (a found row's right side).
  defp meta(view) do
    [Model.short_clock(view.elapsed), Model.tokens(view.tokens)]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  # ------------------------------------------------------ compact rows

  # 7.9: the header's row 1, the found row, one row per agent that is not
  # done with its figure only.
  defp unfold_compact(ctx, run) do
    views = Map.get(ctx.views, run.id, [])

    found =
      case found_rows(ctx, run, :bare) do
        [count | _] -> [count]
        [] -> []
      end

    rows =
      case agent_rows(ctx, [{run, views}], false) do
        [_title | rows] -> rows
        [] -> []
      end

    note = Shapes.compact_note(ctx, run, views)
    [run_header_compact(ctx, run)] ++ found ++ rows ++ note
  end

  # --------------------------------------------------- earlier and legend

  defp earlier_rows(ctx), do: Shapes.earlier(ctx)

  # pass 75 V2 (7.6): the keys row, no rule above it.
  defp footer_rows(ctx) do
    keys =
      cond do
        ctx.hint? ->
          letters = ctx.labels |> Map.values() |> Enum.filter(&(String.length(&1) == 1))
          letters = letters |> Enum.reject(&(&1 =~ ~r/^\d$/)) |> Enum.uniq()
          digits = ctx.labels |> Map.values() |> Enum.filter(&(&1 =~ ~r/^\d$/)) |> Enum.sort()

          span =
            case letters do
              [] ->
                nil

              [one] ->
                one

              many ->
                List.first(Enum.sort_by(many, &order/1)) <>
                  "-" <> List.last(Enum.sort_by(many, &order/1))
            end

          run_span =
            case digits do
              [] -> nil
              [one] -> one
              many -> List.first(many) <> "-" <> List.last(many)
            end

          row(
            ctx,
            Enum.reject(
              [
                span && {span, :text_primary},
                span && {" open", :text_faint},
                run_span && {"  ", :plain},
                run_span && {run_span, :text_primary},
                run_span && {" run", :text_faint},
                {"  ", :plain},
                {"^F", :text_primary},
                {" again: needs you", :text_faint},
                # pass72 G8 (QA Q18): D7's Esc, never run into the words;
                # two-space gaps so the row fits 44 cells.
                {"  ", :plain},
                {"Esc", :text_primary}
              ],
              &is_nil/1
            ),
            []
          )

        true ->
          row(ctx, [
            {"^F", :text_muted, [:bold]},
            {" agents  ", :text_faint},
            {"^N", :text_muted, [:bold]},
            {" needs you  ", :text_faint},
            {"^B", :text_muted, [:bold]},
            {" panel", :text_faint}
          ])
      end

    [keys]
  end

  @hint_order ~w(s d f g h j k l w e r t u i o p)
  defp order(label), do: Enum.find_index(@hint_order, &(&1 == label)) || 99

  # ------------------------------------------------------------ helpers

  defp cells(segments, state) do
    Enum.reduce(segments, 0, fn
      {text, _role}, acc -> acc + Draw.cells(text, state)
      {text, _role, _mods}, acc -> acc + Draw.cells(text, state)
    end)
  end

  @doc false
  def count(1, one, _many), do: "1 " <> one
  def count(n, _one, many), do: "#{n} " <> many

  @doc false
  def changes(ctx, run), do: Changes.changes(ctx.state, run)

  # Hint targets (owner O's `Hint.labels/1`) name an agent as `{:agent, run, node}`;
  # the drawn entries carry the needs-you flag as well. Badges key on the former.
  defp hint_key({:agent, run, node, _needs?}), do: {:agent, run, node}
  defp hint_key(target), do: target
end
