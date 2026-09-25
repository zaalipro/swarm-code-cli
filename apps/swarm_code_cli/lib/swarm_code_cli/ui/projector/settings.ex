defmodule SwarmCodeCLI.UI.Projector.Settings do
  @moduledoc """
  The settings layer on screen (spec §3.7.13, §4.2): it covers the shell the
  way the agent overlay does.

      header   Settings › Section › record                     Esc back to chat
      search   / search … (or the query being typed)
      rule
      body     rail │ page │ detail (≥ 160 columns; else a drawer above the status)
      rule
      status   the last toast, or what the focused row's layer is
      footer   the focused row's keys, then the layer's

  Under 120 columns the rail gives way to the page (the header crumb says
  where you are); under 80 × 20 one sentence says the terminal is too small.
  Only the page rows around the cursor are built into lines.
  """

  alias SwarmCodeCLI.UI.Projector.Settings.Popover, as: SettingsPopover
  alias SwarmCodeCLI.UI.Projector.Settings.Text
  alias SwarmCodeCLI.UI.Reducer.Settings.Paste, as: PasteTarget
  alias SwarmCodeCLI.UI.Scene.{Rect, Region}
  alias SwarmCodeCLI.UI.SafeText
  alias SwarmCodeCLI.UI.Settings.{Detail, Glyphs, Layer, Nav, Page, Row, Sections}
  alias SwarmCodeCLI.UI.Settings.Sections.Overview

  @rail 26
  @detail 48
  @min_columns 80
  @min_rows 20
  @label 29

  @doc "The layer's regions and cursor, or nil when it is closed."
  @spec project(map(), term()) :: nil | {[Region.t()], nil}
  def project(%{settings: %Layer{}} = state, _layout) do
    %{columns: width, rows: height} = state.size

    lines =
      if width < @min_columns or height < @min_rows,
        do: too_small(state, width, height),
        else: screen(state, width, height)

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
      "Settings needs #{@min_columns} × #{@min_rows}; this terminal is #{width} × #{height}.",
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

  defp screen(state, width, height) do
    layer = state.settings
    rows = Nav.rows(state)
    current = Nav.current(state, rows)
    rail? = width >= 120
    detail? = width >= 160
    drawer = if detail?, do: 0, else: if(width < 120 or height < 30, do: 3, else: 4)
    body_rows = max(height - 6 - if(drawer > 0, do: drawer + 1, else: 0), 1)
    page_width = width - if(rail?, do: @rail + 1, else: 0) - if(detail?, do: @detail + 1, else: 0)

    page = page_lines(state, rows, current, page_width, body_rows)
    rail = if rail?, do: rail_lines(state, body_rows), else: nil
    detail = if detail?, do: detail_lines(state, current, @detail, body_rows), else: nil

    body =
      for index <- 0..(body_rows - 1) do
        [
          if(rail,
            do: Text.fit(state, Enum.at(rail, index, []), @rail) ++ [rule_v(state)],
            else: []
          ),
          Text.fit(state, Enum.at(page, index, []), page_width),
          if(detail,
            do: [rule_v(state) | Text.fit(state, Enum.at(detail, index, []), @detail)],
            else: []
          )
        ]
        |> Enum.concat()
      end

    drawer_lines =
      if drawer > 0 do
        lines = detail_lines(state, current, width - 2, drawer)

        [
          rule(state, width)
          | Enum.map(0..(drawer - 1), &[{" ", :text_primary} | Enum.at(lines, &1, [])])
        ]
      else
        []
      end

    lines =
      [header(state, layer, width), search(state, layer, width), rule(state, width)] ++
        body ++
        drawer_lines ++
        [rule(state, width), status(state, layer, current, width), footer(state, current, width)]

    lines |> popover(state, width, height) |> Enum.take(height)
  end

  # ----------------------------------------------------------- header

  defp header(state, layer, width) do
    crumb = glyph(state, :crumb)
    page = Layer.page(layer)

    trail =
      case Page.level(page) do
        :section -> [Sections.title(page.section)]
        :record -> [Sections.title(page.section), record_name(state, page)]
        :sub -> [Sections.title(page.section), sub_name(page)]
      end

    left =
      [{" Settings", {:text_primary, [:bold]}}] ++
        Enum.flat_map(trail, &[{" #{crumb} ", :text_faint}, {&1, {:text_primary, [:bold]}}])

    esc =
      cond do
        Layer.depth(layer) > 1 -> [{"Esc", {:info, [:bold]}}, {" back ", :text_faint}]
        true -> [{"Esc", {:info, [:bold]}}, {" back to chat ", :text_faint}]
      end

    right = needs_you(state) ++ esc

    Text.spread(state, left, right, width)
  end

  defp record_name(state, %Page{record: {kind, id}}) do
    case Map.get(state.settings.data.record, {kind, id}) do
      %{fields: fields} when is_map(fields) ->
        name = Map.get(fields, "name") || Map.get(fields, :name)
        if is_binary(name) and name != "", do: name, else: to_string(id)

      _ ->
        to_string(id)
    end
  end

  defp sub_name(%Page{sub: sub}) when is_binary(sub), do: sub
  defp sub_name(%Page{sub: {:rows, title, _rows}}) when is_binary(title), do: title
  defp sub_name(%Page{sub: {_, name}}) when is_binary(name), do: name
  defp sub_name(%Page{sub: {_, _, name}}) when is_binary(name), do: name
  defp sub_name(_page), do: "…"

  # The chip of what waits on you in the chat (Ctrl-N goes there).
  defp needs_you(state) do
    count =
      state.read_model.interactions
      |> Map.values()
      |> Enum.count(&(Map.get(&1, :state) == :pending))

    if count > 0,
      do: [
        {"! #{count} need#{if count == 1, do: "s", else: ""} you", :warning},
        {" Ctrl-N   ", :text_faint}
      ],
      else: []
  end

  # ----------------------------------------------------------- search

  defp search(state, %Layer{mode: :command_line, command_line: %{text: text} = line}, width) do
    caret = glyph(state, :caret)

    error =
      if line.error,
        do: [{glyph(state, :fail) <> " " <> line.error <> " ", :error}],
        else: [{"Enter runs · Esc leaves ", :text_faint}]

    Text.spread(
      state,
      [{" : ", {:info, [:bold]}}, {text, :text_primary}, {caret, :focus}],
      error,
      width
    )
  end

  defp search(state, %Layer{mode: :search, search: nil, filter: %{} = filter}, width) do
    caret = glyph(state, :caret)
    shown = state |> Nav.rows() |> Enum.count(&Row.focusable?/1)

    Text.spread(
      state,
      [{" / ", {:info, [:bold]}}, {filter.query, :text_primary}, {caret, :focus}],
      [{"filter #{filter.total} rows · #{shown} match ", :text_faint}],
      width
    )
  end

  defp search(state, %Layer{mode: :search, search: %{query: query} = search}, width) do
    caret = glyph(state, :caret)

    count =
      case Map.get(search, :found) do
        %{results: results} -> [{"#{length(results)} results · Esc clears ", :text_faint}]
        _ -> [{"Esc leaves ", :text_faint}]
      end

    Text.spread(
      state,
      [{" / ", {:info, [:bold]}}, {query, :text_primary}, {caret, :focus}],
      count,
      width
    )
  end

  defp search(state, %Layer{search: %{query: query}}, width) when query != "",
    do: Text.fit(state, [{" / ", :text_muted}, {query, :text_primary}], width)

  defp search(state, _layer, width),
    do:
      Text.spread(
        state,
        [{" / ", :text_muted}, {"search every setting, provider, server and key", :text_ghost}],
        strip(state),
        width
      )

  # What the Overview counts, on every page: changed values, attention
  # items, values the environment sets (F1's search row).
  defp strip(state) do
    summary = Overview.summary(Nav.ctx(state))

    [
      if(summary.changed > 0,
        do: [
          {glyph(state, :changed) <> " ", :text_muted},
          {"#{summary.changed} changed from default  ", :text_faint}
        ]
      ),
      if(summary.attention > 0,
        do: [{"! ", :warning}, {"#{summary.attention} need attention  ", :text_faint}]
      ),
      if(summary.env > 0, do: [{"#{summary.env} from env ", :text_faint}])
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.concat()
  end

  # ------------------------------------------------------------- rail

  defp rail_lines(state, rows) do
    layer = state.settings
    section = Layer.section(layer)
    bar = glyph(state, :focus_bar)
    marks = rail_marks(state)

    lines =
      Enum.flat_map(Sections.groups(), fn {group, ids} ->
        heading = if group, do: [[{"  " <> group, :text_faint}]], else: []

        items =
          Enum.map(ids, fn id ->
            cursor? = layer.region == :rail and layer.rail_cursor == id
            here? = id == section
            title = Sections.title(id)
            role = if here?, do: {:text_primary, [:bold]}, else: :text_muted
            lead = if cursor?, do: {bar, :focus}, else: {" ", :text_primary}
            mark = Map.get(marks, id, [])

            line =
              Text.spread(
                state,
                [lead, {"  " <> title, role}],
                mark ++ [{" ", :text_primary}],
                @rail
              )

            if cursor?, do: Text.select(line), else: line
          end)

        heading ++ items ++ [[]]
      end)

    Enum.take(lines, rows)
  end

  # Per section: `!N` attention items (the overview's), else `•N` values
  # changed from their default (terminal keys and the loaded daemon ones).
  defp rail_marks(state) do
    layer = state.settings
    changed = glyph(state, :changed)

    attention =
      case layer.data.overview do
        %{attention: items} when is_list(items) ->
          items
          |> Enum.map(&Map.get(&1, :section))
          |> Enum.reject(&is_nil/1)
          |> Enum.frequencies()

        _ ->
          %{}
      end

    daemon =
      for {key, setting} <- layer.data.values,
          Map.get(setting, :winner) not in [nil, :default],
          {:ok, entry} <- [SwarmCode.Settings.Registry.fetch(key)],
          do: entry.section

    cli =
      for {name, _value} <- state.prefs,
          {:key, key} <- [SwarmCode.Settings.Registry.resolve(name)],
          {:ok, entry} <- [SwarmCode.Settings.Registry.fetch(key)],
          match?({:cli, ^name}, entry.storage),
          do: entry.section

    changed_counts = Enum.frequencies(daemon ++ cli)

    Sections.ids()
    |> Enum.flat_map(fn id ->
      cond do
        Map.get(attention, id, 0) > 0 ->
          [{id, [{"!#{attention[id]}", :warning}]}]

        Map.get(changed_counts, id, 0) > 0 ->
          [{id, [{changed <> "#{changed_counts[id]}", :text_muted}]}]

        true ->
          []
      end
    end)
    |> Map.new()
  end

  # ------------------------------------------------------------- page

  # Only the rows in the window are laid out: heights come from the rows'
  # own continuation lines (and the open editor's), so a 400-row page costs
  # the same to draw as a 20-row one.
  defp page_lines(state, rows, current, width, height) do
    layer = state.settings

    head =
      case page_status(layer) do
        nil -> []
        words -> [[{"  " <> words, :text_muted}], []]
      end

    if rows == [] do
      head ++ [[{"  Nothing here yet.", :text_muted}]]
    else
      heights = Enum.map(rows, &row_height(state, &1))
      index = Enum.find_index(rows, &(&1 == current)) || 0
      before = heights |> Enum.take(index) |> Enum.sum()
      cursor_start = length(head) + before
      cursor_height = Enum.at(heights, index, 1)
      room = max(height - length(head), 1)

      start =
        if cursor_start + cursor_height <= height,
          do: 0,
          else: max(min(before, before + cursor_height - room), 0)

      {window, _} =
        rows
        |> Enum.zip(heights)
        |> Enum.reduce_while({[], 0}, fn {row, row_height}, {acc, at} ->
          cond do
            at >= start + room -> {:halt, {acc, at}}
            at + row_height <= start -> {:cont, {acc, at + row_height}}
            true -> {:cont, {[row | acc], at + row_height}}
          end
        end)

      skip = window_skip(rows, heights, start)
      tables = tables(state, rows, width - 3)

      lines =
        window
        |> Enum.reverse()
        |> Enum.flat_map(
          &row_lines(state, &1, &1 == current and layer.region == :page, width, tables)
        )
        |> Enum.drop(skip)

      if start == 0, do: Enum.take(head ++ lines, height), else: Enum.take(lines, height)
    end
  end

  # The lines of the first window row that sit above the window's top.
  defp window_skip(rows, heights, start) do
    {_, skip} =
      rows
      |> Enum.zip(heights)
      |> Enum.reduce_while({0, 0}, fn {_row, row_height}, {at, _} ->
        if at + row_height > start,
          do: {:halt, {at, start - at}},
          else: {:cont, {at + row_height, 0}}
      end)

    max(skip, 0)
  end

  defp row_height(state, %Row{} = row) do
    extra =
      case editing(state.settings, row) do
        nil ->
          if pasting?(state.settings, row),
            do: length(PasteTarget.lines(state.settings.paste)),
            else: 0

        editing ->
          length(Map.get(editing.module.display(editing.state, Nav.ctx(state)), :lines, []))
      end

    1 + length(row.lines) + extra
  end

  defp page_status(%Layer{available: false, message: message}) when is_binary(message),
    do: message

  defp page_status(_layer), do: nil

  # A table's heading row (a label-less heading with columns) draws the
  # column names in the table's layout.
  defp row_lines(state, %Row{kind: :heading, columns: [_ | _]} = row, _focused?, width, tables)
       when is_map_key(tables, row.id) do
    [
      Text.spread(
        state,
        [{"   ", :text_primary} | Map.fetch!(tables, row.id)],
        row.tag ++ [{" ", :text_primary}],
        width
      )
    ]
  end

  defp row_lines(state, %Row{kind: :heading} = row, _focused?, width, _tables) do
    [
      Text.spread(
        state,
        [{"  " <> row.label, :text_muted}],
        row.tag ++ [{" ", :text_primary}],
        width
      )
    ]
  end

  defp row_lines(state, %Row{} = row, focused?, width, tables) do
    layer = state.settings
    editing = editing(layer, row)
    display = editing && editing.module.display(editing.state, Nav.ctx(state))

    value =
      cond do
        display -> display.value
        pasting?(layer, row) -> PasteTarget.words(layer.paste, Glyphs.tier(state.capabilities))
        true -> row.value
      end

    extra =
      cond do
        display -> Map.get(display, :lines, [])
        pasting?(layer, row) -> PasteTarget.lines(layer.paste)
        true -> []
      end

    value_column = if width >= 84, do: 32, else: max(22, div(width * 2, 5))
    label_width = min(@label, max(value_column - 3, 8))

    lead = if focused?, do: {glyph(state, :focus_bar), :focus}, else: {" ", :text_primary}
    mark = mark(state, row.marks)
    label_role = if row.state == :readonly, do: :text_muted, else: :text_primary

    label =
      Text.fit(state, [{String.duplicate(" ", row.indent) <> row.label, label_role}], label_width)

    tag = row.tag
    tag_cells = Text.cells(state, tag)
    value_room = max(width - value_column - tag_cells - 2, 8)
    value_segments = Text.clip(state, value, value_room)

    main =
      cond do
        # A table row being pasted into (Space on an engine with no key)
        # shows the paste's words instead of its columns.
        is_list(row.columns) and pasting?(layer, row) ->
          [lead, mark, {" ", :text_primary}] ++
            label ++ [{" ", :text_primary}] ++ value_segments

        is_list(row.columns) ->
          [lead, mark, {" ", :text_primary}] ++
            Map.get_lazy(tables, row.id, fn -> columns(state, row, width - 3) end)

        row.label == "" ->
          [lead, mark, {" ", :text_primary}] ++ Text.clip(state, value, width - 4)

        true ->
          [lead, mark, {" ", :text_primary}] ++
            label ++ [{" ", :text_primary}] ++ value_segments
      end

    main = Text.spread(state, main, tag ++ [{" ", :text_primary}], width)
    main = if focused?, do: Text.select(main), else: main

    indent = String.duplicate(" ", if(row.label == "", do: 4, else: value_column))

    continuation =
      Enum.map(row.lines ++ extra, fn line -> [{indent, :text_primary} | line] end)

    [main | continuation]
  end

  # A record table's row: the name first (never dropped), then the columns
  # that fit, dropping the least important (highest priority number, the
  # rightmost among equals) until the rest fit (§4.11).
  defp columns(state, %Row{} = row, width) do
    kept = fit_columns(state, cells(row), width)

    kept
    |> Enum.map(fn {text, role, _} -> [{text, role}, {"  ", :text_primary}] end)
    |> Enum.concat()
  end

  # The cells of a table row: the name (the label, unless the section drew
  # it as the first column itself), then the columns. The name is never
  # dropped.
  defp cells(%Row{label: label, columns: columns}) do
    columns =
      Enum.map(columns, fn {text, role, priority} -> {to_string(text), role, priority} end)

    cond do
      label == "" or Enum.any?(columns, &match?({^label, _, _}, &1)) ->
        columns
        |> Enum.with_index()
        |> Enum.map(fn
          {{text, role, _}, 0} -> {text, role, 0}
          {{^label, role, _}, _} when label != "" -> {label, role, 0}
          {cell, _} -> cell
        end)

      true ->
        [{label, :text_primary, 0} | columns]
    end
  end

  # §4.15: the rows of one record table (a run of consecutive rows with
  # columns) share their columns — each padded to the table's widest cell —
  # and a table too wide for the page drops its least important column in
  # every row alike. Answers the drawn segments of each table row by row id.
  defp tables(state, rows, width) do
    rows
    |> Enum.chunk_by(&(is_list(&1.columns) and &1.columns != []))
    |> Enum.filter(fn [first | _] -> is_list(first.columns) and first.columns != [] end)
    |> Enum.reduce(%{}, fn table, acc -> Map.merge(acc, table_layout(state, table, width)) end)
  end

  defp table_layout(state, table, width) do
    rows = for row <- table, do: {row.id, cells(row)}
    count = rows |> Enum.map(fn {_, cells} -> length(cells) end) |> Enum.max()

    widths =
      for i <- 0..(count - 1) do
        rows
        |> Enum.map(fn {_, cells} ->
          case Enum.at(cells, i) do
            {text, _, _} -> Text.text_cells(state, text)
            nil -> 0
          end
        end)
        |> Enum.max()
      end

    priorities =
      for i <- 0..(count - 1) do
        if i == 0,
          do: 0,
          else:
            Enum.find_value(rows, 1, fn {_, cells} ->
              case Enum.at(cells, i) do
                {_, _, priority} -> priority
                nil -> nil
              end
            end)
      end

    kept = keep_columns(Enum.to_list(0..(count - 1)), widths, priorities, width)
    last = List.last(kept)

    Map.new(rows, fn {id, cells} ->
      segments =
        Enum.flat_map(kept, fn i ->
          {text, role, _} = Enum.at(cells, i) || {"", :text_primary, 1}
          pad = Enum.at(widths, i) - Text.text_cells(state, text)

          if i == last,
            do: [{text, role}],
            else: [{text, role}, {String.duplicate(" ", max(pad, 0) + 2), :text_primary}]
        end)

      {id, segments}
    end)
  end

  defp keep_columns(kept, widths, priorities, width) do
    total = kept |> Enum.map(&(Enum.at(widths, &1) + 2)) |> Enum.sum()
    droppable = Enum.filter(kept, &(Enum.at(priorities, &1) > 0))

    if total <= width or droppable == [] do
      kept
    else
      drop = Enum.max_by(droppable, &{Enum.at(priorities, &1), &1})
      keep_columns(List.delete(kept, drop), widths, priorities, width)
    end
  end

  defp fit_columns(state, cells, width) do
    total =
      cells |> Enum.map(fn {text, _, _} -> Text.text_cells(state, text) + 2 end) |> Enum.sum()

    droppable =
      cells
      |> Enum.with_index()
      |> Enum.filter(fn {{_, _, priority}, _} -> priority > 0 end)

    cond do
      total <= width or droppable == [] ->
        cells

      true ->
        {_, drop} = Enum.max_by(droppable, fn {{_, _, priority}, index} -> {priority, index} end)
        fit_columns(state, List.delete_at(cells, drop), width)
    end
  end

  defp pasting?(%Layer{paste: %{target: target}}, %Row{id: id}) when is_map(target),
    do: (Map.get(target, :row_id) || Map.get(target, "row_id")) == id

  defp pasting?(_layer, _row), do: false

  defp editing(%Layer{editing: %{row_id: id} = editing}, %Row{id: id}), do: editing
  defp editing(_layer, _row), do: nil

  @mark_order [:invalid, :conflict, :attention, :pending, :running, :changed]

  defp mark(state, marks) do
    case Enum.find(@mark_order, &(&1 in marks)) do
      :invalid -> {glyph(state, :fail), :error}
      :conflict -> {"!", :warning}
      :attention -> {"!", :warning}
      :pending -> {glyph(state, :running), :text_faint}
      :running -> {glyph(state, :running), :info}
      :changed -> {glyph(state, :changed), :text_muted}
      nil -> {" ", :text_primary}
    end
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

  # ----------------------------------------------------- status, footer

  defp status(state, layer, _current, width) do
    case layer.status do
      %{text: text, role: role, at: at} = status ->
        if state.now - at < Map.get(status, :ms, 4_000) do
          glyph =
            case role do
              :success -> [{" " <> glyph(state, :ok) <> " ", :success}]
              :error -> [{" " <> glyph(state, :fail) <> " ", :error}]
              :warning -> [{" ! ", :warning}]
              _ -> [{" ", :text_primary}]
            end

          Text.fit(
            state,
            glyph ++ [{text, if(role in [:success, :text_muted], do: :text_primary, else: role)}],
            width
          )
        else
          tip(state, layer, width)
        end

      _ ->
        tip(state, layer, width)
    end
  end

  # The Overview's quiet line when nothing was said.
  defp tip(state, layer, width) do
    if Layer.section(layer) == :overview and Layer.depth(layer) == 1 do
      Text.fit(
        state,
        [
          {" /settings <words> opens straight at a setting · : runs a settings command such as :set theme light",
           :text_faint}
        ],
        width
      )
    else
      []
    end
  end

  defp footer(state, current, width) do
    layer = state.settings

    keys =
      cond do
        layer.mode == :editing and layer.editing != nil ->
          display = layer.editing.module.display(layer.editing.state, Nav.ctx(state))
          Map.get(display, :footer, [])

        layer.mode == :search ->
          [{"Enter", "open"}, {"Esc", "clear"}]

        layer.mode == :paste and layer.paste != nil ->
          paste_keys(layer.paste)

        layer.region == :rail ->
          [{"Enter", "open"}, {"/", "search"}, {"Tab", "page"}]

        current != nil ->
          Enum.map(current.keys, fn {key, _verb, words} -> {key, words} end) ++
            [{"/", "search"}, {"[ ]", "section"}]

        true ->
          [{"/", "search"}, {"[ ]", "section"}]
      end

    keys = keys ++ [{"?", "keys"}]

    left =
      Enum.flat_map(keys, fn {key, words} ->
        [{" " <> key, {:info, [:bold]}}, {" " <> words <> "  ", :text_faint}]
      end)

    Text.spread(state, left, [{"settings ", :text_ghost}], width)
  end

  # cli74 F12: while a key is pasted the footer names the paste's own keys,
  # not the row's (it said "Enter paste a new key" over a pasted key).
  defp paste_keys(%{refused: {:replacement, _}}),
    do: [{"s", "save it anyway"}, {"Esc", "keep the old key"}]

  defp paste_keys(%{pending_task: task}) when task != nil, do: [{"Esc", "keep the old key"}]

  defp paste_keys(_paste),
    do: [
      {"Cmd-V", "paste"},
      {"Enter", "save"},
      {"Ctrl-U", "clear"},
      {"Ctrl-T", "type instead"},
      {"Esc", "cancel"}
    ]

  # ---------------------------------------------------------- popover

  defp popover(lines, %{settings: %Layer{popover: nil}}, _width, _height), do: lines

  defp popover(lines, state, width, height) do
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

  # ---------------------------------------------------------- helpers

  defp glyph(state, id), do: Glyphs.get(id, Glyphs.tier(state.capabilities))
  defp rule(state, width), do: [{String.duplicate(glyph(state, :rule_h), width), :border}]
  defp rule_v(state), do: {glyph(state, :rule_v), :border}
end
