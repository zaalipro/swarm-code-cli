defmodule SwarmCodeCLI.UI.Projector.Shell do
  @moduledoc false
  alias SwarmCodeCLI.UI.{SafeText, Theme, Width}
  alias SwarmCodeCLI.UI.Scene.{Block, Region, Span}

  alias SwarmCodeCLI.UI.Projector.Inspector.Words

  alias SwarmCodeCLI.UI.Projector.{
    Composer,
    Density,
    Inspector,
    RunRow,
    Status,
    Support,
    Workspace
  }

  # The navigator dock is gone. Its job — showing what is running and getting you
  # there — belongs to the tab row on row 1, the Ctrl-G dashboard and Ctrl-P, so
  # the shell projects no left dock and main takes the reclaimed width.
  @order [:title, :main, :inspector, :activity, :composer, :status]
  def project(state, layout) do
    layout = without_idle_inspector(state, layout)

    Enum.reduce(@order, {[], nil}, fn role, {regions, cursor} ->
      case Map.get(layout.rects, role) do
        nil ->
          {regions, cursor}

        rect ->
          {blocks, new_cursor} = blocks(role, state, rect, layout.class)
          id = Atom.to_string(role)
          focus = if state.focus == id and state.layers == [], do: :active, else: :inactive

          label =
            case role do
              :title -> Composer.mode_label(state)
              :composer -> Composer.label(state)
              :tabline -> SafeText.chrome(:runs_label)
              _ -> SafeText.chrome(role)
            end
            |> Density.safe(state, rect.width)

          region = %Region{
            id: id,
            role: role,
            rect: rect,
            label: label,
            blocks: blocks,
            focus: focus
          }

          {regions ++ [region], new_cursor || cursor}
      end
    end)
  end

  # One row for the title and the runs (ux M5): the mark and the project,
  # then the run tabs with the switcher hint on the right. The mode, model,
  # tokens and cost moved to the status line, where the eye looks for them
  # while typing.
  # A conversation with no run has nothing to inspect: the welcome takes the
  # dock's columns instead of a pane that says "No run selected".
  defp without_idle_inspector(state, %{rects: %{inspector: _, main: main} = rects} = layout) do
    if Support.run(state) == nil and state.destination != :activity do
      width = layout.size.columns
      rects = Map.delete(rects, :inspector)
      rects = %{rects | main: %{main | width: width}}

      rects =
        Enum.reduce([:activity, :composer], rects, fn key, acc ->
          case Map.get(acc, key) do
            nil -> acc
            rect -> Map.put(acc, key, %{rect | width: width})
          end
        end)

      %{layout | rects: rects}
    else
      layout
    end
  end

  defp without_idle_inspector(_state, layout), do: layout

  defp blocks(:title, state, rect, class) do
    policy = state.capabilities.ambiguous_width
    workspace = Map.get(state.read_model.snapshots, :workspace)

    project = present(workspace && Map.get(workspace, :project))
    banner = Map.get(state, :banner) || Density.budget(class).banner
    lead = project || banner_words(banner)

    # A project name shares the row with the tabs; the fake demo's warning
    # is the one thing its user must not miss, so it is never cut for them.
    lead_cells =
      if project || banner in [nil, :persisted_banner],
        do: max(1, div(rect.width, 3)),
        else: max(1, rect.width - 4)

    logo = SafeText.value(Support.glyph(:logo_mark, state))
    accent = Theme.style(:accent, state.capabilities)
    logo_style = %{accent | role: :plain, prefix: nil, cues: [], modifiers: [:bold]}

    lead_style = %{
      Theme.style(:text_primary, state.capabilities)
      | role: :plain,
        prefix: nil,
        cues: [],
        modifiers: [:bold]
    }

    left = [
      %Span{text: Density.safe(" " <> logo <> " ", state, rect.width), style: logo_style},
      %Span{text: Density.safe(lead, state, lead_cells), style: lead_style}
    ]

    left_cells =
      Enum.reduce(left, 0, &(Width.cells(SafeText.value(&1.text), policy) + &2))

    gap = 3
    room = rect.width - left_cells - gap

    spans =
      if room >= 12 do
        %Block.RichText{spans: tabs} = tabline(state, room)
        left ++ [plain_gap(gap, state)] ++ tabs
      else
        left
      end

    {[%Block.RichText{spans: spans}], nil}
  end

  defp blocks(:main, state, rect, class), do: {Workspace.project(state, rect, class), nil}
  defp blocks(:inspector, state, rect, class), do: {Inspector.project(state, rect, class), nil}

  defp blocks(:composer, state, rect, _), do: Composer.project(state, rect)
  defp blocks(:status, state, rect, class), do: {Status.project(state, class, rect.width), nil}

  # The row between the transcript and the composer: a hairline, or the title
  # of the approval that has taken the composer slot.
  defp blocks(:activity, state, rect, _class), do: {[Composer.edge(state, rect)], nil}

  # The launcher's banner, in words for the title. A saved session is the
  # product, not a dev build, so it reads as SwarmCode until the daemon names
  # the project; the fake demo and the unsaved session keep saying what they
  # are, since that is the one thing their user must not miss.
  defp banner_words(:persisted_banner), do: SafeText.value(SafeText.chrome(:swarmcode_wordmark))
  defp banner_words(nil), do: SafeText.value(SafeText.chrome(:swarmcode_wordmark))
  defp banner_words(token), do: token |> SafeText.chrome() |> SafeText.value()

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_), do: nil

  # ── Tabline ─────────────────────────────────────────────────────────────────
  #
  # The awareness affordance: one row, directly under the title bar, carrying the
  # runs you are working across so switching is never a blind act.
  #
  # The whole row is a single `Block.RichText` of styled spans and never sibling
  # blocks: blocks stack vertically, so a row assembled from several of them
  # would print one line per block instead of one tab row.

  # The keys come from the binding table at compile time, so a rebind of the
  # run palette, the dashboard or the command palette re-spells the hint; the
  # three words are the tab row's own.
  @tabline_hint Enum.map_join(
                  [run_palette: "runs"],
                  "   ",
                  fn {id, word} ->
                    SwarmCodeCLI.UI.Projector.KeyLabel.primary(
                      SwarmCodeCLI.UI.Keymap.Bindings.fetch(id)
                    ) <> " " <> word
                  end
                )
  @tabline_max 4
  @tab_title 24
  # stripe + space + mark + space + title + space + dot + trailing space
  @tab_chrome 7
  @tab_gap 1
  @hint_gap 2

  @doc """
  The one-line tab row for a region `width` cells wide.

  Up to four runs, the active one first and then the most recent others; each is
  an accent stripe (only when active), the kind mark, the title and a status dot,
  with the active tab sitting on the hover surface. The keys hint is
  right-aligned on the same row. Runs that do not fit are folded into a trailing
  `+N` rather than shrunk into unreadable stubs, so every tab that is drawn stays
  readable.
  """
  def tabline(state, width) do
    policy = state.capabilities.ambiguous_width
    {shown, overflow, hint} = tabline_plan(state, width)
    active = active_run_id(state)

    tabs =
      shown
      |> Enum.map(&tab_spans(&1, &1.id == active, state, width))
      |> Enum.intersperse([plain_gap(@tab_gap, state)])
      |> List.flatten()

    left = tabs ++ overflow_spans(overflow, shown, state)
    hint_cells = if hint == "", do: 0, else: Width.cells(hint, policy)
    pad = max(0, width - spans_cells(left, policy) - hint_cells)

    %Block.RichText{
      spans: left ++ pad_span(pad, state) ++ hint_spans(hint, hint_cells, state)
    }
  end

  @doc """
  What the row shows at `width`: `{tabs, overflow, hint}`.

  Every measurement is in terminal cells under the state's own ambiguous-width
  policy, never in characters: a two-cell title grapheme measured as one would
  push the row past the terminal edge and wrap it onto a second line.
  """
  def tabline_plan(state, width) do
    policy = state.capabilities.ambiguous_width
    runs = tabline_runs(state)
    total = length(runs)
    candidates = Enum.take(runs, @tabline_max)
    widths = Enum.map(candidates, &tab_cells(&1, state, policy, width))

    hint_cells = Width.cells(@tabline_hint, policy)
    room_for_hint? = hint_cells + @hint_gap <= width

    # The tabs are budgeted before the hint. A 42-cell static hint that fits the
    # row but leaves no room for a single tab turns the one affordance that
    # replaced the navigator into a bare "+N" — a row announcing runs it will
    # not show. The hint is the least valuable thing here, and its keys are on
    # the status row as well, so it is what goes when both cannot be drawn.
    with_hint =
      if room_for_hint?,
        do: plan(widths, total, max(0, width - hint_cells - @hint_gap), policy),
        else: {0, 0}

    bare = plan(widths, total, width, policy)

    hint? =
      room_for_hint? and
        (candidates == [] or elem(with_hint, 0) > 0 or elem(bare, 0) == 0)

    {count, overflow} = if hint?, do: with_hint, else: bare

    {Enum.take(candidates, count), overflow, if(hint?, do: @tabline_hint, else: "")}
  end

  # Widest first: the row keeps as many whole tabs as `budget` allows and spends
  # what is left on the +N remainder.
  defp plan(widths, total, budget, policy) do
    count =
      Enum.find(length(widths)..0//-1, 0, fn k ->
        needed(widths, k, total, policy) <= budget
      end)

    overflow = if needed(widths, count, total, policy) <= budget, do: total - count, else: 0

    {count, overflow}
  end

  @doc """
  The runs the tab row offers: the active one first, then the rest in shell order.

  `RunRow.visible/3` is the shared order — the sequence the data source sent in
  `order[:shell]`, then anything the shell has not mentioned by recency — and it
  already drops superseded runs, which have been replaced by a newer turn and
  are not somewhere you can switch back to.
  """
  def tabline_runs(state) do
    # pass71 F11 (review R12): a finished chat or goal turn belongs to the
    # transcript, not the tab row; four turns made four tabs with frozen
    # clocks. Live runs, swarms, workflows and the like keep their tabs, and
    # the run in view always has one (below).
    ordered =
      state.read_model.runs
      |> RunRow.visible("", RunRow.shell_order(state))
      |> Enum.filter(&tab_worthy?/1)

    case active_run_id(state) do
      nil ->
        ordered

      id ->
        case Enum.split_with(ordered, &(&1.id == id)) do
          {[active], rest} ->
            [active | rest]

          # The run in view keeps its tab even when a newer turn replaced it,
          # so the row always says what is on screen.
          {_, _} ->
            case Map.get(state.read_model.runs, id) do
              nil -> ordered
              active -> [active | ordered]
            end
        end
    end
  end

  @tab_live [
    :queued,
    :running,
    :streaming,
    :waiting_question,
    :waiting_approval,
    :paused,
    :retrying
  ]

  defp tab_worthy?(%{kind: kind, state: state}),
    do: kind not in [:chat, :goal] or state in @tab_live

  defp tab_worthy?(_), do: true

  defp active_run_id(state) do
    case Support.run(state) do
      %{id: id} -> id
      _ -> nil
    end
  end

  # The wire kinds :chat and :consensus are not Theme.run_kind/1 keys, so they go
  # through RunRow.theme_kind/1 before any theme lookup or the lookup would raise.
  defp tab_spans(run, active?, state, width) do
    kind = RunRow.theme_kind(run.kind)
    {_kind_letter, kind_role} = Theme.run_kind(kind)
    {_status_word, status_role} = Theme.status(run.state)

    surface = if active?, do: hover_background(state)

    badges =
      run
      |> badges(state, width)
      |> Enum.flat_map(fn {text, role, modifiers} ->
        [
          plain_gap(1, state, surface),
          %Span{
            text: Density.safe(text, state, @tab_title),
            style: %{tint(role, surface, state) | modifiers: modifiers}
          }
        ]
      end)

    [
      stripe_span(active?, surface, state),
      plain_gap(1, state, surface),
      %Span{
        text: Support.glyph(Theme.run_mark(kind), state),
        style: %{tint(kind_role, surface, state) | modifiers: [:bold]}
      },
      plain_gap(1, state, surface),
      %Span{text: tab_title(run, state), style: tab_title_style(active?, surface, state)},
      plain_gap(1, state, surface),
      %Span{text: Support.glyph(:dot, state), style: tint(status_role, surface, state)}
    ] ++ badges ++ [plain_gap(1, state, surface)]
  end

  # What a tab says about its run beyond the title: how many agents it runs,
  # how long it has been going, and whether it is waiting on the user. Each is
  # `{text, role, modifiers}` and each is left out when unknown, so a run the
  # daemon has said nothing about is a bare title, not a title with zeros.
  #
  # Narrow rows keep the tabs by shedding the badges first: the elapsed time
  # goes below 120 columns and the agent count below 100, since a row that
  # drops a whole run to fit a clock has its priorities backwards. The `!`
  # never goes: it is the one badge that asks the user for something.
  defp badges(run, state, width) do
    agents =
      if width >= 100 and is_integer(run.agents_total) and run.agents_total > 0,
        do: [
          {Support.glyph(:hex_full, state)
           |> SafeText.value()
           |> Kernel.<>(Integer.to_string(run.agents_total)), :text_muted, []}
        ],
        else: []

    elapsed =
      case {width >= 120, run_elapsed(run, state)} do
        {true, text} when is_binary(text) -> [{text, :text_muted, []}]
        _ -> []
      end

    needs =
      if is_integer(run.needs) and run.needs > 0,
        do: [{"!" <> Integer.to_string(run.needs), :warning, [:bold]}],
        else: []

    agents ++ elapsed ++ needs
  end

  # A finished run shows how long it took, from its own two stamps. A running
  # one shows how long it has been going, against the state's clock, and
  # nothing while that clock has not been set: a fixture's zero would read as
  # a lie of fifty years.
  defp run_elapsed(%{started_at: started, finished_at: finished}, _state)
       when is_integer(started) and is_integer(finished),
       do: Words.elapsed(started, finished)

  # Only a live run's clock runs: a failed workflow the daemon never stamped
  # finished must not count on for hours (ux F14).
  defp run_elapsed(%{started_at: started, state: run_state}, %{now: now})
       when is_integer(started) and is_integer(now) and now > 0,
       do: if(Words.live?(run_state), do: Words.elapsed(started, now))

  defp run_elapsed(_run, _state), do: nil

  # Only the active tab carries the stripe; an inactive one spends the same cell
  # on a blank so the tabs stay on a common grid instead of shifting sideways as
  # the active run changes.
  defp stripe_span(true, surface, state),
    do: %Span{text: Support.rail(state), style: tint(:accent, surface, state)}

  defp stripe_span(false, surface, state), do: plain_gap(1, state, surface)

  # The title is cut on a word boundary when it must be cut at all: "Migrate
  # the billing…" reads as a title, "Migrate the billing sch…" as an accident.
  # The boundary is only honoured when it leaves at least half the budget, so
  # a title that is one long word still shows most of that word.
  defp tab_title(run, state) do
    policy = state.capabilities.ambiguous_width
    title = run.title |> Density.safe(state, @tab_title * 4) |> SafeText.value()

    if Width.cells(title, policy) <= @tab_title do
      Density.safe(title, state, @tab_title)
    else
      ellipsis = Width.cells("…", policy)
      {head, _rest, _used} = Width.take_cells(title, @tab_title - ellipsis, policy)

      head =
        case :binary.matches(head, " ") do
          [] ->
            head

          matches ->
            {last_space, _} = List.last(matches)

            if last_space * 2 >= @tab_title,
              do: binary_part(head, 0, last_space),
              else: head
        end

      Density.safe(String.trim_trailing(head) <> "…", state, @tab_title)
    end
  end

  defp tab_title_style(true, surface, state),
    do: %{tint(:text_primary, surface, state) | modifiers: [:bold]}

  defp tab_title_style(false, surface, state), do: tint(:text_muted, surface, state)

  defp tab_cells(run, state, policy, width) do
    badge_cells =
      run
      |> badges(state, width)
      |> Enum.map(fn {text, _role, _modifiers} -> 1 + Width.cells(text, policy) end)
      |> Enum.sum()

    @tab_chrome + Width.cells(SafeText.value(tab_title(run, state)), policy) + badge_cells
  end

  defp needed(widths, count, total, policy) do
    tabs = widths |> Enum.take(count) |> Enum.sum()
    tabs + max(0, count - 1) * @tab_gap + overflow_cells(total - count, count, policy)
  end

  defp overflow_cells(0, _count, _policy), do: 0
  defp overflow_cells(n, 0, policy), do: Width.cells(overflow_text(n), policy)
  defp overflow_cells(n, _count, policy), do: @tab_gap + Width.cells(overflow_text(n), policy)

  defp overflow_text(n), do: "+" <> Integer.to_string(n)

  defp overflow_spans(0, _shown, _state), do: []

  defp overflow_spans(n, shown, state) do
    text = overflow_text(n)
    cells = Width.cells(text, state.capabilities.ambiguous_width)
    lead = if shown == [], do: [], else: [plain_gap(@tab_gap, state)]

    lead ++ [%Span{text: Density.safe(text, state, cells), style: tint(:text_faint, nil, state)}]
  end

  defp hint_spans("", _cells, _state), do: []

  defp hint_spans(hint, cells, state),
    do: [%Span{text: Density.safe(hint, state, cells), style: tint(:text_faint, nil, state)}]

  # A zero-cell span would still be a span; an empty SafeText is not worth
  # minting, so the padding disappears entirely when the row is already full.
  defp pad_span(0, _state), do: []
  defp pad_span(width, state), do: [plain_gap(width, state)]

  defp spans_cells(spans, policy),
    do: Enum.reduce(spans, 0, &(Width.cells(SafeText.value(&1.text), policy) + &2))

  defp plain_gap(width, state, background \\ nil),
    do: %Span{
      text: Density.safe(String.duplicate(" ", width), state, width),
      style: tint(:plain, background, state)
    }

  defp hover_background(state), do: Theme.style(:hover, state.capabilities).background

  # Paint resolves a span prefix as `style.prefix || themed.prefix`, so blanking a
  # span's own prefix does not suppress a role's cue: the theme puts it straight
  # back. The colour is borrowed onto the cue-free `:plain` role instead, the way
  # `RunRow.tinted/2` does it, with `background` overriding so the active tab can
  # sit on the hover surface while its spans keep their own foregrounds.
  defp tint(role, background, state) do
    themed = Theme.style(role, state.capabilities)

    %{
      Theme.style(:plain, state.capabilities)
      | foreground: themed.foreground,
        background: background || themed.background
    }
  end
end
