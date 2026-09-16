defmodule SwarmCodeCLI.UI.Projector.Shell do
  @moduledoc false
  alias SwarmCodeCLI.UI.{SafeText, Theme, Width}
  alias SwarmCodeCLI.UI.Scene.{Block, Region, Span, Style}

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
  @order [:title, :tabline, :main, :inspector, :activity, :composer, :status]
  def project(state, layout) do
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

  defp blocks(:title, state, rect, class) do
    policy = state.capabilities.ambiguous_width

    banner =
      (Map.get(state, :banner) || Density.budget(class).banner)
      |> SafeText.chrome()
      |> SafeText.value()

    workspace = Map.get(state.read_model.snapshots, :workspace)
    mode = Composer.mode_label(state)
    model = workspace && Map.get(workspace, :chat_model)

    triple =
      if is_binary(model) and model != "",
        do: banner <> " · " <> mode <> " · " <> model,
        else: banner <> " · " <> mode

    logo_mark = SafeText.value(Support.glyph(:logo_mark, state))
    wordmark = SafeText.value(SafeText.chrome(:swarmcode_wordmark))
    left_text = logo_mark <> " " <> wordmark <> "  " <> triple
    left_cells = Width.cells(left_text, policy)

    # Right-aligned live counts from ShellSnapshot.counts
    shell_snapshot = Map.get(state.read_model.snapshots, :shell)
    counts = shell_snapshot && Map.get(shell_snapshot, :counts)

    right_parts = counts_parts(counts, state)
    right_text = Enum.join(right_parts, " · ")
    right_cells = if right_text == "", do: 0, else: Width.cells(right_text, policy)

    # Accent bold without the RUNNING prefix cue
    accent_style = Theme.style(:accent, state.capabilities)
    wordmark_style = %{accent_style | role: :plain, prefix: nil, cues: [], modifiers: [:bold]}
    counts_style = %{accent_style | role: :plain, prefix: nil, cues: []}

    spans =
      [
        %Span{text: Density.safe(logo_mark, state, rect.width), style: wordmark_style},
        %Span{text: Density.safe(" ", state, rect.width), style: wordmark_style},
        %Span{text: Density.safe(wordmark, state, rect.width), style: wordmark_style},
        %Span{text: Density.safe("  ", state, rect.width), style: %Style{role: :text_primary}},
        %Span{text: Density.safe(triple, state, rect.width), style: %Style{role: :text_primary}}
      ]

    spans =
      if right_text != "" and left_cells + right_cells + 2 <= rect.width do
        pad = String.duplicate(" ", rect.width - left_cells - right_cells)

        spans ++
          [
            %Span{text: Density.safe(pad, state, rect.width), style: %Style{role: :text_primary}},
            %Span{text: Density.safe(right_text, state, rect.width), style: counts_style}
          ]
      else
        spans
      end

    {[%Block.RichText{spans: spans}], nil}
  end

  defp blocks(:tabline, state, rect, _class), do: {[tabline(state, rect.width)], nil}

  defp blocks(:main, state, rect, class), do: {Workspace.project(state, rect, class), nil}
  defp blocks(:inspector, state, rect, class), do: {Inspector.project(state, rect, class), nil}

  defp blocks(:composer, state, rect, _), do: Composer.project(state, rect)
  defp blocks(:status, state, rect, class), do: {Status.project(state, class, rect.width), nil}

  defp blocks(:activity, state, rect, _class) do
    needs = state.read_model.interactions |> Map.values() |> Enum.count(&(&1.state == :pending))

    activity_text = "NEEDS #{needs} · Activity"

    block =
      if needs > 0 do
        # Use accent color for the strip when needs > 0, without the RUNNING prefix
        accent_style = Theme.style(:accent, state.capabilities)
        clean_style = %{accent_style | role: :plain, prefix: nil, cues: []}

        %Block.RichText{
          spans: [
            %Span{
              text: Density.safe(activity_text, state, rect.width),
              style: clean_style
            }
          ]
        }
      else
        Support.text(activity_text, state, rect.width)
      end

    {[block], nil}
  end

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
                  [run_palette: "runs", runs_dashboard: "all", command_palette: "features"],
                  "   ",
                  fn {id, word} ->
                    SwarmCodeCLI.UI.Projector.KeyLabel.primary(
                      SwarmCodeCLI.UI.Keymap.Bindings.fetch(id)
                    ) <> " " <> word
                  end
                )
  @tabline_max 4
  @tab_title 20
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
      |> Enum.map(&tab_spans(&1, &1.id == active, state))
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
    widths = Enum.map(candidates, &tab_cells(&1, state, policy))

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
    ordered = RunRow.visible(state.read_model.runs, "", RunRow.shell_order(state))

    case active_run_id(state) do
      nil ->
        ordered

      id ->
        case Enum.split_with(ordered, &(&1.id == id)) do
          {[active], rest} -> [active | rest]
          {_, _} -> ordered
        end
    end
  end

  defp active_run_id(state) do
    case Support.run(state) do
      %{id: id} -> id
      _ -> nil
    end
  end

  # The wire kinds :chat and :consensus are not Theme.run_kind/1 keys, so they go
  # through RunRow.theme_kind/1 before any theme lookup or the lookup would raise.
  defp tab_spans(run, active?, state) do
    kind = RunRow.theme_kind(run.kind)
    {_kind_letter, kind_role} = Theme.run_kind(kind)
    {_status_word, status_role} = Theme.status(run.state)

    surface = if active?, do: hover_background(state)

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
      %Span{text: Support.glyph(:dot, state), style: tint(status_role, surface, state)},
      plain_gap(1, state, surface)
    ]
  end

  # Only the active tab carries the stripe; an inactive one spends the same cell
  # on a blank so the tabs stay on a common grid instead of shifting sideways as
  # the active run changes.
  defp stripe_span(true, surface, state),
    do: %Span{text: Support.glyph(:stripe, state), style: tint(:accent, surface, state)}

  defp stripe_span(false, surface, state), do: plain_gap(1, state, surface)

  defp tab_title(run, state), do: Density.safe(run.title, state, @tab_title)

  defp tab_title_style(true, surface, state),
    do: %{tint(:text_primary, surface, state) | modifiers: [:bold]}

  defp tab_title_style(false, surface, state), do: tint(:text_muted, surface, state)

  defp tab_cells(run, state, policy),
    do: @tab_chrome + Width.cells(SafeText.value(tab_title(run, state)), policy)

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

  defp counts_parts(nil, _state), do: []

  # Glyphs go through Support.glyph/2 so they degrade to their one-cell ASCII twins in ASCII mode
  # (a bare SafeText.chrome/1 here would leave Unicode on screen; see ORCHESTRATOR_NOTES_2 #36).
  defp counts_parts(counts, state) do
    for {field, token, word} <- [
          {:running, :glyph_selected, "running"},
          {:waiting, :glyph_inactive, "waiting"},
          {:failed, :glyph_failed, "failed"}
        ],
        count = Map.get(counts, field, 0),
        count > 0 do
      SafeText.value(Support.glyph(token, state)) <>
        " " <> Integer.to_string(count) <> " " <> word
    end
  end
end
