defmodule SwarmCodeCLI.UI.Projector.Settings do
  @moduledoc """
  The settings layer on screen (spec §3.7.13, §4.2; pass 75, E): it covers
  the shell the way the agent overlay does. Every number comes from
  `Settings.Grid`; the lines come from four helpers on that grid.

      row 0     the crumb                          (`Chrome.crumb/3`)
      row 1     the search well and the counts     (`Chrome.well/3`)
      row 2     the section strip under 120 columns (`Chrome.strip/3`)
      body      rail ‖ page ‖ note, separated by gutters, never by rules
                (`rail_lines/3`, `Page.build/3`, the note column)
      rows - 3  the message row                    (`Chrome.message/4`)
      rows - 1  the status line                    (`Chrome.status/4`)

  Under 120 columns the rail gives way to the strip, under 90 to the crumb's
  `Esc sections`; under 80 × 20 two sentences say the terminal is too small.
  Only the page rows around the cursor are built into lines.
  """

  alias SwarmCodeCLI.UI.Projector.Settings.Chrome
  alias SwarmCodeCLI.UI.Projector.Settings.Note
  alias SwarmCodeCLI.UI.Projector.Settings.Page, as: SettingsPage
  alias SwarmCodeCLI.UI.Projector.Settings.Popover, as: SettingsPopover
  alias SwarmCodeCLI.UI.Projector.Settings.Text
  alias SwarmCodeCLI.UI.Scene.{Rect, Region}
  alias SwarmCodeCLI.UI.SafeText
  alias SwarmCodeCLI.UI.Settings.{Glyphs, Grid, Layer, Nav, Sections}

  @doc "The layer's regions and cursor, or nil when it is closed."
  @spec project(map(), term()) :: nil | {[Region.t()], nil}
  def project(%{settings: %Layer{}} = state, _layout) do
    %{columns: width, rows: height} = state.size
    grid = Grid.for(width, height)

    lines =
      if grid.class == :too_small,
        do: too_small(state, width, height),
        else: screen(state, grid, state.capabilities)

    blocks = Enum.map(lines, &Text.row(state, &1, width))

    region = %Region{
      id: "settings",
      role: :main,
      rect: %Rect{x: 0, y: 0, width: width, height: height},
      label: SafeText.chrome(:empty),
      blocks: Enum.take(blocks, height),
      focus: :active
    }

    {[region], nil}
  end

  def project(_state, _layout), do: nil

  # A5 / F§too small: the one sentence, centred on two lines (it is wider
  # than the terminal that needs it); Esc still closes the layer.
  defp too_small(state, width, height) do
    lines = [
      "Settings needs 80 × 20; this terminal is #{width} × #{height}.",
      "Make it larger, or use ncode config in a shell."
    ]

    top = div(max(height - length(lines), 0), 2)

    centred =
      for words <- lines do
        pad = max(div(width - Text.text_cells(state, words), 2), 0)
        [{String.duplicate(" ", pad), :text_primary}, {words, :text_primary}]
      end

    List.duplicate([], top) ++
      centred ++ List.duplicate([], max(height - top - length(lines), 0))
  end

  # crumb, well, [strip], blank, body, blank, message, blank, status: exactly
  # `grid.rows` lines (D1: no top-margin row, the crumb is the first line).
  defp screen(state, %Grid{} = grid, caps) do
    glyphs = &Glyphs.for_caps(&1, caps)
    current = Nav.current(state, Nav.rows(state))

    head =
      [Chrome.crumb(state, grid, glyphs), Chrome.well(state, grid, glyphs)] ++
        if(grid.strip_row, do: [Chrome.strip(state, grid, glyphs)], else: [])

    head = head ++ List.duplicate([], max(grid.body_top - length(head), 0))
    {body, span} = body(state, grid, caps, current)

    lines =
      head ++
        body ++
        [
          [],
          Chrome.message(state, grid, glyphs, current),
          [],
          Chrome.status(state, grid, glyphs, current)
        ]

    lines = Enum.take(lines ++ List.duplicate([], max(grid.rows - length(lines), 0)), grid.rows)

    overlay(lines, state, span, grid)
  end

  # The body lines (rail ‖ page ‖ note, `grid.body_rows` of them) and the
  # screen line of the focused page row (an editor's popover opens under it).
  defp body(state, %Grid{} = grid, caps, current) do
    glyphs = &Glyphs.for_caps(&1, caps)

    detail? = state.settings.detail_open and current != nil

    meta =
      cond do
        sections_page?(state, grid) ->
          %{
            lines: sections_page_lines(state, grid.page.width, grid.body_rows, glyphs),
            focus_first: nil
          }

        detail? ->
          Note.detail_page(state, current, grid)

        true ->
          SettingsPage.build(state, grid, caps)
      end

    rail = if grid.rail, do: rail_lines(state, grid.rail.width, glyphs), else: nil
    note = if grid.note && not detail?, do: Note.column(state, current, meta, grid), else: nil

    lines =
      for index <- 0..(grid.body_rows - 1) do
        rail_part =
          if rail,
            do:
              [spaces(grid.rail.left)] ++
                Text.fit(state, Enum.at(rail, index, []), grid.rail.width) ++
                [spaces(grid.page.left - grid.rail.left - grid.rail.width)],
            else: [spaces(grid.page.left)]

        page_part = Text.fit(state, Enum.at(meta.lines, index, []), grid.page.width)

        note_part = if note, do: note_part(state, note, index, grid), else: []

        Text.fit(state, rail_part ++ page_part ++ note_part, grid.columns)
      end

    span =
      if is_integer(meta.focus_first),
        do:
          {grid.body_top + meta.focus_first,
           grid.body_top + (meta[:focus_last] || meta.focus_first)}

    {lines, span}
  end

  defp spaces(count), do: {String.duplicate(" ", max(count, 0)), :text_primary}

  # The gutter and the note on body line `index`: the connector `───┤` (or
  # `───╮` on the note's first line) on the focus row's line.
  defp note_part(state, note, index, %Grid{} = grid) do
    caps = state.capabilities
    gutter = grid.note.spine - grid.page.left - grid.page.width
    line = if index >= note.top, do: Enum.at(note.lines, index - note.top, []), else: []

    if note.join == index and line != [] do
      twin? = Glyphs.twin?(caps)
      dash = if twin?, do: "-", else: Glyphs.for_caps(:connector, caps)
      join = if note.top == index, do: :join_top, else: :join_mid
      join = if twin?, do: "+", else: Glyphs.for_caps(join, caps)
      [_spine | rest] = line

      [
        spaces(gutter - 3),
        {String.duplicate(dash, 3), :text_faint},
        {join, :text_faint}
        | Text.fit(state, rest, grid.note.width + 1)
      ]
    else
      [spaces(gutter) | Text.fit(state, line, grid.note.width + 2)]
    end
  end

  # ------------------------------------------------------ small, narrow

  # F16: at 80–89 columns the rail region is the sections page.
  defp sections_page?(%{settings: %Layer{region: :rail}}, %Grid{class: :small}), do: true
  defp sections_page?(_state, _grid), do: false

  # The rail's lines at the page's width, scrolled so the cursor stays in view.
  defp sections_page_lines(state, width, rows, glyphs) do
    {lines, cursor} = rail(state, width, glyphs)
    cursor = cursor || 0
    top = cursor |> Kernel.-(div(rows, 2)) |> max(0) |> min(max(length(lines) - rows, 0))
    Enum.slice(lines, top, rows)
  end

  # ------------------------------------------------------------- rail

  # The rail (pass 75, E): group words at rail column 1, the sections at
  # column 2 with their marks right, the current section on a `hover` pill.
  # When the rail has the focus the band and `▌` sit on the rail cursor (D9);
  # during a search the sections draw their match counts and no pill.
  defp rail_lines(state, width, glyphs) do
    {lines, _cursor} = rail(state, width, glyphs)
    lines
  end

  # The rail's lines and the index of the rail cursor's line (nil without focus).
  defp rail(state, width, glyphs) do
    layer = state.settings
    section = Layer.section(layer)
    focus? = layer.region == :rail
    matches = search_matches(layer)
    marks = if matches, do: %{}, else: Chrome.rail_marks(state, glyphs)

    tagged =
      Enum.flat_map(Sections.groups(), fn {group, ids} ->
        heading = if group, do: [{[{" " <> group, :text_faint}], false}], else: []

        items =
          Enum.map(ids, fn id ->
            cursor? = focus? and layer.rail_cursor == id
            pill? = id == section and matches == nil and not cursor?
            count = matches && Map.get(matches, id, 0)

            {role, mark} =
              cond do
                count == 0 -> {:text_faint, []}
                is_integer(count) -> {:text_muted, [{"#{count}", :text_muted}]}
                pill? or cursor? -> {{:text_primary, [:bold]}, Map.get(marks, id, [])}
                true -> {:text_muted, Map.get(marks, id, [])}
              end

            # the twin marks the rail cursor as it marks the page focus
            bar =
              if Glyphs.twin?(state.capabilities),
                do: {">", {:text_primary, [:bold, :reversed]}},
                else: {glyphs.(:focus_bar), :accent}

            lead =
              if cursor?,
                do: [bar, {" ", :text_primary}],
                else: [{"  ", :text_primary}]

            line =
              Text.spread(
                state,
                lead ++ [{Sections.title(id), role}],
                if(mark == [], do: [], else: mark ++ [{" ", :text_primary}]),
                width
              )

            cond do
              cursor? -> {Text.band(line), true}
              pill? -> {on_fill(line, :hover), false}
              true -> {line, false}
            end
          end)

        heading ++ items ++ [{[], false}]
      end)

    {Enum.map(tagged, &elem(&1, 0)), Enum.find_index(tagged, &elem(&1, 1))}
  end

  # Per section, the results of the query being searched (nil when no query).
  defp search_matches(%Layer{mode: :search, search: %{query: query} = search})
       when is_binary(query) and query != "" do
    case Map.get(search, :found) do
      %{results: results} -> Enum.frequencies_by(results, &elem(&1, 1).section)
      _ -> %{}
    end
  end

  defp search_matches(_layer), do: nil

  defp on_fill(segments, background) do
    Enum.map(segments, fn
      {text, {_, :on, _}} = segment when is_binary(text) -> segment
      {text, role} -> {text, {role, :on, background}}
    end)
  end

  # ---------------------------------------------------------- popover

  # Pass 75 (E, R26.3): a popover is a rounded `text_faint` box on the
  # `popover` fill over the scrimmed body; the anchor row (the focused item)
  # keeps its colours. The keys sheet, a confirmation and the pending
  # question are centred; a picker (an enum's, or the model picker an
  # editor floats) hangs under its row from the page's spine column.
  defp overlay(lines, state, span, %Grid{} = grid) do
    case box(state, span, grid) do
      nil ->
        lines

      {framed, top, left} ->
        {first, last} = span || {nil, nil}
        body = grid.body_top..(grid.body_top + grid.body_rows - 1)//1

        lines
        |> Enum.with_index()
        |> Enum.map(fn {line, index} ->
          anchor? = is_integer(first) and index >= first and index <= last
          line = if index in body and not anchor?, do: Text.scrim(line), else: line

          case index >= top and Enum.at(framed, index - top) do
            over when is_list(over) -> Text.splice(state, line, left, over, grid.columns)
            _ -> line
          end
        end)
    end
  end

  # The framed box and where it goes, or nil when no popover is open.
  defp box(%{settings: %Layer{popover: {kind, _} = popover}} = state, span, %Grid{} = grid)
       when kind in [:picker, :project_picker] do
    content = SettingsPopover.lines(state, popover)
    width = min(max(widest(state, content) + 4, 40), grid.page.width)
    height = min(length(content) + 2, grid.body_rows)
    framed = SettingsPopover.frame(state, Enum.take(content, height - 2), [], [], [], width)
    {framed, under(span, height, grid), grid.page.left}
  end

  defp box(%{settings: %Layer{popover: {_, _} = popover}} = state, _span, %Grid{} = grid) do
    content = SettingsPopover.lines(state, popover)
    width = min(max(widest(state, content) + 4, 40), grid.columns - 4)
    # a sheet may cover the well and the message row; the crumb and the
    # status line stay
    height = min(length(content) + 2, grid.rows - 2)
    framed = SettingsPopover.frame(state, Enum.take(content, height - 2), [], [], [], width)
    {framed, max(div(grid.rows - height, 2), 1), max(div(grid.columns - width, 2), 0)}
  end

  # QA #2 P0-1: an open editor whose display carries a popover (the model
  # picker, F4) floats it under its row: the title and the counts in the top
  # border, the filter, the column names and the window of models inside.
  defp box(
         %{settings: %Layer{mode: :editing, editing: %{module: module} = editing}} = state,
         span,
         %Grid{} = grid
       ) do
    case module.display(editing.state, Nav.ctx(state)) do
      %{popover: %{kind: :picker} = popover} ->
        left = min(grid.page.left, max(grid.columns - 44, 0))
        width = max(min(grid.columns - left - 2, 121), min(40, grid.columns - left))
        # the header's lines above, the status and the message below
        room = max(grid.rows - 5, 6)
        framed = SettingsPopover.picker_frame(state, popover, width, room)
        {framed, under(span, length(framed), grid), left}

      _ ->
        nil
    end
  end

  defp box(_state, _span, _grid), do: nil

  # The first screen row of a box `height` lines tall under the anchor row,
  # or as low as it fits above the message row.
  defp under({_first, last}, height, %Grid{} = grid) when last + 1 + height <= grid.rows - 2,
    do: last + 1

  defp under(_span, height, %Grid{} = grid), do: max(grid.rows - 2 - height, 1)

  defp widest(state, lines),
    do: lines |> Enum.map(&Text.cells(state, &1)) |> Enum.max(fn -> 20 end)
end
