defmodule SwarmCodeCLI.UI.Projector.RunsDashboard do
  @moduledoc """
  Full-screen runs dashboard grouped by kind (Ctrl-G).

  The dashboard owns the whole screen minus the title row and the status row, so
  it is projected as a `Scene.Dialog` whose rect spans the full terminal rather
  than going through the centred option-list dialog chrome: its rows are
  `Block.Surface` cards carrying a gauge, not single-line options.

  The row itself lives in `UI.Projector.RunRow`, which the Ctrl-R palette draws
  with its own column widths; this module owns the grouping, the headings, the
  window and the full-screen chrome.

  Two width facts govern every line here:

    * `Paint.Scene.dialog/2` lays the body out in `rect.width - 2` — the border
      columns are not the body's to spend — so `dialog/2` hands `project/2` the
      body width, never the rect's own width;
    * a `Block.Surface` with an accent indents its contents by two more cells, so
      a run row is budgeted for `body width - 2` and ends exactly at the card
      edge.

  It replaced a scrolling `Block.VirtualList`, so it windows like one: only the
  runs that fit are drawn, the window follows the focused row, and what is left
  over is counted on an overflow line rather than painted off the bottom.
  """
  alias SwarmCodeCLI.UI.{SafeText, State, Theme, Width}
  alias SwarmCodeCLI.UI.Scene.{Block, Dialog, Rect, Span}
  alias SwarmCodeCLI.UI.Projector.{Density, RunRow, Support}

  @gauge_width 28
  @status_width 12
  @meta_width 30
  @min_title 10

  # Column widths for a row budget: the first set that still leaves a readable
  # title. The gauge is the point of this view, so it narrows rather than
  # vanishing; the columns around it go in order of how little they carry.
  @columns [
    [status_width: @status_width, gauge_width: @gauge_width, meta_width: @meta_width],
    [status_width: @status_width, gauge_width: @gauge_width, meta_width: 0],
    [status_width: @status_width, gauge_width: 16, meta_width: 0],
    [status_width: 0, gauge_width: 16, meta_width: 0],
    [status_width: 0, gauge_width: 8, meta_width: 0]
  ]

  # The dialog's own border rows and its single footer line.
  @chrome_lines 3
  # The header line and the blank under it.
  @header_lines 2
  # A group costs its heading and the blank line that closes it.
  @group_lines 2
  # The accent stripe and the space after it, ahead of the row's first column.
  @accent_width 2
  # The least space the header leaves between its summary and its controls.
  @summary_gap 2

  @doc "Full-screen dialog for the `{:runs_dashboard, id}` layer."
  def dialog(state, _class) do
    rect = rectangle(state.size)
    window = window(state)

    %Dialog{
      id: "runs_dashboard",
      rect: rect,
      title: Density.safe("ALL RUNS", state, max(0, rect.width - 4)),
      blocks: blocks(state, body_width(rect), window),
      footer: footer(state, body_width(rect)),
      focused_control_id: focused_run_id(state),
      body_scroll: window.first,
      body_visible_range: {window.first, window.first + length(window.shown)},
      body_total_count: window.total
    }
  end

  # Row 0 is the title bar and the last row is the status bar; the dashboard
  # takes everything in between.
  defp rectangle(size) do
    %Rect{
      x: 0,
      y: min(1, max(0, size.rows - 1)),
      width: size.columns,
      height: max(1, size.rows - 2)
    }
  end

  # Paint.Scene.dialog/2 lays the blocks out inside the border, never across it.
  defp body_width(rect), do: max(0, rect.width - 2)

  defp footer(state, width) do
    [
      Support.action(
        Density.safe("Close", state, max(0, width - 2)),
        {:local, :close_top_layer}
      )
    ]
  end

  @doc """
  Rows of the dashboard: a header line, one labelled group per kind in the
  window, and an overflow line whenever runs are left over.

  `width` is the body width — what `Paint.Scene.dialog/2` actually lays blocks
  out in — not the dialog rect's own width.
  """
  def project(state, width), do: blocks(state, width, window(state))

  defp blocks(state, width, window) do
    header = render_header(state, width, window.entries)
    groups = window.shown |> group_runs() |> render_groups(state, width)

    [header, empty_line(state) | groups] ++
      overflow_line(state, width, window.first, length(window.shown), window.total)
  end

  @doc """
  The runs that fit, and where the window sits.

  The window follows the focused row: it scrolls only as far as it must to keep
  the row Up/Down moved to on screen, which is the same rule the Ctrl-R palette
  uses and the reason the focused row is always one the action table holds.
  """
  def window(state) do
    entries = ordered(state)
    total = length(entries)
    lines = body_lines(state)
    index = Enum.find_index(entries, &(&1.id == state.focus)) || 0
    first = anchor(entries, index, lines)
    shown = entries |> Enum.drop(first) |> Enum.take(fill(entries, first, lines))

    %{first: first, shown: shown, total: total, entries: entries}
  end

  @doc "Runs grouped by their themed kind, in display order. Exposed for tests."
  def groups(state), do: state |> visible_runs() |> group_runs()

  @doc "Every listed run id, in the order the dashboard draws them."
  def ids(state), do: state |> ordered() |> Enum.map(& &1.id)

  @doc """
  Up/Down move through the listed runs and wrap at both ends.

  Without this the `{:runs_dashboard, _}` layer falls through to the generic
  dialog graph and focus can never land on a run row: Enter would close the
  dashboard instead of opening what the user moved to.

  A filter that matches nothing still has to offer a focusable control, or the
  reducer's `Integer.mod/2` cycle would divide by zero, so an empty list falls
  back to the footer's close.
  """
  def focus_graph(state) do
    case ids(state) do
      [] -> ["cancel"]
      ids -> ids
    end
  end

  @doc """
  The run a paging key moves focus to, or `nil` when there is nothing to move.

  A page is the window the user is actually looking at, so PageDown lands on the
  first row of the next screenful rather than on a fixed count of rows.
  """
  def page_focus(state, key) do
    case ids(state) do
      [] ->
        nil

      ids ->
        last = length(ids) - 1
        index = Enum.find_index(ids, &(&1 == state.focus)) || 0
        step = max(1, length(window(state).shown))

        target =
          case key do
            :home -> 0
            :end -> last
            :page_up -> index - step
            :page_down -> index + step
          end

        Enum.at(ids, target |> max(0) |> min(last))
    end
  end

  @doc "The kind-specific meta line for a run. Exposed for tests."
  def meta(run, kind), do: RunRow.meta(run, kind)

  # Every listed run, flattened back out of its group so the focus graph, the
  # window and the painted order are the same sequence.
  defp ordered(state) do
    state |> groups() |> Enum.flat_map(fn {_kind, runs} -> runs end)
  end

  defp visible_runs(state) do
    state.read_model.runs
    |> RunRow.visible(filter_text(state), RunRow.shell_order(state))
    |> Enum.map(&RunRow.enrich(&1, state))
  end

  # The lines the groups may spend: the body minus the header and its blank.
  defp body_lines(state) do
    rect = rectangle(state.size)
    max(1, rect.height - @chrome_lines - @header_lines)
  end

  # The window keeps `index` on screen and scrolls no further than it must.
  defp anchor(_entries, 0, _lines), do: 0

  defp anchor(entries, index, lines) do
    Enum.reduce_while(0..index, 0, fn first, _ ->
      if first + fill(entries, first, lines) > index,
        do: {:halt, first},
        else: {:cont, first + 1}
    end)
  end

  # How many runs the window starting at `first` holds, once the overflow line
  # has taken its own line off the budget.
  defp fill(entries, first, lines) do
    count = capacity(entries, first, lines)

    if first > 0 or first + count < length(entries),
      do: max(1, capacity(entries, first, lines - 1)),
      else: count
  end

  # A run costs one line, and the first run of each group costs its heading and
  # the blank that closes the group as well.
  defp capacity(entries, first, lines) do
    entries
    |> Enum.drop(first)
    |> Enum.reduce_while({0, 0, nil}, fn run, {count, used, kind} ->
      next = RunRow.theme_kind(run.kind)
      cost = 1 + if next == kind, do: 0, else: @group_lines

      if used + cost <= lines,
        do: {:cont, {count + 1, used + cost, next}},
        else: {:halt, {count, used, kind}}
    end)
    |> elem(0)
  end

  defp focused_run_id(state) do
    if Map.has_key?(state.read_model.runs, state.focus), do: state.focus
  end

  # A single space, not "": an empty line carries no cells and is dropped, which
  # would run the groups together.
  defp empty_line(state), do: %Block.Text{text: Density.safe(" ", state, 1)}

  defp filter_text(state) do
    case state.layers do
      [{:runs_dashboard, _} | _] -> State.runs_filter(state)
      _ -> ""
    end
  end

  defp group_runs(runs) do
    runs
    |> Enum.group_by(&RunRow.theme_kind(&1.kind))
    |> Enum.sort_by(fn {kind, _} -> kind_order(kind) end)
  end

  defp kind_order(:swarm), do: 0
  defp kind_order(:consensus_judge), do: 1
  defp kind_order(:research), do: 2
  defp kind_order(:workflow), do: 3
  defp kind_order(:goal), do: 4
  defp kind_order(:assistant), do: 5
  defp kind_order(:ultra), do: 6
  defp kind_order(_), do: 99

  defp kind_label(:assistant), do: "ASSISTANT"
  defp kind_label(:goal), do: "GOALS"
  defp kind_label(:swarm), do: "SWARMS"
  defp kind_label(:workflow), do: "WORKFLOWS"
  defp kind_label(:research), do: "DEEP RESEARCH"
  defp kind_label(:consensus_judge), do: "CONSENSUS"
  defp kind_label(:ultra), do: "ULTRA"
  defp kind_label(_), do: "OTHER"

  # Every measurement here is in terminal cells under the state's own
  # ambiguous-width policy. `Density.safe/4` treats its number as a cell budget,
  # so a character count would elide "3 runs · 1 live" mid-word under :wide,
  # where U+00B7 MIDDLE DOT is two cells wide.
  defp render_header(state, width, entries) do
    live = Enum.count(entries, &(&1.state in [:running, :streaming]))
    summary = "#{length(entries)} runs · #{live} live"

    # Two cells of margin either side, "ALL RUNS" and the two cells after it.
    spare = max(0, width - 14)
    summary_width = min(cells(summary, state), spare)

    # The widest set of controls that still leaves the summary its gap. Eliding
    # the controls instead would run them into the summary and cut a key name in
    # half; the filter box is the part worth keeping longest.
    controls = controls(state, max(0, spare - summary_width - @summary_gap))
    controls_width = cells(controls, state)
    padding_width = spare - summary_width - controls_width

    title_style = %{Theme.style(:text_primary, state.capabilities) | modifiers: [:bold]}
    faint = Theme.style(:text_faint, state.capabilities)
    plain_style = Theme.style(:plain, state.capabilities)

    %Block.RichText{
      spans: [
        %Span{text: Density.safe("  ", state, 2), style: plain_style},
        %Span{text: Density.safe("ALL RUNS", state, 8), style: title_style},
        %Span{text: Density.safe("  ", state, 2), style: plain_style},
        %Span{text: Density.safe(summary, state, summary_width), style: faint},
        %Span{
          text: Density.safe(String.duplicate(" ", padding_width), state, padding_width),
          style: plain_style
        },
        %Span{text: Density.safe(controls, state, controls_width), style: faint},
        %Span{text: Density.safe("  ", state, 2), style: plain_style}
      ]
    }
  end

  # The filter box — the affordance while empty, the live query once typed — and
  # the keys. The arrows are row text rather than catalogue glyphs, so the ASCII
  # form is spelled out here, where the terminal's capabilities are known.
  defp controls(state, room) do
    query = State.runs_filter(state)
    box = if query == "", do: "/ filter", else: "/" <> query

    [box <> move_keys(state) <> open_keys(state), box <> open_keys(state), box, ""]
    |> Enum.find("", &(cells(&1, state) <= room))
  end

  defp move_keys(%{capabilities: %{ascii?: true}}), do: "    Up/Dn move"
  defp move_keys(_state), do: "    ⇅ move"

  defp open_keys(%{capabilities: %{ascii?: true}}), do: "    Enter open    Ctrl-G close"
  defp open_keys(_state), do: "    ↵ open    Ctrl-G close"

  defp render_groups(grouped, state, width) do
    grouped
    |> Enum.flat_map(fn {kind, runs} ->
      heading = render_group_heading(kind, state, width)
      rows = Enum.map(runs, &render_run_row(&1, kind, state, width))

      [heading | rows] ++ [empty_line(state)]
    end)
  end

  # The kind mark is drawn as row text, not left to the role's prefix cue: that
  # cue is still the old single letter ("S", "G", "W") while Theme.run_mark/1 is
  # the design's glyph. Paint falls back to the theme prefix whenever a span's
  # own prefix is nil, so the mark and the label both borrow the kind colour
  # through RunRow.tinted/2; carrying the run_* role would reprint the letter
  # beside the mark. Support.glyph/2 swaps in the registered ASCII twin when the
  # terminal cannot draw the glyph — including for the rule, whose glyph is two
  # cells wide under the :wide policy and so is repeated a measured number of
  # times rather than a counted number of characters.
  defp render_group_heading(kind, state, width) do
    {_letter, role} = Theme.run_kind(kind)
    mark = Support.glyph(Theme.run_mark(kind), state)
    label = kind_label(kind)

    mark_style = %{RunRow.tinted(role, state) | modifiers: [:bold]}
    plain_style = Theme.style(:plain, state.capabilities)
    rule_style = Theme.style(:border_soft, state.capabilities)

    label_width = cells(label, state)
    mark_width = cells(SafeText.value(mark), state)
    rule_width = max(0, width - 7 - mark_width - label_width)
    rule = repeat(SafeText.value(Support.glyph(:rule, state)), rule_width, state)

    %Block.RichText{
      spans: [
        %Span{text: Density.safe("  ", state, 2), style: plain_style},
        %Span{text: mark, style: mark_style},
        %Span{text: Density.safe(" ", state, 1), style: plain_style},
        %Span{text: Density.safe(label, state, label_width), style: mark_style},
        %Span{text: Density.safe("  ", state, 2), style: plain_style},
        %Span{text: Density.safe(rule, state, rule_width), style: rule_style}
      ]
    }
  end

  # One run is one line. The accent stripe and the surface padding consume two
  # cells on the left of the card, and the card itself sits inside the dialog
  # border, so the row is budgeted for `width - 2` of the body width and ends
  # exactly where the card does.
  defp render_run_row(run, kind, state, width) do
    {_kind_letter, kind_role} = Theme.run_kind(kind)
    budget = max(0, width - @accent_width)
    spans = RunRow.spans(run, kind, state, row_opts(columns(budget), budget))

    # The whole line is one action, so clicking anywhere on the card opens the run.
    row = Support.action_spans(spans, {:local, {:navigate, {:run, run.id}}})

    %Block.Surface{
      blocks: [row],
      tone: :card,
      accent: kind_role
    }
  end

  defp columns(budget), do: Enum.find(@columns, List.last(@columns), &fits?(&1, budget))

  defp fits?(columns, budget), do: budget - RunRow.chrome_width(row_opts(columns)) >= @min_title

  defp row_opts(columns), do: Keyword.put(columns, :min_title, @min_title)

  defp row_opts(columns, budget) do
    opts = row_opts(columns)
    Keyword.put(opts, :title_width, RunRow.title_width(budget, opts))
  end

  # What the window left out, counted rather than painted off the bottom.
  defp overflow_line(_state, _width, 0, count, total) when count >= total, do: []

  defp overflow_line(state, width, first, count, total) do
    text =
      case {first, total - first - count} do
        {0, below} -> "#{below} more below"
        {above, 0} -> "#{above} more above"
        {above, below} -> "#{above} more above    #{below} more below"
      end

    [
      %Block.RichText{
        spans: [
          %Span{
            text: Density.safe("  ", state, 2),
            style: Theme.style(:plain, state.capabilities)
          },
          %Span{
            text: Density.safe(text, state, max(0, width - 2)),
            style: Theme.style(:text_faint, state.capabilities)
          }
        ]
      }
    ]
  end

  defp repeat(glyph, budget, state) do
    case cells(glyph, state) do
      0 -> ""
      width -> String.duplicate(glyph, div(budget, width))
    end
  end

  defp cells(text, state), do: Width.cells(text, state.capabilities.ambiguous_width)
end
