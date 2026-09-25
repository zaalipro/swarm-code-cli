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
  where you are); under 80 × 16 one sentence says the terminal is too small.
  Only the page rows around the cursor are built into lines.
  """

  alias SwarmCodeCLI.UI.Projector.Settings.Popover, as: SettingsPopover
  alias SwarmCodeCLI.UI.Projector.Settings.Text
  alias SwarmCodeCLI.UI.Scene.{Rect, Region}
  alias SwarmCodeCLI.UI.SafeText
  alias SwarmCodeCLI.UI.Settings.{Detail, Glyphs, Layer, Nav, Page, Row, Sections}

  @rail 26
  @detail 48
  @min_columns 80
  @min_rows 16
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

  defp too_small(state, width, height) do
    words = "Settings needs at least #{@min_columns} × #{@min_rows} · Esc closes"
    top = div(max(height - 1, 0), 2)
    pad = max(div(width - Text.text_cells(state, words), 2), 0)

    List.duplicate([], top) ++
      [[{String.duplicate(" ", pad), :text_primary}, {words, :text_muted}]] ++
      List.duplicate([], max(height - top - 1, 0))
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

    right =
      cond do
        Layer.depth(layer) > 1 -> [{"Esc", {:info, [:bold]}}, {" back ", :text_faint}]
        true -> [{"Esc", {:info, [:bold]}}, {" back to chat ", :text_faint}]
      end

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
  defp sub_name(%Page{sub: {_, name}}) when is_binary(name), do: name
  defp sub_name(%Page{sub: {_, _, name}}) when is_binary(name), do: name
  defp sub_name(_page), do: "…"

  # ----------------------------------------------------------- search

  defp search(state, %Layer{mode: :search, search: %{query: query}}, width) do
    caret = glyph(state, :caret)

    Text.spread(
      state,
      [{" / ", {:info, [:bold]}}, {query, :text_primary}, {caret, :focus}],
      [{"Esc clears ", :text_faint}],
      width
    )
  end

  defp search(state, _layer, width),
    do:
      Text.fit(
        state,
        [{" / ", :text_muted}, {"search every setting, provider, server and key", :text_ghost}],
        width
      )

  # ------------------------------------------------------------- rail

  defp rail_lines(state, rows) do
    layer = state.settings
    section = Layer.section(layer)
    bar = glyph(state, :focus_bar)

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
            line = Text.fit(state, [lead, {"  " <> title, role}], @rail)
            if cursor?, do: Text.select(line), else: line
          end)

        heading ++ items ++ [[]]
      end)

    Enum.take(lines, rows)
  end

  # ------------------------------------------------------------- page

  defp page_lines(state, rows, current, width, height) do
    layer = state.settings
    title = Sections.page_title(Layer.section(layer), Nav.ctx(state))
    status = page_status(layer)

    head =
      case status do
        nil -> []
        words -> [[{"  " <> words, :text_muted}], []]
      end

    _ = title

    blocks =
      rows
      |> Enum.map(fn row ->
        {row, row_lines(state, row, row == current and layer.region == :page, width)}
      end)

    lines = head ++ Enum.flat_map(blocks, &elem(&1, 1))
    lines = if rows == [], do: head ++ [[{"  Nothing here yet.", :text_muted}]], else: lines

    cursor_start =
      Enum.reduce_while(blocks, length(head), fn {row, row_lines}, at ->
        if row == current, do: {:halt, at}, else: {:cont, at + length(row_lines)}
      end)

    cursor_height =
      case Enum.find(blocks, fn {row, _} -> row == current end) do
        {_, lines} -> length(lines)
        nil -> 1
      end

    start =
      if cursor_start + cursor_height <= height,
        do: 0,
        else: min(cursor_start, cursor_start + cursor_height - height)

    Enum.slice(lines, max(start, 0), height)
  end

  defp page_status(%Layer{available: false, message: message}) when is_binary(message),
    do: message

  defp page_status(_layer), do: nil

  defp row_lines(state, %Row{kind: :heading} = row, _focused?, width) do
    [
      Text.spread(
        state,
        [{"  " <> row.label, :text_muted}],
        row.tag ++ [{" ", :text_primary}],
        width
      )
    ]
  end

  defp row_lines(state, %Row{} = row, focused?, width) do
    layer = state.settings
    editing = editing(layer, row)
    display = editing && editing.module.display(editing.state, Nav.ctx(state))
    value = if display, do: display.value, else: row.value
    extra = if display, do: Map.get(display, :lines, []), else: []

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
      if row.label == "" do
        [lead, mark, {" ", :text_primary}] ++ Text.clip(state, value, width - 4)
      else
        [lead, mark, {" ", :text_primary}] ++ label ++ [{" ", :text_primary}] ++ value_segments
      end

    main = Text.spread(state, main, tag ++ [{" ", :text_primary}], width)
    main = if focused?, do: Text.select(main), else: main

    indent = String.duplicate(" ", if(row.label == "", do: 4, else: value_column))

    continuation =
      Enum.map(row.lines ++ extra, fn line -> [{indent, :text_primary} | line] end)

    [main | continuation]
  end

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
          []
        end

      _ ->
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
