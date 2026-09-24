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
  alias SwarmCodeCLI.UI.Projector.Panel.{Draw, Model, Name, Shapes}
  alias SwarmCodeCLI.UI.Projector.Inspector.Changes

  @full_lane 12
  @compact_lane 8
  # The compact name column: the widest name and one cell. pass73 T10: it is
  # the agent's one name (`Panel.Name`), cut at its end with `…` only where
  # the sentence would keep fewer than 14 cells (16 cells of name in a
  # 46-cell pane), never a different, shorter word.
  defp short_field(ctx) do
    widest =
      ctx.views
      |> Map.values()
      |> List.flatten()
      |> Enum.map(&Draw.cells(&1.display, ctx.state))
      |> Enum.max(fn -> 4 end)

    badge = if ctx.hint?, do: 2, else: 0
    min(max(5, widest + 1), max(5, ctx.width - 29 - badge))
  end

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
  defp layout(ctx, height) do
    all = candidates(ctx)

    Enum.find_value(all, fn build ->
      rows = build.()
      footer = legend(ctx, rows) ++ footer_rows(ctx)
      if length(drawn(rows)) + length(footer) <= height, do: fill(rows, footer, height, ctx)
    end) || cut(List.last(all).(), footer_rows(ctx), height, ctx)
  end

  defp fill(rows, footer, height, ctx) do
    blank = List.duplicate(blank(ctx), max(0, height - length(drawn(rows)) - length(footer)))
    rows ++ blank ++ footer
  end

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

  # Where the band goes (R3, D2): under the run's header when one run is
  # live, under the load row when there are more (D6), and first in compact.
  defp candidates(ctx) do
    band = band_rows(ctx)
    summary = summary_rows(ctx)

    cond do
      length(ctx.runs) > 1 ->
        Enum.map(bodies(ctx, []), fn build -> fn -> summary ++ band ++ build.() end end)

      ctx.mode == :compact and band != [] ->
        Enum.map(bodies(ctx, []), fn build -> fn -> band ++ [blank(ctx) | build.()] end end)

      true ->
        bodies(ctx, band)
    end
  end

  defp bodies(%{mode: :full} = ctx, band) do
    [chat | others] = ordered(ctx)

    [
      fn ->
        unfold_full(ctx, chat, band, true) ++ Enum.flat_map(others, &orbit(ctx, &1, true))
      end,
      fn ->
        unfold_full(ctx, chat, band, false) ++ Enum.flat_map(others, &orbit(ctx, &1, true))
      end,
      fn ->
        unfold_full_tight(ctx, chat, band) ++ Enum.flat_map(others, &orbit(ctx, &1, false))
      end
    ]
  end

  defp bodies(%{mode: :compact} = ctx, _band) do
    [chat | others] = ordered(ctx)
    earlier = earlier_rows(ctx)

    # Fold the other runs from the last one up (D5), then drop earlier runs,
    # then collapse done agents.
    # The unfolded rows of each run are drawn once and shared by the folds.
    chat_rows = unfold_compact(ctx, chat, false)
    open_rows = Map.new(others, &{&1.id, unfold_compact(ctx, &1, false)})

    folds =
      for k <- 0..length(others) do
        fn ->
          {open, folded} = Enum.split(others, length(others) - k)

          chat_rows ++
            Enum.flat_map(open, &Map.fetch!(open_rows, &1.id)) ++
            Enum.flat_map(folded, &orbit(ctx, &1, true))
        end
      end

    with_earlier = Enum.map(folds, fn build -> fn -> build.() ++ earlier end end)

    collapsed = fn ->
      unfold_compact(ctx, chat, true) ++ Enum.flat_map(others, &orbit(ctx, &1, false))
    end

    with_earlier ++ folds ++ [collapsed]
  end

  # The run in chat first; when no run is in chat, the newest live run leads.
  defp ordered(ctx), do: ctx.runs

  # --------------------------------------------------------------- rows

  @doc false
  def row(ctx, left, right \\ [], opts \\ []) do
    {Draw.row(left, right, ctx.width, ctx.state, Keyword.take(opts, [:background])), nil,
     Keyword.drop(opts, [:background])}
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

    fill(Enum.take(rows, height), Enum.take(footer_rows(ctx), max(0, height - 3)), height, ctx)
  end

  # Row 0 (D1): the whole load, when more than one run is live.
  defp summary_rows(%{runs: runs}) when length(runs) < 2, do: []

  defp summary_rows(ctx) do
    agents = ctx.views |> Map.values() |> List.flatten()
    live = Enum.count(agents, &(&1.state not in [:done, :failed, :stopped]))
    cost = ctx.runs |> Enum.map(&(Map.get(&1, :cost_usd) || 0)) |> Enum.sum()

    rest =
      [count(length(agents), "agent", "agents"), "#{live} live", Model.money(cost)]
      |> Enum.reject(&is_nil/1)
      |> Enum.map_join("", &(" · " <> &1))

    [row(ctx, [{count(length(ctx.runs), "run", "runs"), :text_primary}, {rest, :text_faint}], [])] ++
      if(ctx.mode == :compact and ctx.needs == [], do: [blank(ctx)], else: [])
  end

  # ------------------------------------------------------------ the band

  defp band_rows(%{needs: []}), do: []

  defp band_rows(%{needs: [{ask, run, view}]} = ctx) when ctx.mode == :full do
    state = ctx.state
    name = (view && view.display) || "the Lead"
    name_role = (view && view.name_role) || :text_primary
    question? = ask.verb == :question
    title_name = if question?, do: name <> " asks", else: name

    head =
      row(
        ctx,
        [{"! NEEDS YOU", :warning, [:bold]}, {" · ", :text_muted}, {title_name, name_role}],
        [{"1 waiting", :text_muted}],
        band: true,
        background: :card
      )

    inner = ctx.width - 5

    # pass73 T10: a command or a file is one row, cut with `…` (the card and
    # the overlay show it whole); a question may take three.
    request =
      if question?,
        do: Draw.wrap(ask.text, inner, 3, state),
        else: [Draw.elide(Model.flat(ask.text), inner, state)]

    badge = badge_for(ctx, view)

    body =
      request
      |> Enum.with_index()
      |> Enum.map(fn {line, i} ->
        lead = if i == 0 and badge, do: badge_segments(ctx, badge), else: [{"  ", :plain}]
        row(ctx, lead ++ [{line, :text_primary, [:bold]}], [], band: true, background: :card)
      end)
      |> band_target(view)

    tail =
      row(ctx, [{"  " <> reason(ask, run, ctx), :text_muted}], answer_key(ctx),
        band: true,
        background: :card
      )

    [head | body] ++ [tail]
  end

  defp band_rows(ctx) do
    n = length(ctx.needs)
    cap = if ctx.mode == :compact, do: 2, else: 3
    shown = Enum.take(ctx.needs, cap)

    title =
      if n == 1,
        do: "! 1 NEEDS YOU",
        else: "! #{n} NEED YOU · oldest first"

    right = if ctx.hint?, do: again_key(ctx), else: answer_key(ctx)

    head = row(ctx, [{title, :warning, [:bold]}], right, band: true, background: :card)

    # pass72 G3 (QA Q3): the band's name column fits the names; pass73 T10:
    # the same name as the agent's row, cut with `…` only past 16 cells.
    name_w =
      shown
      |> Enum.map(fn {_, _, view} -> Draw.cells((view && view.display) || "Lead", ctx.state) end)
      |> Enum.max(fn -> 4 end)
      |> min(16)

    items =
      Enum.map(shown, fn {ask, _run, view} ->
        short = Name.fit((view && view.display) || "Lead", name_w, ctx.state)
        role = (view && view.name_role) || :text_primary
        badge = badge_for(ctx, view)
        lead = if badge, do: badge_segments(ctx, badge), else: [{"  ", :plain}]

        row(
          ctx,
          lead ++
            [
              {Draw.pad_to(short, name_w, ctx.state), role},
              {" ", :plain},
              {ask.text, :text_primary}
            ],
          [],
          band: true,
          background: :card
        )
        |> List.wrap()
        |> band_target(view)
        |> hd()
      end)

    more =
      if n > cap,
        do: [
          row(ctx, [{"  +#{n - cap} more · ^N goes through them", :text_faint}], [],
            band: true,
            background: :card
          )
        ],
        else: []

    [head | items] ++ more
  end

  # pass72 G8 (QA Q9): a band row is the drawn entry of its agent, so the
  # hint letters follow what the band shows, oldest first; a request past the
  # band's cap ("+2 more") gets no letter and is reached with ^N.
  defp band_target([first | rest], %{run_id: run, id: id}),
    do: [target(first, {:agent, run, id, true}) | rest]

  defp band_target(rows, _view), do: rows

  defp answer_key(%{hint?: true} = ctx), do: again_key(ctx)
  defp answer_key(_ctx), do: [{"^N", :text_primary, [:bold]}, {" answer", :text_muted}]
  defp again_key(_ctx), do: [{"^F", :text_primary, [:bold]}, {" again", :text_muted}]

  # Why it asks: what it wants to do and the project's approval mode.
  defp reason(%{verb: :question}, _run, _ctx), do: "answer it in the chat"

  defp reason(ask, _run, ctx) do
    verb =
      case ask.verb do
        :command -> "run a command"
        :edit -> "edit a file"
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

  defp run_header_full(ctx, run) do
    state = ctx.state
    in_chat? = run.id == ctx.chat_id
    badge = run_badge(ctx, run)
    clock = run |> Model.elapsed(state) |> Model.clock()

    bar =
      cond do
        in_chat? -> [{g(ctx, :in_chat), :accent}]
        true -> [{" ", :plain}]
      end

    lead = if badge, do: badge_segments(ctx, badge), else: []
    title_role = if ctx.hint?, do: :text_faint, else: :text_primary
    title_mods = if ctx.hint?, do: [], else: [:bold]

    first =
      row(
        ctx,
        lead ++
          bar ++
          [
            {Draw.mark(Model.kind(run), state), Model.kind_role(run)},
            {" ", :plain},
            {title(ctx, run, lead, in_chat?, clock && not ctx.hint? && clock), title_role,
             title_mods},
            if(in_chat?, do: {" · in chat", if(ctx.hint?, do: :text_faint, else: :text_muted)})
          ],
        if(clock && not ctx.hint?, do: [{clock, :text_muted}], else: [])
      )
      |> target({:run, run.id})

    meta = Shapes.meta(ctx, run)
    indent = if badge, do: "      ", else: "  "
    second = if meta != "", do: [row(ctx, [{indent <> meta, :text_faint}], [])], else: []
    [first | second]
  end

  defp run_header_compact(ctx, run) do
    state = ctx.state
    in_chat? = run.id == ctx.chat_id
    badge = run_badge(ctx, run)
    clock = run |> Model.elapsed(state) |> Model.clock()
    ratio = Shapes.ratio(ctx, run)

    bar = if in_chat?, do: [{g(ctx, :in_chat), :accent}], else: [{" ", :plain}]
    lead = if badge, do: badge_segments(ctx, badge), else: []
    title_role = if ctx.hint?, do: :text_faint, else: :text_primary

    right =
      if ctx.hint?,
        do: [],
        else: [{[ratio, clock] |> Enum.reject(&is_nil/1) |> Enum.join(" · "), :text_muted}]

    row(
      ctx,
      lead ++
        bar ++
        [
          {Draw.mark(Model.kind(run), state), Model.kind_role(run)},
          {" ", :plain},
          {title(ctx, run, lead, in_chat?, right_text(right)), title_role,
           if(in_chat?, do: [:bold], else: [])},
          if(in_chat?, do: {" · in chat", :text_muted})
        ],
      right
    )
    |> target({:run, run.id})
  end

  # The title is what gives way: "in chat" (R4) and the right-hand facts keep
  # their room.
  defp title(ctx, run, lead, in_chat?, right) do
    state = ctx.state
    lead_cells = cells(lead, state)
    in_chat = if in_chat?, do: Draw.cells(" · in chat", state), else: 0
    right_cells = if is_binary(right) and right != "", do: Draw.cells(right, state) + 1, else: 0
    room = ctx.width - 2 - lead_cells - 3 - in_chat - right_cells
    Draw.elide(Model.title(run), max(4, room), state)
  end

  defp right_text([{text, _role}]), do: text
  defp right_text(_), do: nil

  # -------------------------------------------------------- full blocks

  defp unfold_full(ctx, run, band, extras?) do
    views = Map.get(ctx.views, run.id, [])

    header = run_header_full(ctx, run)
    band = if band == [], do: [], else: band ++ [blank(ctx)]
    pre = Shapes.before_agents(ctx, run, views, extras?)
    blocks = agent_blocks(ctx, run, views)
    post = Shapes.after_agents(ctx, run, views, extras?)
    earlier = if extras? and run.id == ctx.chat_id, do: Shapes.earlier(ctx), else: []
    gap = if length(ctx.runs) > 1, do: [], else: [blank(ctx)]

    header ++ gap ++ band ++ pre ++ blocks ++ post ++ earlier
  end

  # Full mode with too little height: the header, the band and one row per agent.
  defp unfold_full_tight(ctx, run, band) do
    views = Map.get(ctx.views, run.id, [])
    header = run_header_full(ctx, run)
    header ++ band ++ Enum.map(views, &compact_row(ctx, &1))
  end

  @doc false
  def agent_blocks(ctx, _run, views) do
    tree? = Enum.any?(views, &(&1.role == :lead)) and length(views) > 1
    {visible, deeper} = Enum.split_with(views, &(&1.depth <= 1 or &1.role == :lead))
    name_w = name_width(ctx, visible, tree?)
    last = length(visible) - 1

    visible
    |> Enum.with_index()
    |> Enum.flat_map(fn {view, i} ->
      {first, cont} = connectors(ctx, tree?, view, i, last)
      w = if tree? and view.role == :lead, do: name_w + 2, else: name_w
      agent_block(ctx, view, first, cont, w)
    end)
    |> Kernel.++(deeper_row(ctx, deeper))
  end

  # R16: agents deeper than the lead's workers collapse to one row.
  defp deeper_row(_ctx, []), do: []

  defp deeper_row(ctx, deeper) do
    [
      row(ctx, [
        {"  " <> g(ctx, :deeper) <> " ", :text_faint},
        {"#{length(deeper)} more agents under them · open in the overlay", :text_faint}
      ])
    ]
  end

  # The tree connector before an agent's first row and before its other rows.
  defp connectors(ctx, true = _tree?, %{role: :lead}, _i, last) do
    cont = if last > 0, do: g(ctx, :pipe), else: " "
    {"", cont}
  end

  defp connectors(ctx, true, _view, i, last) do
    if i == last,
      do: {g(ctx, :elbow), " "},
      else: {g(ctx, :tee), g(ctx, :pipe)}
  end

  defp connectors(ctx, false, _view, i, last) do
    {"", if(i == last, do: " ", else: g(ctx, :pipe))}
  end

  # The name column: the widest sibling, never cut while there is room (R14),
  # cut in the middle only past what the row can hold.
  # The state words line up in one column (col 22 of a 46-cell pane, D3).
  @word_column 21

  defp name_width(ctx, views, tree?) do
    state = ctx.state
    subs = if tree?, do: Enum.reject(views, &(&1.role == :lead)), else: views
    widest = subs |> Enum.map(&Draw.cells(&1.display, state)) |> Enum.max(fn -> 4 end)
    prefix = if tree?, do: 4, else: 2
    meta = views |> Enum.map(&Draw.cells(meta(&1) || "", state)) |> Enum.max(fn -> 0 end)
    # pass72 G3 (QA Q3): the widest state word shown, not "needs you" always.
    word = views |> Enum.map(&Draw.cells(Model.word(&1.state), state)) |> Enum.max(fn -> 4 end)
    cap = ctx.width - 2 - prefix - 1 - word - 1 - meta
    column = @word_column - prefix - 1
    widest |> max(column) |> min(max(4, cap))
  end

  defp meta(view) do
    [Model.short_clock(view.elapsed), Model.tokens(view.tokens)]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  defp agent_block(ctx, view, first, cont, name_w) do
    state = ctx.state
    hint? = ctx.hint?
    badge = badge_for(ctx, view)

    glyph_mods = if view.state == :needs_you, do: [:bold], else: []

    prefix =
      cond do
        hint? and badge -> badge_segments(ctx, badge)
        hint? -> [{"    ", :plain}]
        first == "" -> []
        true -> [{first, :text_ghost}, {" ", :plain}]
      end

    dim = fn role -> if hint?, do: :text_faint, else: role end
    word_role = if view.state == :needs_you, do: :warning, else: dim.(Model.word_role(view.state))
    word_mods = if view.state == :needs_you, do: [:bold], else: []

    name_row =
      row(
        ctx,
        prefix ++
          [
            {g(ctx, view.state), Model.glyph_role(view.state), glyph_mods},
            {" ", :plain},
            {name(view.display, name_w, state), dim.(view.name_role)},
            {" ", :plain},
            {Model.word(view.state), word_role, word_mods}
          ],
        if(hint?, do: [], else: [{meta(view) || "", :text_faint}])
      )
      |> target({:agent, view.run_id, view.id, view.needs_you?})

    cont_prefix =
      cond do
        hint? -> [{"     ", :plain}]
        true -> [{cont, :text_ghost}, {" ", :plain}]
      end

    [name_row | detail_rows(ctx, view, cont_prefix)]
  end

  defp name(text, w, state) do
    if Draw.cells(text, state) > w,
      do: Draw.pad_to(Draw.elide(text, w, state, :middle), w, state),
      else: Draw.pad_to(text, w, state)
  end

  # The second row: the lane and the sentence; a done agent's finding and its
  # evidence; a failure with its retry.
  defp detail_rows(ctx, %{state: :done} = view, prefix) do
    state = ctx.state

    lead =
      prefix ++
        [{g(ctx, :finding), if(ctx.hint?, do: :text_faint, else: :success)}, {" ", :plain}]

    room = ctx.width - 2 - cells(prefix, state) - 2
    text = view.finding || produced_words(view) || "finished"
    evidence = evidence(view)
    lines = Draw.wrap(text, room, if(ctx.hint?, do: 1, else: 2), state)
    last_line = List.last(lines)

    {lines, tail} =
      cond do
        evidence == nil or ctx.hint? ->
          {lines, []}

        Draw.cells(last_line <> " · " <> evidence, state) <= room ->
          {List.replace_at(lines, -1, {last_line, evidence}), []}

        true ->
          {lines, [evidence]}
      end

    role = if ctx.hint?, do: :text_faint, else: :text_primary

    first_rows =
      lines
      |> Enum.with_index()
      |> Enum.map(fn
        {{line, ev}, 0} ->
          row(ctx, lead ++ [{line, role}, {" · " <> ev, :text_faint}], [])

        {line, 0} ->
          row(ctx, lead ++ [{line, role}], [])

        {{line, ev}, _} ->
          row(ctx, prefix ++ [{"  " <> line, role}, {" · " <> ev, :text_faint}], [])

        {line, _} ->
          row(ctx, prefix ++ [{"  " <> line, role}], [])
      end)

    first_rows ++ Enum.map(tail, &row(ctx, prefix ++ [{"  " <> &1, :text_faint}], []))
  end

  defp detail_rows(ctx, view, prefix) do
    state = ctx.state
    {sentence, role} = Model.sentence(view, state)
    role = if ctx.hint? and role != :warning, do: :text_faint, else: role
    lane = lane_segments(ctx, view, @full_lane)
    lane_cells = if lane == [], do: 0, else: @full_lane + 1
    room = ctx.width - 2 - cells(prefix, state) - lane_cells
    lines = Draw.wrap(sentence, room, if(ctx.hint?, do: 1, else: 2), state)

    retry =
      if view.state == :failed and view.retry_at,
        do: [],
        else: []

    case lines do
      [] when lane == [] ->
        []

      [] ->
        [row(ctx, prefix ++ lane, [])]

      [one | more] ->
        pad = String.duplicate(" ", lane_cells)

        [row(ctx, prefix ++ lane ++ spacer(lane) ++ [{one, role}], [])] ++
          Enum.map(more, &row(ctx, prefix ++ [{pad <> &1, role}], [])) ++ retry
    end
  end

  defp spacer([]), do: []
  defp spacer(_lane), do: [{" ", :plain}]

  defp produced_words(%{files_changed: n}) when is_integer(n) and n > 0,
    do: count(n, "file changed", "files changed")

  defp produced_words(_), do: nil

  # `fake.ex:88 +1`: the first reference and how many more.
  # pass72 G4 (QA Q4): D2's `fake.ex:88 +1`: the basename and its line.
  defp evidence(%{refs: [first | rest]}) do
    first = Path.basename(first)
    if rest == [], do: first, else: "#{first} +#{length(rest)}"
  end

  defp evidence(_), do: nil

  # ------------------------------------------------------------- lanes

  @doc false
  def lane_segments(ctx, view, n) do
    case Model.window(view.lane, n) do
      nil ->
        []

      cells ->
        cells
        |> Enum.chunk_by(& &1)
        |> Enum.map(fn [kind | _] = run ->
          {String.duplicate(g(ctx, lane_token(kind)), length(run)), lane_role(ctx, view, kind)}
        end)
    end
  end

  defp lane_token(:think), do: :lane_think
  defp lane_token(:tools), do: :lane_tools
  defp lane_token(:write), do: :lane_write
  defp lane_token(:you), do: :lane_you
  defp lane_token(:fail), do: :lane_fail
  defp lane_token(_), do: :lane_idle

  defp lane_role(%{hint?: true}, _view, :you), do: :warning
  defp lane_role(%{hint?: true}, _view, _kind), do: :text_faint
  defp lane_role(_ctx, _view, :think), do: :text_muted
  defp lane_role(_ctx, _view, :you), do: :warning
  defp lane_role(_ctx, _view, :fail), do: :error
  defp lane_role(_ctx, _view, :idle), do: :text_ghost
  defp lane_role(_ctx, view, _kind), do: view.lane_role

  # ------------------------------------------------------ compact rows

  defp unfold_compact(ctx, run, collapse_done?) do
    views = Map.get(ctx.views, run.id, [])

    {done, rest} =
      if collapse_done? and length(views) > 6,
        do: Enum.split_with(views, &(&1.state == :done)),
        else: {[], views}

    header = run_header_compact(ctx, run)
    rows = Enum.map(rest, &compact_row(ctx, &1))

    collapsed =
      case done do
        [] ->
          []

        done ->
          names = Enum.map_join(done, ", ", & &1.display)

          [
            row(ctx, [
              {"  " <> g(ctx, :done), :success},
              {" #{length(done)} done: " <> names, :text_muted}
            ])
          ]
      end

    note = Shapes.compact_note(ctx, run, views)
    [header | rows] ++ collapsed ++ note
  end

  defp compact_row(ctx, view) do
    state = ctx.state
    badge = badge_for(ctx, view)

    prefix =
      cond do
        badge -> badge_segments(ctx, badge)
        ctx.hint? -> [{"    ", :plain}]
        true -> [{"  ", :plain}]
      end

    dim = fn role -> if ctx.hint?, do: :text_faint, else: role end
    glyph_mods = if view.state == :needs_you, do: [:bold], else: []

    {body, _} =
      case view.state do
        :done ->
          text = view.finding || produced_words(view) || "finished"
          {[{g(ctx, :finding) <> " " <> text, dim.(:text_primary)}], nil}

        _ ->
          {sentence, role} = Model.sentence(view, state, true)
          role = if ctx.hint? and role != :warning, do: :text_faint, else: role
          lane = lane_segments(ctx, view, @compact_lane)
          {lane ++ spacer(lane) ++ [{sentence, role}], nil}
      end

    row(
      ctx,
      prefix ++
        [
          {g(ctx, view.state), Model.glyph_role(view.state), glyph_mods},
          {" ", :plain},
          {Draw.pad_to(
             Name.fit(view.display, short_field(ctx) - 1, state),
             short_field(ctx),
             state
           ), dim.(view.name_role)},
          {" ", :plain}
        ] ++ body,
      []
    )
    |> target({:agent, view.run_id, view.id, view.needs_you?})
  end

  # -------------------------------------------------------- orbit lines

  # D6: a folded run on two rows, `⋔ api hardening  ●●◐!   0/3 · 05:02` and
  # its most important sentence (R2); one row when `sentence?` is false.
  defp orbit(ctx, run, sentence?) do
    state = ctx.state
    views = Map.get(ctx.views, run.id, [])
    badge = run_badge(ctx, run)
    clock = run |> Model.elapsed(state) |> Model.clock()
    ratio = Shapes.ratio(ctx, run)

    glyphs =
      views
      |> Enum.take(12)
      |> Enum.map(&{g(ctx, &1.state), Model.glyph_role(&1.state), glyph_mods(&1)})

    lead = if badge, do: badge_segments(ctx, badge), else: [{" ", :plain}]

    right =
      if ctx.hint?,
        do: [],
        else: [{[ratio, clock] |> Enum.reject(&is_nil/1) |> Enum.join(" · "), :text_muted}]

    first =
      row(
        ctx,
        lead ++
          [
            {Draw.mark(Model.kind(run), state), Model.kind_role(run)},
            {" ", :plain},
            {Model.title(run), if(ctx.hint?, do: :text_faint, else: :text_primary)},
            {"  ", :plain}
          ] ++ glyphs,
        right
      )
      |> target({:run, run.id})

    # A folded run's needs-you agents are reached through the band's rows
    # (pass72 G8), never through an entry nothing on screen shows.
    second =
      if sentence?,
        do: [row(ctx, [{"   ", :plain} | priority(ctx, run, views)], [])],
        else: []

    [first | second]
  end

  defp glyph_mods(%{state: :needs_you}), do: [:bold]
  defp glyph_mods(_), do: []

  # R2 over a whole run: who needs you, else who failed, else the kind's own
  # fact, else what the newest working agent does.
  defp priority(ctx, run, views) do
    state = ctx.state

    cond do
      v = Enum.find(views, & &1.needs_you?) ->
        [{"! " <> v.display, :warning}, {" " <> elem(Model.sentence(v, state), 0), :text_muted}]

      v = Enum.find(views, &(&1.state == :failed)) ->
        [
          {g(ctx, :failed) <> " " <> v.display <> " failed", :error},
          {retry_words(v, state), :text_muted}
        ]

      fact = Shapes.orbit_fact(ctx, run, views) ->
        [{fact, :text_muted}]

      v = Enum.find(Enum.reverse(views), &(&1.state in [:working, :thinking])) ->
        [{v.display <> " " <> elem(Model.sentence(v, state), 0), :text_muted}]

      true ->
        [{Model.word(hd(views ++ [%{state: :done}]).state), :text_muted}]
    end
  end

  defp retry_words(%{retry_at: at}, %{now: now})
       when is_integer(at) and is_integer(now) and at > now,
       do: " · retry in #{div(at - now + 999, 1000)} s"

  defp retry_words(_v, _state), do: ""

  # --------------------------------------------------- earlier and legend

  defp earlier_rows(ctx) do
    state = ctx.state

    state
    |> Model.earlier(2)
    |> Enum.map(fn run ->
      clock = run |> Model.elapsed(state) |> Model.clock()
      {mark, role} = done_mark(ctx, run)

      row(
        ctx,
        [
          {" ", :plain},
          {Draw.mark(Model.kind(run), state), :text_muted},
          {" ", :plain},
          {Model.title(run), :text_primary}
        ],
        [{mark, role}, {" " <> (clock || ""), :text_muted}]
      )
      |> target({:run, run.id})
    end)
    |> case do
      [] -> []
      rows -> [blank(ctx) | rows]
    end
  end

  @doc false
  def done_mark(ctx, %{state: :done}), do: {g(ctx, :done), :success}
  def done_mark(ctx, %{state: :failed}), do: {g(ctx, :failed), :error}
  def done_mark(ctx, _run), do: {g(ctx, :stopped), :text_muted}

  # The lane legend, only when a lane is drawn.
  defp legend(ctx, body) do
    drawn? =
      Enum.any?(body, fn
        {_b, {:agent, run_id, id, _}, _} ->
          ctx.views |> Map.get(run_id, []) |> Enum.any?(&(&1.id == id and &1.lane != nil))

        _ ->
          false
      end)

    if drawn? and not ctx.hint? do
      [
        row(ctx, [
          {"last 60 s  ", :text_faint},
          {g(ctx, :lane_think), :text_muted},
          {" think ", :text_faint},
          {g(ctx, :lane_tools), :text_primary},
          {" tools ", :text_faint},
          {g(ctx, :lane_write), :text_primary},
          {" write ", :text_faint},
          {g(ctx, :lane_you), :warning},
          {" you", :text_faint}
        ])
      ]
    else
      []
    end
  end

  defp footer_rows(ctx) do
    inner = max(0, ctx.width - 2)
    rule = row(ctx, [{String.duplicate(g(ctx, :rule), inner), :text_ghost}], [])

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

        length(ctx.runs) > 1 and ctx.mode == :full ->
          row(
            ctx,
            [
              {"^F", :text_muted},
              {" + 1-#{min(9, length(ctx.runs))} opens a run  ", :text_faint},
              {"^N", :text_muted},
              {" next", :text_faint}
            ],
            [{mode_word(ctx), :text_faint}]
          )

        true ->
          row(
            ctx,
            [
              {"^F", :text_muted},
              {" agents  ", :text_faint},
              {"^N", :text_muted},
              {" needs you  ", :text_faint},
              {"^B", :text_muted},
              {" panel", :text_faint}
            ],
            [{mode_word(ctx), :text_faint}]
          )
      end

    [rule, keys]
  end

  @hint_order ~w(s d f g h j k l w e r t u i o p)
  defp order(label), do: Enum.find_index(@hint_order, &(&1 == label)) || 99

  defp mode_word(%{mode: :compact}), do: "compact"
  defp mode_word(_), do: "full"

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
