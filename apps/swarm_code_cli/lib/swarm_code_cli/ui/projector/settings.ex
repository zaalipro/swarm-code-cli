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
  alias SwarmCodeCLI.UI.Projector.Settings.Page, as: SettingsPage
  alias SwarmCodeCLI.UI.Projector.Settings.Popover, as: SettingsPopover
  alias SwarmCodeCLI.UI.Projector.Settings.Text
  alias SwarmCodeCLI.UI.Scene.{Rect, Region}
  alias SwarmCodeCLI.UI.SafeText
  alias SwarmCodeCLI.UI.Settings.{Detail, Glyphs, Grid, Layer, Nav, Row, Sections}

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
      "Make it larger, or use swarmcode config in a shell."
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
    {body, anchor} = body(state, grid, caps, current)

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

    lines
    |> editor_popover(state, anchor, grid)
    |> popover(state, grid)
  end

  # The body lines (rail ‖ page ‖ note, `grid.body_rows` of them) and the
  # screen line of the focused page row (an editor's popover opens under it).
  defp body(state, %Grid{} = grid, caps, current) do
    glyphs = &Glyphs.for_caps(&1, caps)

    meta =
      if sections_page?(state, grid),
        do: %{
          lines: sections_page_lines(state, grid.page.width, grid.body_rows, glyphs),
          focus_first: nil
        },
        else: SettingsPage.build(state, grid, caps)

    rail = if grid.rail, do: rail_lines(state, grid.rail.width, glyphs), else: nil
    note = if grid.note, do: note_lines(state, current, grid), else: nil

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

        note_part =
          if note,
            do:
              [spaces(grid.note.spine - grid.page.left - grid.page.width)] ++
                Text.fit(state, Enum.at(note, index, []), grid.note.width + 2),
            else: []

        Text.fit(state, rail_part ++ page_part ++ note_part, grid.columns)
      end

    anchor = if is_integer(meta.focus_first), do: grid.body_top + meta.focus_first

    {lines, anchor}
  end

  defp spaces(count), do: {String.duplicate(" ", max(count, 0)), :text_primary}

  # The note column's lines at 160 columns and more (task 319 hangs it from
  # the focused group; until then the detail of the focused row from the top).
  defp note_lines(state, current, %Grid{note: note, body_rows: rows}) do
    state
    |> detail_lines(current, note.width + 2, rows)
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

            lead =
              if cursor?,
                do: [{glyphs.(:focus_bar), :accent}, {" ", :text_primary}],
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

  # ----------------------------------------------------------- detail

  defp detail_lines(_state, nil, _width, _rows), do: []

  defp detail_lines(state, %Row{detail: nil} = row, width, rows),
    do: detail_lines(state, %{row | detail: %Detail{title: row.label}}, width, rows)

  defp detail_lines(state, %Row{detail: %Detail{} = detail} = row, width, rows) do
    inner = max(width - 2, 10)
    scope = if detail.scope, do: [{" · " <> detail.scope, :text_faint}], else: []

    title = [[{" ", :text_primary}, {detail.title, {:text_primary, [:bold]}} | scope]]
    key_line = if detail.key_line, do: [[{" " <> detail.key_line, :text_faint}]], else: []

    description =
      if detail.description in [nil, ""],
        do: [],
        else: [
          []
          | Enum.map(Text.wrap(state, detail.description, inner), &[{" " <> &1, :text_primary}])
        ]

    facts =
      if detail.facts == [],
        do: [],
        else: [
          []
          | Enum.map(detail.facts, fn {name, value} ->
              [{" " <> pad(name, 10), :text_muted}, {value, :text_primary}]
            end)
        ]

    layers =
      if detail.layers == [] do
        []
      else
        crumb = glyph(state, :crumb)
        ok = glyph(state, :ok)

        [[], [{" where it comes from", :text_muted}, {"   strongest first", :text_faint}]] ++
          Enum.map(detail.layers, fn layer ->
            lead = if layer.winner?, do: " #{crumb} ", else: "   "
            role = if layer.winner?, do: :text_primary, else: :text_muted
            win = if layer.winner?, do: [{"  " <> ok, :success}], else: []
            note = if layer.note, do: [{"  " <> to_string(layer.note), :text_faint}], else: []
            [{lead <> pad(layer.layer, 18), role}, {layer.value, role}] ++ note ++ win
          end)
      end

    notes = Enum.map(detail.notes, fn {words, role} -> [{" " <> words, role}] end)
    notes = if notes == [], do: [], else: [[] | notes]

    keys =
      case row.keys do
        [] ->
          []

        keys ->
          [
            []
            | Enum.map(keys, fn {key, _verb, words} ->
                [{" " <> key, {:info, [:bold]}}, {" " <> words, :text_faint}]
              end)
          ]
      end

    (title ++ key_line ++ description ++ facts ++ layers ++ notes ++ keys)
    |> Enum.map(&Text.clip(state, &1, width))
    |> Enum.take(rows)
  end

  defp pad(text, width), do: String.pad_trailing(to_string(text), width)

  # ---------------------------------------------------------- popover

  defp popover(lines, %{settings: %Layer{popover: nil}}, _grid), do: lines

  defp popover(lines, state, %Grid{columns: width, rows: height}) do
    box = SettingsPopover.lines(state, state.settings.popover)
    widest = box |> Enum.map(&Text.cells(state, &1)) |> Enum.max(fn -> 20 end)
    box_width = min(max(widest + 4, 40), width - 4)

    box_height = min(length(box) + 2, height - 4)
    top = max(div(height - box_height, 2), 1)
    left = max(div(width - box_width, 2), 0)
    h = glyph(state, :rule_h)
    v = glyph(state, :rule_v)
    inner = box_width - 2

    framed =
      [
        [
          {glyph(state, :corner_tl) <> String.duplicate(h, inner) <> glyph(state, :corner_tr),
           :border}
        ]
      ] ++
        Enum.map(Enum.take(box, box_height - 2), fn line ->
          [{v, :border}, {" ", :popover}] ++ Text.fit(state, line, inner - 1) ++ [{v, :border}]
        end) ++
        [
          [
            {glyph(state, :corner_bl) <> String.duplicate(h, inner) <> glyph(state, :corner_br),
             :border}
          ]
        ]

    Enum.with_index(lines)
    |> Enum.map(fn {line, index} ->
      case Enum.at(framed, index - top) do
        nil -> line
        _ when index < top -> line
        over -> Text.splice(state, line, left, over, width)
      end
    end)
  end

  # ------------------------------------------------- editor popover (F4)

  # QA #2 P0-1: an open editor whose display carries a popover (the model
  # picker) floats it under its row, as F4 draws it: the title and the counts
  # in the top border, the filter, the list, the keys and `N of M` inside.
  # Nothing drew it: the footer changed and the list was never seen.
  defp editor_popover(
         lines,
         %{settings: %Layer{mode: :editing, editing: %{module: module} = editing}} = state,
         anchor,
         %Grid{columns: width, rows: height} = grid
       ) do
    page_left = grid.page.left - 2

    case module.display(editing.state, Nav.ctx(state)) do
      %{popover: %{kind: :picker} = popover} ->
        float(lines, state, popover, anchor, page_left, width, height)

      _ ->
        lines
    end
  end

  defp editor_popover(lines, _state, _anchor, _grid), do: lines

  defp float(lines, state, popover, anchor, page_left, width, height) do
    left = min(page_left + 2, max(width - 44, 0))
    box_width = max(min(width - left - 2, 121), min(40, width - left))
    inner = box_width - 2
    # the header's three lines above, the status and the footer below
    room = max(height - 5, 6)
    body = SettingsPopover.editor_lines(state, popover, inner - 1, room - 2)
    box_height = length(body) + 2

    top =
      cond do
        is_integer(anchor) and anchor + 1 + box_height <= height - 2 -> anchor + 1
        true -> max(height - 2 - box_height, 1)
      end

    h = glyph(state, :rule_h)
    v = glyph(state, :rule_v)

    framed =
      [top_border(state, popover, box_width)] ++
        Enum.map(body, fn line ->
          [{v, :border}, {" ", :popover}] ++ Text.fit(state, line, inner - 1) ++ [{v, :border}]
        end) ++
        [
          [
            {glyph(state, :corner_bl) <> String.duplicate(h, inner) <> glyph(state, :corner_br),
             :border}
          ]
        ]

    Enum.with_index(lines)
    |> Enum.map(fn {line, index} ->
      case Enum.at(framed, index - top) do
        nil -> line
        _ when index < top -> line
        over -> Text.splice(state, line, left, over, width)
      end
    end)
  end

  # `┌─ Chat model · new conversations ───── 4 providers · 23 models ─┐`
  defp top_border(state, popover, box_width) do
    h = glyph(state, :rule_h)

    right = [
      {" " <> to_string(Map.get(popover, :meta) || "") <> " ", :text_faint},
      {h <> glyph(state, :corner_tr), :border}
    ]

    title =
      [{to_string(Map.get(popover, :title) || ""), {:text_primary, [:bold]}}] ++
        case Map.get(popover, :subtitle) do
          nil -> []
          sub -> [{" · " <> to_string(sub), :text_faint}]
        end

    lead = [{glyph(state, :corner_tl) <> h <> " ", :border}]
    title = Text.clip(state, title, max(box_width - Text.cells(state, right) - 5, 1))
    used = Text.cells(state, lead) + Text.cells(state, title) + Text.cells(state, right)
    fill = [{" " <> String.duplicate(h, max(box_width - used - 1, 0)), :border}]
    lead ++ title ++ fill ++ right
  end

  # ---------------------------------------------------------- helpers

  defp glyph(state, id), do: Glyphs.for_caps(id, state.capabilities)
end
