defmodule SwarmCodeCLI.UI.Projector.Settings.Page do
  @moduledoc """
  The settings page as E draws it (pass 75): the rows of `Nav.rows/1` in
  groups that hang on a one-cell spine, each group opened by its title line
  (`╭─ title … tag`), groups separated by one blank line, the focused item on
  the band, and a window that follows the cursor by group. Pure: it reads the
  projector state (`state.settings`, `state.capabilities`), the frame's
  `Settings.Grid` and answers lines of segments exactly `grid.page.width`
  cells wide.
  """

  alias SwarmCodeCLI.UI.Projector.Settings.{Note, Text}
  alias SwarmCodeCLI.UI.Reducer.Settings.Paste, as: PasteTarget

  alias SwarmCodeCLI.UI.Settings.{
    Editors,
    Glyphs,
    Grid,
    Layer,
    ModelPicker,
    Nav,
    Row,
    Search,
    Strata
  }

  @type segments :: [Text.segment()]
  @type group :: %{
          title: segments() | nil,
          tag: segments(),
          rows: [Row.t()],
          spined?: boolean(),
          danger?: boolean(),
          first_index: non_neg_integer()
        }

  # ----------------------------------------------------------- groups

  @doc """
  The page's rows as groups: a heading row opens a group (its title and
  tag); leading info rows before the first heading form one group without a
  spine or title; other rows before the first heading form a title-less
  spined group; a blank info row ends the current group. A table's heading
  (a heading with columns) stays a row of its group.
  """
  @spec groups([Row.t()]) :: [group()]
  def groups(rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce([], fn {row, index}, groups -> place(groups, row, index) end)
    |> Enum.map(fn group -> %{group | rows: Enum.reverse(group.rows)} end)
    |> Enum.reverse()
    |> Enum.reject(&(&1.title == nil and &1.rows == []))
  end

  defp place(groups, %Row{kind: :heading, columns: columns} = row, index)
       when columns in [nil, []] do
    [
      %{
        title: [{row.label, :text_muted}],
        tag: row.tag || [],
        rows: [],
        spined?: true,
        danger?: row.label == "danger",
        first_index: index
      }
      | groups
    ]
  end

  defp place(groups, %Row{} = row, index) do
    cond do
      blank?(row) ->
        [open(nil, true, index) | groups]

      groups == [] ->
        [%{open(nil, not info?(row), index) | rows: [row]}]

      true ->
        [group | rest] = groups

        if group.title == nil and not group.spined? and not info?(row),
          do: [%{open(nil, true, index) | rows: [row]}, group | rest],
          else: [%{group | rows: [row | group.rows]} | rest]
    end
  end

  defp open(title, spined?, index),
    do: %{title: title, tag: [], rows: [], spined?: spined?, danger?: false, first_index: index}

  defp info?(%Row{kind: :info}), do: true
  defp info?(_row), do: false

  # An info row with nothing to say separates what is above from what is below.
  defp blank?(%Row{kind: :info, label: "", value: value, lines: []}),
    do: Enum.all?(value, fn {text, _} -> String.trim(text) == "" end)

  defp blank?(_row), do: false

  @doc """
  A group's title line: `╭─ ` (faint), the title (muted) and its tag right
  aligned one cell inside the page's right edge (faint; a `warning` tag
  keeps its role). In the twin: `   title ----…   tag`.
  """
  @spec title_line(map(), group(), Grid.t()) :: segments()
  def title_line(state, %{title: title} = group, %Grid{page: page}) do
    caps = state.capabilities
    tag = Enum.map(group.tag, &faint_tag/1)
    right = if tag == [], do: [], else: tag ++ [{" ", :text_primary}]

    if Glyphs.twin?(caps) do
      left = [{"   ", :text_primary}] ++ title ++ [{" ", :text_primary}]
      stop = if tag == [], do: 4, else: Text.cells(state, right) + 3
      run = max(page.width - Text.cells(state, left) - stop, 0)
      line = left ++ [{String.duplicate("-", run), :text_faint}]
      Text.spread(state, line, right, page.width)
    else
      lead =
        Glyphs.for_caps(:spine_top, caps) <> Glyphs.for_caps(:title_lead, caps) <> " "

      Text.spread(state, [{lead, :text_faint} | title], right, page.width)
    end
  end

  defp faint_tag({text, role}) when role in [:warning, :error], do: {text, role}
  defp faint_tag({text, _role}), do: {text, :text_faint}

  @doc """
  The blank lines between groups: one before every group but the first
  (`true` = a blank line goes before that group), none after a title.
  """
  @spec separators([group()]) :: [boolean()]
  def separators(groups), do: groups |> Enum.with_index() |> Enum.map(fn {_, i} -> i > 0 end)

  # ----------------------------------------------- hoist and marks

  @prefixes [action: "▸ ", link: "→ ", running: "◐ "]

  @doc """
  A row as the page draws it: a leading `▸ `, `→ ` or `◐ ` (or the tier's
  twin) of its label, else of its first value segment, becomes the `:action`,
  `:link` or `:running` mark in the mark slot; a finished task's `✓ ` plus its
  muted summary becomes one `chip_ok` chip. The section's row data is not
  changed (D4).
  """
  @spec hoist(Row.t(), map()) :: Row.t()
  def hoist(%Row{} = row, caps) do
    prefixes = prefixes(caps)
    row |> hoist_prefix(prefixes) |> chip(caps)
  end

  defp prefixes(caps) do
    Enum.flat_map(@prefixes, fn {mark, prefix} ->
      twin = Glyphs.get(mark, :ascii) <> " "
      if Glyphs.tier(caps) == :ascii, do: [{mark, prefix}, {mark, twin}], else: [{mark, prefix}]
    end)
  end

  defp hoist_prefix(%Row{label: label, value: value} = row, prefixes) do
    case Enum.find(prefixes, fn {_, prefix} -> String.starts_with?(label, prefix) end) do
      {mark, prefix} ->
        %{row | label: String.replace_prefix(label, prefix, ""), marks: add_mark(row.marks, mark)}

      nil ->
        with [{text, role} | rest] <- value,
             true <- is_binary(text),
             {mark, prefix} <-
               Enum.find(prefixes, fn {_, prefix} -> String.starts_with?(text, prefix) end) do
          %{
            row
            | value: [{String.replace_prefix(text, prefix, ""), role} | rest],
              marks: add_mark(row.marks, mark)
          }
        else
          _ -> row
        end
    end
  end

  defp add_mark(marks, mark), do: if(mark in marks, do: marks, else: marks ++ [mark])

  defp chip(%Row{value: [{ok, :success}, {summary, :text_muted} | rest]} = row, caps)
       when ok in ["✓ ", "v "] do
    chip =
      if Glyphs.twin?(caps),
        do: {"[" <> ok <> summary <> "]", :success},
        else: {" " <> ok <> summary <> " ", :chip_ok}

    %{row | value: [chip | rest]}
  end

  defp chip(row, _caps), do: row

  @doc "Every ` · ` in a primary or muted segment drawn faint; the pieces keep their role."
  @spec split_dots(segments()) :: segments()
  def split_dots(segments) do
    Enum.flat_map(segments, fn
      {text, role} when role in [:text_primary, :text_muted] and is_binary(text) ->
        text
        |> String.split(" · ")
        |> Enum.intersperse(:dot)
        |> Enum.flat_map(fn
          :dot -> [{" · ", :text_faint}]
          "" -> []
          piece -> [{piece, role}]
        end)

      segment ->
        [segment]
    end)
  end

  @mark_order [:invalid, :conflict, :attention, :pending, :running, :action, :link]

  @doc """
  The one glyph of a row's mark slot, by priority; `:changed` draws nothing
  (the spine's hue says it). `danger?` draws the action mark as an error.
  """
  @spec mark(Row.t(), map(), boolean()) :: Text.segment()
  def mark(%Row{marks: marks}, caps, danger?) do
    glyph = &Glyphs.for_caps(&1, caps)

    case Enum.find(@mark_order, &(&1 in marks)) || Enum.find(marks, &swatch?/1) do
      :invalid -> {glyph.(:fail), :error}
      :conflict -> {"!", :warning}
      :attention -> {"!", {:warning, [:bold]}}
      :pending -> {glyph.(:running), :text_faint}
      :running -> {glyph.(:running), :info}
      :action -> {glyph.(:action), if(danger?, do: :error, else: :text_muted)}
      :link -> {glyph.(:link), :text_muted}
      {:swatch, texture, role} -> {glyph.(texture), role}
      nil -> {" ", :text_primary}
    end
  end

  defp swatch?({:swatch, _texture, _role}), do: true
  defp swatch?(_mark), do: false

  # -------------------------------------------------------- row lines

  @doc """
  One row's lines, each exactly `grid.page.width` cells: the spine cell, the
  mark slot, the label wrapped in its column (2-cell hanging indent), the
  value wrapped from the value column (continuations 2 cells further in),
  the tag right-aligned one cell inside the page, the hint on the focused
  row, then the row's own continuation lines and the open editor's lines.

  Opts: `focus?` (the page cursor is on it), `band?` (draw the band; false
  while a popover is open), `first?` (the first line of a title-less group
  opens it with `╭`), `last?` (the group's last row: its last line closes
  the group with `╰`), `tables` (the page's table layouts by row id).
  """
  @spec row_lines(map(), Row.t(), group(), Grid.t(), keyword()) :: [segments()]
  def row_lines(state, %Row{} = row, group, %Grid{} = grid, opts \\ []) do
    focus? = Keyword.get(opts, :focus?, false)
    row = hoist(row, state.capabilities)
    content = content(state, row, group, grid, focus?, Keyword.get(opts, :tables, %{}))
    drawer = if focus? and drawer?(state, grid), do: Note.drawer(state, row, grid), else: []
    count = length(content) + length(drawer)

    main =
      content
      |> Enum.with_index()
      |> Enum.map(fn {line, at} ->
        spine = spine(state, row, group, at, count, focus?, opts)
        line = Text.fit(state, [spine | line], grid.page.width)
        if focus? and Keyword.get(opts, :band?, true), do: band(line), else: line
      end)

    drawn =
      drawer
      |> Enum.with_index(length(content))
      |> Enum.map(fn {line, at} ->
        spine = spine(state, row, group, at, count, false, opts)
        Text.fit(state, [spine | line], grid.page.width)
      end)

    main ++ drawn
  end

  @doc """
  Whether the focused row carries the drawer (R24.5): under 160 columns,
  with the focus on the page and no popover open.
  """
  @spec drawer?(map(), Grid.t()) :: boolean()
  def drawer?(%{settings: %Layer{region: :page} = layer}, %Grid{drawer_lines: lines}),
    do: lines > 0 and not popover?(layer)

  def drawer?(_state, _grid), do: false

  # A popover is open: the layer's own, or the model picker an editor floats.
  defp popover?(%Layer{popover: {_, _}}), do: true
  defp popover?(%Layer{mode: :editing, editing: %{module: ModelPicker}}), do: true
  defp popover?(_layer), do: false

  # The spine cell of one line of a row.
  defp spine(state, row, group, at, count, focus?, opts) do
    caps = state.capabilities
    glyph = &Glyphs.for_caps(&1, caps)

    cond do
      not group.spined? ->
        {" ", :text_primary}

      Glyphs.twin?(caps) ->
        cond do
          at > 0 -> {" ", :text_primary}
          focus? -> {">", {:text_primary, [:bold, :reversed]}}
          :attention in row.marks -> {"!", :warning}
          Strata.set?(row.layer) -> {"*", :text_primary}
          true -> {"|", :text_faint}
        end

      focus? ->
        {glyph.(:focus_bar), :accent}

      at == 0 and Keyword.get(opts, :first?, false) ->
        {glyph.(:spine_top), :text_faint}

      at == count - 1 and Keyword.get(opts, :last?, false) ->
        {glyph.(:spine_end), :text_faint}

      true ->
        {glyph.(:spine), Strata.spine_role(row)}
    end
  end

  # The lines after the spine cell (page width - 1 cells each).
  defp content(state, %Row{kind: :heading} = row, _group, grid, _focus?, tables) do
    heads =
      Map.get(tables, row.id) ||
        Enum.map(row.columns, fn {t, _r, _p} -> {"#{t}  ", :text_faint} end)

    [
      Text.spread(
        state,
        [{"  ", :text_primary} | heads],
        row.tag ++ [{" ", :text_primary}],
        grid.page.width - 1
      )
    ]
  end

  defp content(state, %Row{columns: [_ | _]} = row, group, grid, focus?, tables) do
    if editing(state.settings, row) != nil or pasting?(state.settings, row) do
      setting_content(state, row, group, grid, focus?)
    else
      width = grid.page.width - 1
      cells = Map.get_lazy(tables, row.id, fn -> columns(state, row, grid.page.width - 3) end)
      mark = mark(row, state.capabilities, group.danger?)

      [
        Text.spread(
          state,
          [mark, {" ", :text_primary} | cells],
          tag(row, focus?) ++ [{" ", :text_primary}],
          width
        )
      ]
    end
  end

  defp content(state, row, group, grid, focus?, _tables),
    do: setting_content(state, row, group, grid, focus?)

  defp setting_content(state, %Row{} = row, group, %Grid{} = grid, focus?) do
    width = grid.page.width - 1
    {value, extra} = shown(state, row)
    tag = tag(row, focus?)
    mark = mark(row, state.capabilities, group.danger?)

    {head, room} =
      if row.label == "" do
        {[mark, {" ", :text_primary}], width - 2}
      else
        {[mark, {" ", :text_primary}], grid.value_offset - 1}
      end

    label =
      label_lines(state, row, group, focus?, if(row.label == "", do: 0, else: grid.label_width))

    value = value(row, value)
    tag_cells = Text.cells(state, tag)

    value_room =
      if row.label == "",
        do: room - tag_cells - 2,
        else: grid.page.width - grid.value_offset - tag_cells - 2

    {value_room, tag_on_first?} =
      if value_room >= 8, do: {value_room, true}, else: {value_room + tag_cells, false}

    value_room =
      min(
        value_room,
        if(row.label == "", do: width - 5, else: grid.page.width - grid.value_offset - 3)
      )

    # A row without a label draws its value from the label column: its first
    # line has the room to the page's edge (the storage bar is the page less
    # four), its wrapped lines two cells less.
    first_room =
      if row.label == "" and tag_cells == 0, do: max(room - 1, value_room), else: value_room

    well? = focus? and well?(state.settings, row)
    value = if well?, do: caret(state, row, value), else: value
    values = wrap_value(state, value, max(first_room, 1), max(value_room, 1))
    values = if well?, do: well(state, values, value_room), else: values
    chip? = match?([{_, :chip_ok} | _], value)

    rows = max(length(label), length(values))

    main =
      for k <- 0..(rows - 1) do
        label_k = Enum.at(label, k, [])
        value_k = Enum.at(values, k, [])

        left =
          cond do
            row.label == "" and k == 0 ->
              head ++ value_k

            row.label == "" ->
              [{"  ", :text_primary}, {"  ", :text_primary} | value_k]

            true ->
              lead = if k == 0, do: head, else: [{"  ", :text_primary}]

              gap =
                cond do
                  k == 0 and chip? -> []
                  k == 0 and well? -> [{" ", {:text_primary, :on, :hover}}]
                  true -> [{" ", :text_primary}]
                end

              indent = if k == 0, do: [], else: [{"  ", :text_primary}]

              lead ++ Text.fit(state, label_k, grid.label_width) ++ gap ++ indent ++ value_k
          end

        right =
          cond do
            k == 0 and tag_on_first? -> hint_room(state, row, focus?, value_k, tag, grid) ++ tag
            k == rows - 1 and not tag_on_first? -> tag
            true -> []
          end

        # the margin cell ends every line; only a tag or a hint needs a gap
        if right == [],
          do: Text.fit(state, left, width - 1) ++ [{" ", :text_primary}],
          else: Text.spread(state, left, right ++ [{" ", :text_primary}], width)
      end

    continuation_at = if row.label == "", do: 4, else: grid.value_offset + 1
    more_room = max(width - continuation_at - 1, 1)

    indent = {String.duplicate(" ", continuation_at), :text_primary}

    continuations =
      for line <- row.lines,
          line = if(line == [{row.key, :text_faint}], do: chips(state, line), else: line),
          wrapped <- Text.wrap_segments(state, line, more_room) do
        Text.fit(state, [indent | wrapped], width)
      end

    main ++ continuations ++ editor_lines(state, extra, indent, more_room, width)
  end

  # The open editor's (or the paste target's) lines under the row: a
  # trailing `warning` segment (`not saved`) is right-aligned one cell inside
  # the page, on the line's last wrapped line.
  defp editor_lines(state, lines, indent, room, width) do
    Enum.flat_map(lines, fn line ->
      {left, right} =
        case List.last(line) do
          {_text, :warning} = marker -> {Enum.drop(line, -1), [marker, {" ", :text_primary}]}
          _ -> {line, []}
        end

      wrapped =
        if left == [],
          do: [[]],
          else: Text.wrap_segments(state, left, max(room - Text.cells(state, right), 1))

      last = length(wrapped) - 1

      wrapped
      |> Enum.with_index()
      |> Enum.map(fn {part, at} ->
        if at == last,
          do: Text.spread(state, [indent | part], right, width),
          else: Text.fit(state, [indent | part], width)
      end)
    end)
  end

  # The value wrapped at `first` cells on its first line and `rest` after.
  defp wrap_value(state, value, room, room), do: Text.wrap_segments(state, value, room)

  defp wrap_value(state, value, first, rest) do
    case Text.wrap_segments(state, value, first) do
      [head | [_ | _] = tail] ->
        more = tail |> Enum.intersperse([{" ", :text_primary}]) |> Enum.concat()
        [head | Text.wrap_segments(state, more, rest)]

      lines ->
        lines
    end
  end

  # The band over a focused item's line; a well (an open text field) keeps
  # its own fill on its cells.
  defp band(line) do
    Enum.map(line, fn
      {_text, {_role, :on, _background}} = segment -> segment
      segment -> Text.band([segment]) |> hd()
    end)
  end

  @well_editors [
    Editors.Text,
    Editors.Number,
    Editors.Multiline,
    Editors.Color,
    Editors.LspCommand
  ]

  # A text field is open on the row: a text, number, multi-line, colour or
  # command editor, or the paste target of a secret (R26.2).
  defp well?(layer, row) do
    case editing(layer, row) do
      %{module: module} -> module in @well_editors
      nil -> pasting?(layer, row)
    end
  end

  # The editor's caret as the accent caret; the paste target's after its words.
  defp caret(state, row, value) do
    caret = {Glyphs.for_caps(:caret, state.capabilities), :accent}

    if pasting?(state.settings, row) and editing(state.settings, row) == nil do
      value ++ [caret]
    else
      Enum.map(value, fn
        {"▏", :focus} -> caret
        segment -> segment
      end)
    end
  end

  # Each value line on the `hover` well, padded to the room before the tag.
  defp well(state, lines, room) do
    Enum.map(lines, fn line ->
      line
      |> then(&Text.fit(state, &1, max(room, Text.cells(state, &1))))
      |> Enum.map(fn
        {text, {_role, :on, _background}} = segment when is_binary(text) -> segment
        {text, role} -> {text, {role, :on, :hover}}
      end)
    end)
  end

  # The value (or the open editor's, or the paste target's) and the extra
  # lines the editor or the paste draws under it.
  defp shown(state, row) do
    layer = state.settings

    case editing(layer, row) do
      %{module: module, state: editor} ->
        display = module.display(editor, Nav.ctx(state))
        {display.value, Map.get(display, :lines, [])}

      nil ->
        if pasting?(layer, row),
          do:
            {PasteTarget.words(layer.paste, Glyphs.tier(state.capabilities)),
             PasteTarget.lines(layer.paste)},
          else: {row.value, []}
    end
  end

  defp label_lines(_state, _row, _group, _focus?, 0), do: []

  defp label_lines(state, row, group, focus?, width) do
    role =
      cond do
        row.state == :disabled -> :text_faint
        row.layer == :default or row.state == :readonly -> :text_muted
        true -> :text_primary
      end

    role = if focus?, do: {role, [:bold]}, else: role
    title = group.title && Enum.map_join(group.title, "", &elem(&1, 0))
    text = strip_suffix(row.label, title)
    indent = min(row.indent || 0, max(width - 4, 0))
    pad = String.duplicate(" ", indent)

    segments = chips(state, [{text, role}])

    lines =
      case Text.wrap_segments(state, segments, width - indent) do
        [first | [_ | _] = rest] ->
          rest = rest |> Enum.intersperse([{" ", role}]) |> Enum.concat()

          [
            first
            | Enum.map(
                Text.wrap_segments(state, rest, max(width - indent - 2, 1)),
                &[{"  ", :text_primary} | &1]
              )
          ]

        lines ->
          lines
      end

    if indent == 0, do: lines, else: Enum.map(lines, &[{pad, :text_primary} | &1])
  end

  @doc """
  While a query is searched, each of its words (two characters or more, not
  an `@` filter) lights up where it matched in `segments`, case-insensitively:
  a `chip_info` chip ` word ` (the twin: `[word]`); the other runs keep their
  role. Outside a search the segments come back unchanged.
  """
  @spec chips(map(), segments()) :: segments()
  def chips(%{settings: %Layer{mode: :search, search: %{query: query}}} = state, segments)
      when is_binary(query) and query != "" do
    words =
      query
      |> String.downcase()
      |> String.split()
      |> Enum.reject(&String.starts_with?(&1, "@"))
      |> Enum.filter(&(String.length(&1) >= 2))

    twin? = Glyphs.twin?(state.capabilities)

    if words == [],
      do: segments,
      else: Enum.flat_map(segments, fn {text, role} -> chip_text(text, role, words, twin?) end)
  end

  def chips(_state, segments), do: segments

  defp chip_text("", _role, _words, _twin?), do: []

  defp chip_text(text, role, words, twin?) when is_binary(text) do
    down = String.downcase(text)

    hits =
      for word <- words, [before, _] <- [String.split(down, word, parts: 2)] do
        {String.length(before), String.length(word)}
      end

    case Enum.min_by(hits, &elem(&1, 0), fn -> nil end) do
      nil ->
        [{text, role}]

      {at, length} ->
        before = String.slice(text, 0, at)
        matched = String.slice(text, at, length)
        rest = String.slice(text, (at + length)..-1//1)

        chip =
          if twin?,
            do: {"[" <> matched <> "]", :text_primary},
            else: {" " <> matched <> " ", :chip_info}

        if(before == "", do: [], else: [{before, role}]) ++
          [chip | chip_text(rest, role, words, twin?)]
    end
  end

  defp chip_text(text, role, _words, _twin?), do: [{text, role}]

  defp value(%Row{state: :disabled}, value),
    do: value |> split_dots() |> Enum.map(fn {text, _} -> {text, :text_faint} end)

  defp value(%Row{layer: :default}, value) do
    value
    |> split_dots()
    |> Enum.map(fn
      {text, :text_primary} -> {text, :text_muted}
      segment -> segment
    end)
  end

  defp value(_row, value), do: split_dots(value)

  # The whole tag in the hue of the layer that set the value; muted on focus.
  defp tag(%Row{tag: tag}, true), do: Enum.map(tag || [], fn {text, _} -> {text, :text_muted} end)
  defp tag(%Row{tag: tag, layer: nil}, false), do: tag || []

  defp tag(%Row{tag: tag, layer: layer}, false) do
    role = Strata.role(layer)

    Enum.map(tag || [], fn
      {text, r} when r in [:text_primary, :text_muted, :text_faint] -> {text, role}
      segment -> segment
    end)
  end

  # The hint and three cells, when the focused row has room for them.
  defp hint_room(_state, _row, false, _value, _tag, _grid), do: []

  defp hint_room(state, row, true, value, tag, grid) do
    hint = if editing(state.settings, row), do: [], else: hint(row)

    fits? =
      hint != [] and
        Text.cells(state, value) + 3 + Text.cells(state, hint) + 3 + Text.cells(state, tag) <=
          grid.page.width - grid.value_offset

    if fits?, do: hint ++ [{"   ", :text_primary}], else: []
  end

  @doc """
  The focused row's hint (D8): its first `Enter` key, else its editor's verb
  (`Space switch` for a toggle, `Enter pick` for the model picker, `Enter
  edit`), else nothing.
  """
  @spec hint(Row.t()) :: segments()
  def hint(%Row{keys: keys, editor: editor}) do
    case Enum.find(keys || [], fn {key, _verb, _words} -> key == "Enter" end) do
      {key, _verb, words} ->
        [{key, :key}, {" " <> words, :text_faint}]

      nil ->
        case editor do
          {Editors.Toggle, _} -> [{"Space", :key}, {" switch", :text_faint}]
          {ModelPicker, _} -> [{"Enter", :key}, {" pick", :text_faint}]
          {_module, _opts} -> [{"Enter", :key}, {" edit", :text_faint}]
          nil -> []
        end
    end
  end

  defp pasting?(%Layer{paste: %{target: target}}, %Row{id: id}) when is_map(target),
    do: (Map.get(target, :row_id) || Map.get(target, "row_id")) == id

  defp pasting?(_layer, _row), do: false

  defp editing(%Layer{editing: %{row_id: id} = editing}, %Row{id: id}), do: editing
  defp editing(_layer, _row), do: nil

  # ---------------------------------------------------- build, window

  @type item :: %{
          index: non_neg_integer() | nil,
          kind: :title | :row | :blank | :info,
          focus?: boolean(),
          current?: boolean(),
          height: pos_integer(),
          group: non_neg_integer(),
          focusable?: boolean(),
          build: (-> [segments()])
        }

  @type meta :: %{
          lines: [segments()],
          focus_first: non_neg_integer() | nil,
          focus_last: non_neg_integer() | nil,
          group_top: non_neg_integer() | nil,
          above: non_neg_integer(),
          below: non_neg_integer()
        }

  @doc """
  The page's body: its groups as items (titles, rows, the blank lines
  between groups), windowed to `grid.body_rows` lines around the cursor, with
  where the focus and its group sit. Only the items in the window are built
  into segments; the others are measured.
  """
  @spec build(map(), Grid.t(), map()) :: meta()
  def build(state, %Grid{} = grid, _caps) do
    layer = state.settings
    rows = Nav.rows(state)
    current = Nav.current(state, rows)

    on_page? =
      layer.region == :page or
        (layer.region == :search and match?(%{cursor: id} when id != nil, layer.search))

    items =
      head_items(state, layer, grid) ++
        if rows == [],
          do: [info_item(state, grid, "Nothing here yet.")],
          else: row_items(state, rows, current, on_page?, grid)

    cursor = Enum.find(items, &(&1.kind in [:row, :info] and &1.index != nil and &1.current?))
    window(items, cursor, nil, grid, state)
  end

  defp head_items(state, %Layer{available: false, message: message}, grid)
       when is_binary(message),
       do: [info_item(state, grid, message), blank_item(-1)]

  # Pass 75 (R27.4): while a query is searched the page opens with the
  # filter vocabulary on one quiet line (wrapped, never cut), then a blank.
  defp head_items(state, %Layer{mode: :search, search: %{query: query}}, grid)
       when is_binary(query) and query != "" do
    words =
      (Search.filters() -- ["@section:", "@key:"])
      |> Enum.map(&{&1, :text_muted})
      |> Enum.intersperse({"  ", :text_muted})

    lines =
      state
      |> Text.wrap_segments([{"filters ", :text_faint} | words], max(grid.page.width - 4, 1))
      |> Enum.map(&Text.fit(state, [{"   ", :text_primary} | &1], grid.page.width))

    [
      %{
        index: nil,
        kind: :info,
        focus?: false,
        current?: false,
        focusable?: false,
        height: length(lines),
        group: -1,
        build: fn -> lines end
      },
      blank_item(-1)
    ]
  end

  defp head_items(_state, _layer, _grid), do: []

  defp info_item(state, grid, words) do
    %{
      index: nil,
      kind: :info,
      focus?: false,
      current?: false,
      focusable?: false,
      height: 1,
      group: -1,
      build: fn -> [Text.fit(state, [{"   " <> words, :text_muted}], grid.page.width)] end
    }
  end

  defp blank_item(group),
    do: %{
      index: nil,
      kind: :blank,
      focus?: false,
      current?: false,
      focusable?: false,
      height: 1,
      group: group,
      build: fn -> [[]] end
    }

  defp row_items(state, rows, current, on_page?, grid) do
    tables = tables(state, rows, grid.page.width - 3)
    band? = not popover?(state.settings)
    index_of = rows |> Enum.with_index() |> Map.new(fn {row, i} -> {row.id, i} end)

    rows
    |> groups()
    |> Enum.with_index()
    |> Enum.flat_map(fn {group, g} ->
      separator = if g > 0, do: [blank_item(g)], else: []

      title =
        if group.title,
          do: [
            %{
              index: group.first_index,
              kind: :title,
              focus?: false,
              current?: false,
              focusable?: false,
              height: 1,
              group: g,
              build: fn -> [title_line(state, group, grid)] end
            }
          ],
          else: []

      last = length(group.rows) - 1

      members =
        group.rows
        |> Enum.with_index()
        |> Enum.map(fn {row, at} ->
          current? = current != nil and row.id == current.id
          focus? = current? and on_page?

          opts = [
            focus?: focus?,
            band?: band?,
            first?: at == 0 and group.title == nil,
            last?: at == last,
            tables: tables
          ]

          %{
            index: Map.get(index_of, row.id),
            kind: if(row.kind == :info, do: :info, else: :row),
            focus?: focus?,
            current?: current?,
            focusable?: Row.focusable?(row),
            height:
              height(state, row, group, grid, tables) +
                if(focus? and drawer?(state, grid), do: grid.drawer_lines, else: 0),
            group: g,
            build: fn -> row_lines(state, row, group, grid, opts) end
          }
        end)

      separator ++ title ++ members
    end)
  end

  defp height(state, row, group, grid, tables),
    do: length(content(state, hoist(row, state.capabilities), group, grid, false, tables))

  @doc """
  The window over `items`: when the cursor's group fits the body its title
  is the first line (D18), else the cursor sits at the bottom; under 120
  columns the lines naming what is hidden above and below take their rows
  (`arrows/3`). Answers the body's lines (exactly `grid.body_rows`) and the
  body-relative lines of the focus and its group.
  """
  @spec window([item()], item() | nil, non_neg_integer() | nil, Grid.t(), map()) :: meta()
  def window(items, cursor, _group_top, %Grid{} = grid, state) do
    placed = place_items(items)
    total = Enum.reduce(items, 0, &(&1.height + &2))
    arrows? = grid.class in [:strip, :small]

    {first, room, top_lines, bottom_lines} =
      Enum.reduce_while(1..3, {nil, grid.body_rows, 0, 0}, fn _, {_first, _room, top, bottom} ->
        room = max(grid.body_rows - top - bottom, 1)
        first = first_line(placed, cursor, total, room)

        top2 =
          if arrows? and hidden(placed, first, room, :above) > 0, do: arrow_rows(grid), else: 0

        bottom2 =
          if arrows? and hidden(placed, first, room, :below) > 0, do: arrow_rows(grid), else: 0

        if {top2, bottom2} == {top, bottom},
          do: {:halt, {first, room, top, bottom}},
          else: {:cont, {first, max(grid.body_rows - top2 - bottom2, 1), top2, bottom2}}
      end)

    first = first || first_line(placed, cursor, total, room)
    visible = window_lines(placed, first, room)

    {focus_first, focus_last, group_top} =
      case cursor && Enum.find(placed, fn {item, _} -> item == cursor end) do
        {item, start} ->
          group_start = group_start(placed, item.group)
          shift = top_lines - first

          {if(item.focus?, do: start + shift),
           if(item.focus?, do: start + item.height - 1 + shift),
           max(group_start + shift, top_lines)}

        nil ->
          {nil, nil, nil}
      end

    meta = %{
      lines: visible,
      focus_first: focus_first,
      focus_last: focus_last,
      group_top: group_top,
      above: hidden(placed, first, room, :above),
      below: hidden(placed, first, room, :below),
      above_names: hidden_titles(placed, first, room, :above),
      below_names: hidden_titles(placed, first, room, :below),
      top_lines: top_lines,
      bottom_lines: bottom_lines
    }

    meta = arrows(meta, state, grid)
    %{meta | lines: pad_lines(state, meta.lines, grid)}
  end

  defp place_items(items) do
    {placed, _} = Enum.map_reduce(items, 0, fn item, at -> {{item, at}, at + item.height} end)
    placed
  end

  defp group_start(placed, group) do
    Enum.find_value(placed, 0, fn {item, at} ->
      if item.group == group and item.kind != :blank, do: at
    end)
  end

  # The first body line: the cursor's group title when the group fits, else
  # as little scrolling as keeps the cursor's item in view, cursor at the bottom.
  defp first_line(_placed, nil, _total, _room), do: 0

  defp first_line(placed, cursor, total, room) do
    {_, start} = Enum.find(placed, fn {item, _} -> item == cursor end)
    group = group_start(placed, cursor.group)

    group_end =
      placed
      |> Enum.filter(fn {item, _} -> item.group == cursor.group end)
      |> Enum.map(fn {item, at} -> at + item.height end)
      |> Enum.max(fn -> start + cursor.height end)

    first =
      if group_end - group <= room,
        do: group,
        else: min(max(group, start + cursor.height - room), start)

    first |> min(max(total - room, 0)) |> max(0)
  end

  defp window_lines(placed, first, room) do
    last = first + room

    placed
    |> Enum.filter(fn {item, at} -> at + item.height > first and at < last end)
    |> Enum.flat_map(fn {item, at} ->
      lines = item.build.()
      skip = max(first - at, 0)
      lines |> Enum.drop(skip) |> Enum.take(last - max(at, first))
    end)
  end

  defp hidden(placed, first, room, side) do
    Enum.count(placed, fn {item, at} ->
      item.focusable? and
        case side do
          :above -> at + item.height <= first
          :below -> at >= first + room
        end
    end)
  end

  defp hidden_titles(placed, first, room, side) do
    for {%{kind: :title, build: build}, at} <- placed,
        (side == :above and at < first) or (side == :below and at >= first + room) do
      build.() |> hd() |> title_words()
    end
  end

  # A title line's words (the title itself, without the spine and the tag).
  defp title_words(line) do
    Enum.find_value(line, "", fn
      {text, :text_muted} -> text
      _ -> nil
    end)
  end

  defp arrow_rows(%Grid{class: :strip}), do: 2
  defp arrow_rows(%Grid{}), do: 1

  @doc """
  Under 120 columns, the lines that name what the window hides: `↑ title ·
  title · N rows above` first and `↓ … · N rows below` last (a blank line
  beside each under the strip layout); nothing at 120 columns and more.
  """
  @spec arrows(map(), map(), Grid.t()) :: map()
  def arrows(%{top_lines: top, bottom_lines: bottom} = meta, state, %Grid{} = grid)
      when grid.class in [:strip, :small] do
    up = if top > 0, do: [arrow_line(state, meta, :above, grid)], else: []
    down = if bottom > 0, do: [arrow_line(state, meta, :below, grid)], else: []

    {up, down} =
      if grid.class == :strip,
        do: {if(up == [], do: [], else: up ++ [[]]), if(down == [], do: [], else: [[] | down])},
        else: {up, down}

    body = Enum.take(meta.lines, grid.body_rows - length(up) - length(down))
    filler = List.duplicate([], max(grid.body_rows - length(up) - length(down) - length(body), 0))
    %{meta | lines: up ++ body ++ filler ++ down}
  end

  def arrows(meta, _state, _grid), do: meta

  defp arrow_line(state, meta, side, grid) do
    {glyph, count, names, words} =
      case side do
        :above -> {:up, meta.above, meta.above_names, "above"}
        :below -> {:down, meta.below, meta.below_names, "below"}
      end

    arrow = [
      {"   ", :text_primary},
      {Glyphs.for_caps(glyph, state.capabilities) <> " ", :text_faint}
    ]

    tail = [{" · #{count} #{if count == 1, do: "row", else: "rows"} #{words}", :text_faint}]

    names =
      names
      |> Enum.map(&[{&1, :text_muted}])
      |> Enum.intersperse([{" · ", :text_faint}])
      |> Enum.concat()

    room = grid.page.width - Text.cells(state, arrow) - Text.cells(state, tail) - 1
    Text.fit(state, arrow ++ Text.clip(state, names, max(room, 0)) ++ tail, grid.page.width)
  end

  defp pad_lines(state, lines, %Grid{} = grid) do
    lines = Enum.take(lines, grid.body_rows)

    (lines ++ List.duplicate([], grid.body_rows - length(lines)))
    |> Enum.map(&Text.fit(state, &1, grid.page.width))
  end

  # ------------------------------------------------------------ tables

  # A record table's row: the name first (never dropped), then the columns
  # that fit, dropping the least important (highest priority number, the
  # rightmost among equals) until the rest fit (§4.11).
  @doc "A record table's row cut to `width`: the name first, then the columns that fit."
  @spec columns(map(), Row.t(), non_neg_integer()) :: segments()
  def columns(state, %Row{} = row, width) do
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

    # Only the first cell that reads as the label is the name: a later one
    # that happens to read the same (a key binding `Up` whose key name is
    # `Up`) keeps its own priority (QA #2 P2-6).
    name_at = if label == "", do: nil, else: Enum.find_index(columns, &match?({^label, _, _}, &1))

    cond do
      label == "" or name_at != nil ->
        columns
        |> Enum.with_index()
        |> Enum.map(fn
          {{text, role, _}, 0} -> {text, role, 0}
          {{text, role, _}, ^name_at} -> {text, role, 0}
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
  @spec tables(map(), [Row.t()], non_neg_integer()) :: %{String.t() => segments()}
  def tables(state, rows, width) do
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

  @doc """
  A label without the ` · <group title>` it ends with (`Model · this
  conversation` under `this conversation` draws `Model`); the registry label
  is untouched.
  """
  @spec strip_suffix(String.t(), String.t() | nil) :: String.t()
  def strip_suffix(label, title) when is_binary(title) and title != "" do
    suffix = " · " <> title

    if String.ends_with?(label, suffix) and label != suffix,
      do: String.replace_suffix(label, suffix, ""),
      else: label
  end

  def strip_suffix(label, _title), do: label
end
