defmodule SwarmCodeCLI.UI.Projector.RunPalette do
  @moduledoc """
  Centred run palette (Ctrl-R): the switching affordance.

  The same modal idea as the Ctrl-G dashboard but smaller, and ordered by
  recency rather than grouped by kind. It opens on the run you are looking at,
  narrows as you type, and Enter switches to the focused run.

  The rows are `UI.Projector.RunRow`, the single-line row the dashboard already
  solved, drawn with the palette's own columns: a narrower gauge, a leading
  selection stripe and a relative timestamp on the right. The gauge is the point
  of this view: in the old sidebar you could not see a run's progress until you
  opened it.
  """
  alias SwarmCodeCLI.UI.{SafeText, State, Theme, Width}
  alias SwarmCodeCLI.UI.Scene.{Block, Dialog, Rect, Span}
  alias SwarmCodeCLI.UI.Projector.{Density, RunRow, Support}
  alias SwarmCodeCLI.UI.Projector.Inspector.{Hive, Words}

  @dialog_width 92
  @dialog_height 20

  @gauge_width 16
  @words_width 18
  @count_width 4
  @time_width 6
  @min_title 8
  @min_query 8

  # The stripe, the `!` cell and the gaps after each, ahead of the row's first column.
  @lead_width 4
  # The gap before each trailing column.
  @trail_gap 1

  @columns [words_width: @words_width, count_width: @count_width, time_width: @time_width]
  @bare [words_width: 0, count_width: 0, time_width: 0]

  @doc "Centred dialog for the `{:run_palette, id}` layer."
  def dialog(state, _class) do
    rect = rectangle(state.size)
    runs = rows(state)
    total = length(RunRow.visible(state.read_model.runs, "", RunRow.shell_order(state)))
    height = window_height(rect)
    first = scroll(state, runs, height)

    %Dialog{
      id: "run_palette",
      rect: rect,
      title: Density.safe("Switch run", state, max(0, rect.width - 4)),
      blocks: [
        filter_line(state, length(runs), total, rect.width)
        | body(state, runs, rect, first, height)
      ],
      footer: footer(state, rect.width),
      focused_control_id: focused_run_id(state),
      body_scroll: first,
      body_visible_range: {first, min(first + height, length(runs))},
      body_total_count: length(runs)
    }
  end

  @doc "The runs the palette lists: live runs, narrowed by the query, in shell order."
  def rows(state) do
    state.read_model.runs
    |> RunRow.visible(filter_text(state), RunRow.shell_order(state))
    |> Enum.map(&RunRow.enrich(&1, state))
  end

  @doc "The listed run ids in display order."
  def ids(state), do: state |> rows() |> Enum.map(& &1.id)

  @doc """
  Up/Down move through the listed runs and wrap at both ends.

  The reducer's generic `:focus_cycle` walks this list with `Integer.mod/2`, so
  the graph holds the rows only and moving past the last row lands on the first.
  A query that matches nothing still has to offer a focusable control, or the
  cycle would divide by zero, so an empty list falls back to the footer's close.
  """
  def focus_graph(state) do
    case ids(state) do
      [] -> ["cancel"]
      ids -> ids
    end
  end

  @doc """
  The row the palette opens on: the run you are looking at, else the newest.

  `Support.run/1` resolves the current destination, which is either a run id
  directly or a conversation id that a run belongs to.
  """
  def initial_focus(state) do
    ids = ids(state)

    current =
      case Support.run(state) do
        %{id: id} -> id
        _ -> nil
      end

    if current in ids, do: current, else: List.first(ids) || "cancel"
  end

  # About 92x20, centred, and never wider than the terminal it sits in.
  defp rectangle(size) do
    width = max(1, min(@dialog_width, size.columns - 4))
    height = max(1, min(@dialog_height, size.rows - 4))

    %Rect{
      x: div(size.columns - width, 2),
      y: div(size.rows - height, 2),
      width: width,
      height: height
    }
  end

  defp footer(state, width) do
    [
      Support.action(
        Density.safe("Close", state, max(0, width - 4)),
        {:local, :close_top_layer}
      )
    ]
  end

  defp filter_text(state) do
    case state.layers do
      [{:run_palette, _} | _] -> State.runs_filter(state)
      _ -> ""
    end
  end

  defp focused_run_id(state) do
    if Map.has_key?(state.read_model.runs, state.focus), do: state.focus
  end

  # The border, the filter line and the single footer line are not rows.
  defp window_height(rect), do: max(1, rect.height - 4)

  # Only as much scrolling as it takes to keep the focused row on screen.
  defp scroll(state, runs, height) do
    index = Enum.find_index(runs, &(&1.id == state.focus)) || 0

    (index - height + 1)
    |> max(0)
    |> min(max(0, length(runs) - height))
  end

  defp body(state, [], rect, _first, _height) do
    text = if map_size(state.read_model.runs) == 0, do: "No runs yet", else: "No runs match"

    [
      %Block.RichText{
        spans: [
          RunRow.gap(1, state),
          %Span{
            text: Density.safe(text, state, max(0, rect.width - 3)),
            style: Theme.style(:text_faint, state.capabilities)
          }
        ]
      }
    ]
  end

  defp body(state, runs, rect, first, height) do
    # A Surface with no accent indents its body by one cell, and the dialog
    # border takes the other two, so the row is budgeted for width - 3.
    budget = max(0, rect.width - 3)
    opts = row_opts(columns(budget), budget)

    runs
    |> Enum.drop(first)
    |> Enum.take(height)
    |> Enum.map(&row(&1, state, opts))
  end

  # One run is one line: a single RichText of spans inside the card, never
  # sibling blocks, which a Surface would stack vertically. The shared builder
  # draws the mark, the title and the gauge; the status word and the meta are
  # replaced by the hive's own columns — the state in plain words, `⬢N` agents
  # and the age — with `!` beside the stripe when the run waits on you.
  defp row(run, state, opts) do
    kind = RunRow.theme_kind(run.kind)
    focused? = run.id == state.focus

    spans =
      RunRow.spans(
        run,
        kind,
        state,
        Keyword.merge(opts,
          lead: stripe(focused?, state) ++ bang(run, state),
          trail:
            words(run, state, opts[:words_width]) ++
              count(run, kind, state, opts[:count_width]) ++
              timestamp(run, state, opts[:time_width])
        )
      )

    line = Support.action_spans(spans, {:local, {:navigate, {:run, run.id}}})

    %Block.Surface{
      blocks: [line],
      tone: if(focused?, do: :hover, else: :card),
      accent: nil
    }
  end

  # `!` in the warning colour when the run waits on you, a blank cell otherwise.
  defp bang(run, state) do
    mark =
      if Map.get(run, :needs, 0) > 0,
        do: %Span{
          text: Support.glyph(:waiting, state),
          style: %{RunRow.tinted(:warning, state) | modifiers: [:bold]}
        },
        else: RunRow.gap(1, state)

    [mark, RunRow.gap(1, state)]
  end

  defp words(_run, _state, 0), do: []

  defp words(run, state, width) do
    role =
      cond do
        Words.waiting?(run.state) -> :warning
        run.state == :failed -> :error
        run.state == :done -> :success
        true -> :text_muted
      end

    [
      RunRow.gap(@trail_gap, state),
      %Span{
        text: Hive.fit(Hive.run_words(run, state), width, state),
        style: RunRow.tinted(role, state)
      }
    ]
  end

  # `⬢3`: the agent count in the kind's colour.
  defp count(_run, _kind, _state, 0), do: []

  defp count(run, kind, state, width) do
    {_letter, role} = Theme.run_kind(kind)
    glyph = SafeText.value(Support.glyph(:hex_full, state))
    text = glyph <> Integer.to_string(Hive.total(run, state))

    [
      RunRow.gap(@trail_gap, state),
      %Span{
        text: Density.safe(RunRow.pad(text, width, state), state, width),
        style: RunRow.tinted(role, state)
      }
    ]
  end

  # The selection stripe. Both stripe glyphs are one cell under both width
  # policies, so the columns stay aligned whether or not a row is focused, and
  # the ASCII twins ("#" and "-") keep the selection legible without colour.
  defp stripe(focused?, state) do
    {token, role} = if focused?, do: {:stripe, :focus}, else: {:stripe_off, :border_soft}

    [
      %Span{text: Support.glyph(token, state), style: RunRow.tinted(role, state)},
      RunRow.gap(1, state)
    ]
  end

  defp timestamp(_run, _state, 0), do: []

  defp timestamp(run, state, width) do
    # A run the read model holds no clock fact for leaves the column blank
    # rather than showing an age nothing in the read model supports.
    text = RunRow.age(run, state) || ""

    [
      RunRow.gap(@trail_gap, state),
      %Span{
        text: Density.safe(RunRow.pad_leading(text, width, state), state, width),
        style: Theme.style(:text_faint, state.capabilities)
      }
    ]
  end

  # Column widths for a row budget: the first set that still leaves a readable
  # title. The gauge is the point of this view, so it is never dropped; the
  # columns around it go in order of how little they carry, the timestamp first,
  # then the agent count, then the words.
  defp columns(budget) do
    [
      @columns,
      Keyword.put(@columns, :time_width, 0),
      @columns |> Keyword.put(:time_width, 0) |> Keyword.put(:count_width, 0),
      @bare
    ]
    |> Enum.find(@bare, &fits?(&1, budget))
  end

  defp fits?(columns, budget), do: budget - RunRow.chrome_width(row_opts(columns)) >= @min_title

  defp row_opts(columns, budget) do
    opts = row_opts(columns)
    Keyword.put(opts, :title_width, RunRow.title_width(budget, opts))
  end

  # The status word and the meta are the shared builder's columns; the palette
  # draws its own in the trail, so those are dropped and the trail's cells are
  # reserved for the title budget instead.
  defp row_opts(columns) do
    [
      status_width: 0,
      meta_width: 0,
      words_width: columns[:words_width],
      count_width: columns[:count_width],
      time_width: columns[:time_width],
      gauge_width: @gauge_width,
      min_title: @min_title,
      reserved: @lead_width + trail_width(columns)
    ]
  end

  defp trail_width(columns) do
    cost(columns[:words_width]) + cost(columns[:count_width]) + cost(columns[:time_width])
  end

  defp cost(0), do: 0
  defp cost(width), do: @trail_gap + width

  # The query beside its match count, with the key hints while there is room.
  defp filter_line(state, shown, total, width) do
    query = State.runs_filter(state)
    inner = max(0, width - 2)

    count = "#{shown} of #{total}"
    hints = hints(state)
    count_width = cells(count, state)
    hints_width = cells(hints, state)

    # One leading gap, the search mark, one gap, then the query, two, the count.
    spare = inner - 3 - 2 - count_width
    room? = spare - 2 - hints_width >= @min_query
    query_width = max(0, if(room?, do: spare - 2 - hints_width, else: spare))

    faint = Theme.style(:text_faint, state.capabilities)

    query_style =
      if query == "",
        do: faint,
        else: %{Theme.style(:text_primary, state.capabilities) | modifiers: [:bold]}

    query_text = if query == "", do: "filter runs", else: query

    head = [
      RunRow.gap(1, state),
      %Span{text: Support.glyph(:search_mark, state), style: RunRow.tinted(:focus, state)},
      RunRow.gap(1, state),
      %Span{
        text: Density.safe(RunRow.pad(query_text, query_width, state), state, query_width),
        style: query_style
      },
      RunRow.gap(2, state),
      %Span{text: Density.safe(count, state, count_width), style: faint}
    ]

    tail =
      if room?,
        do: [
          RunRow.gap(2, state),
          %Span{text: Density.safe(hints, state, hints_width), style: faint}
        ],
        else: []

    %Block.RichText{spans: head ++ tail}
  end

  # The hint arrows are row text rather than catalogue glyphs, so the ASCII form
  # is spelled out here, where the terminal's capabilities are known.
  defp hints(%{capabilities: %{ascii?: true}}), do: "Up/Dn move  Enter open  Ctrl-R close"
  defp hints(_state), do: "⇅ move  ↵ open  Ctrl-R close"

  defp cells(text, state), do: Width.cells(text, state.capabilities.ambiguous_width)
end
