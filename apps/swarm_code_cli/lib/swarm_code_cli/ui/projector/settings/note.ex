defmodule SwarmCodeCLI.UI.Projector.Settings.Note do
  @moduledoc """
  The note (pass 75, E): the focused row's detail as a column at 160
  columns and more that hangs from the focused group and connects to the
  focused row. Its own spine opens with `╭`, closes with `╰`, and on the
  ladder's lines takes the hue of the layer each line names. The body reads:
  title · scope, the key line, the description, the facts, where the value
  comes from (the ladder, strongest first) and the keys. While an enum editor
  is open on the row the note reads the editor's choices instead.
  """

  alias SwarmCodeCLI.UI.Projector.Settings.Text

  alias SwarmCodeCLI.UI.Settings.{
    Detail,
    Editors,
    Glyphs,
    Grid,
    Layer,
    ModelPicker,
    Nav,
    Row,
    Strata
  }

  alias SwarmCodeCLI.UI.Settings.Sections.Overview

  @type segments :: [Text.segment()]

  @doc """
  The note column for the focused row: its lines (`spine <> " " <> text`,
  `note.width + 2` cells), the body line it starts on and the body line of
  the connector (`join`, nil when the focus line is outside the note). Nil
  without a row, under 160 columns, or while the model picker is open.
  """
  @spec column(map(), Row.t() | nil, map(), Grid.t()) ::
          %{top: non_neg_integer(), lines: [segments()], join: non_neg_integer() | nil} | nil
  def column(_state, nil, _meta, _grid), do: nil
  def column(_state, _row, _meta, %Grid{note: nil}), do: nil

  def column(%{settings: %Layer{} = layer} = state, %Row{} = row, meta, %Grid{} = grid) do
    if picker_open?(layer) do
      nil
    else
      width = grid.note.width
      caps = state.capabilities

      spined =
        case enum_editor(layer, row) do
          %{} = editor -> editor_body_spined(state, row, editor, width)
          nil -> body_spined(state, row, width)
        end

      spined = Enum.take(spined, grid.body_rows)
      height = length(spined)
      last = height - 1

      lines =
        spined
        |> Enum.with_index()
        |> Enum.map(fn {{line, role}, at} ->
          spine =
            cond do
              at == 0 -> {corner(:spine_top, caps), :text_faint}
              at == last -> {corner(:note_end, caps), :text_faint}
              true -> {spine(caps), role || :text_faint}
            end

          [spine, {" ", :text_primary} | Text.fit(state, line, width)]
        end)

      focus = Map.get(meta, :focus_first)
      top = placement(Map.get(meta, :group_top) || focus || 0, focus || 0, height, grid.body_rows)
      join = if is_integer(focus) and focus >= top and focus < top + height, do: focus

      %{top: top, lines: lines, join: join}
    end
  end

  @doc """
  Where the note starts: at its group's top, slid up only as far as the
  body needs, and never so far that the focus line leaves it.
  """
  @spec placement(integer(), integer(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  def placement(group_top, focus_first, height, body_rows) do
    top = max(0, min(group_top, body_rows - height))
    if focus_first >= top + height, do: max(focus_first - height + 1, 0), else: top
  end

  @doc "The note's text lines for `row` at `width` cells (R24.3)."
  @spec body(map(), Row.t(), pos_integer()) :: [segments()]
  def body(state, %Row{} = row, width),
    do: state |> body_spined(row, width) |> Enum.map(&elem(&1, 0))

  # The body with the role of the note's spine cell on each line (the
  # ladder's lines take their layer's hue; nil = faint).
  defp body_spined(state, %Row{} = row, width) do
    detail = row.detail || untitled(state, row)
    title = title(state, detail.title, detail.scope, width)

    key_line =
      if detail.key_line, do: wrap(state, [{detail.key_line, :text_faint}], width), else: []

    description =
      if detail.description in [nil, ""],
        do: [],
        else: wrap(state, [{detail.description, :text_muted}], width)

    facts =
      Enum.flat_map(detail.facts, fn {name, value} ->
        wrap(state, [{pad(name, 9), :text_faint}, {to_string(value), :text_primary}], width)
      end)

    notes =
      Enum.flat_map(detail.notes, fn {words, role} -> wrap(state, [{words, role}], width) end)

    ladder = ladder_spined(state, detail.layers, width)
    keys = keys(state, keys_of(row, detail), width)

    [plain(title ++ key_line)]
    |> Kernel.++([plain(description), plain(facts)])
    |> Kernel.++([ladder, plain(notes), plain(keys)])
    |> Enum.reject(&(&1 == []))
    |> Enum.intersperse([{[], nil}])
    |> Enum.concat()
  end

  defp plain(lines), do: Enum.map(lines, &{&1, nil})

  defp title(state, title, scope, width) do
    title = SwarmCodeCLI.UI.Projector.Settings.Page.strip_suffix(title, scope)
    scope = if scope in [nil, ""], do: [], else: [{" · " <> scope, :text_muted}]
    wrap(state, [{title, {:text_primary, [:bold]}} | scope], width)
  end

  defp keys_of(%Row{keys: keys}, %Detail{actions: []}),
    do: Enum.map(keys || [], fn {key, _verb, words} -> {key, words} end)

  defp keys_of(_row, %Detail{actions: actions}), do: actions

  # `key words   key words`, three cells apart, wrapped at the note's width.
  defp keys(_state, [], _width), do: []

  defp keys(state, keys, width) do
    keys
    |> Enum.map(fn {key, words} -> [{key, :key}, {" " <> words, :text_faint}] end)
    |> Enum.reduce([], fn chunk, lines ->
      case lines do
        [] ->
          [chunk]

        [line | rest] ->
          if Text.cells(state, line) + 3 + Text.cells(state, chunk) <= width,
            do: [line ++ [{"   ", :text_primary} | chunk] | rest],
            else: [chunk, line | rest]
      end
    end)
    |> Enum.reverse()
  end

  @doc """
  The ladder, strongest layer first: `:column` answers one line per layer
  (`› ` on the winner, the layer word, the value, the note, `✓` right);
  `:inline` answers one line of `▎word value` cells three apart.
  """
  @spec ladder(map(), Row.t(), :column | :inline) :: [segments()] | segments()
  def ladder(state, %Row{detail: %Detail{layers: layers}}, :column),
    do: state |> ladder_spined(layers, 40) |> Enum.map(&elem(&1, 0))

  def ladder(state, %Row{} = row, :inline) do
    state
    |> ladder_cells(row)
    |> Enum.intersperse([{"   ", :text_primary}])
    |> Enum.concat()
  end

  def ladder(_state, _row, :column), do: []

  # The inline ladder's cells, strongest first: `▎word value` in the layer's
  # hue, ` ✓` after the winner (the twin: the winner's word bold, ` v`).
  defp ladder_cells(state, %Row{detail: %Detail{layers: layers}}) do
    caps = state.capabilities
    twin? = Glyphs.twin?(caps)

    layers
    |> Enum.map(fn layer ->
      id = Map.get(layer, :id)
      word = Overview.layer_word(id) <> " " <> to_string(layer.value)

      cell =
        if twin?,
          do: [{word, if(layer.winner?, do: {:text_primary, [:bold]}, else: :text_muted)}],
          else: [{Glyphs.for_caps(:ladder, caps), Strata.role(id)}, {word, :text_muted}]

      if layer.winner?,
        do: cell ++ [{" " <> ok(caps), :success}],
        else: cell
    end)
  end

  defp ladder_cells(_state, _row), do: []

  defp ladder_spined(_state, [], _width), do: []

  defp ladder_spined(state, layers, width) do
    caps = state.capabilities
    twin? = Glyphs.twin?(caps)
    head = {[{"where it comes from", :text_muted}, {" · strongest first", :text_faint}], nil}

    lines =
      Enum.map(layers, fn layer ->
        id = Map.get(layer, :id)
        winner? = Map.get(layer, :winner?, false)
        value_role = if winner?, do: :text_primary, else: :text_muted

        {lead, word} =
          cond do
            twin? and winner? -> {"  ", {:text_primary, [:bold]}}
            winner? -> {Glyphs.for_caps(:crumb, caps) <> " ", :text_muted}
            true -> {"  ", :text_muted}
          end

        note = Map.get(layer, :note)

        left = [
          {lead, :accent},
          # 10 cells, and one space at least: `project file` is 12 (407)
          {pad(Overview.layer_word(id), 9) <> " ", word},
          {pad(to_string(layer.value), 8) <> " ", value_role}
          | if(note, do: [{to_string(note), :text_faint}], else: [])
        ]

        right = if winner?, do: [{ok(caps), :success}], else: []
        role = if Map.get(layer, :set?, false), do: Strata.role(id), else: :text_faint
        {Text.spread(state, left, right, width), role}
      end)

    [head | lines]
  end

  @doc """
  The note while an enum editor is open on the row (R24.8): `<label> ·
  editing`, the key line, every choice (`✓` saved, `›` the candidate) with
  its hint under it, the ladder and the editor's keys.
  """
  @spec editor_body(map(), Row.t(), map(), pos_integer()) :: [segments()]
  def editor_body(state, %Row{} = row, editor, width),
    do: state |> editor_body_spined(row, editor, width) |> Enum.map(&elem(&1, 0))

  defp editor_body_spined(state, %Row{} = row, %{state: editor} = editing, width) do
    caps = state.capabilities
    detail = row.detail || untitled(state, row)

    title =
      wrap(state, [{row.label, {:text_primary, [:bold]}}, {" · editing", :text_muted}], width)

    key_line =
      if detail.key_line, do: wrap(state, [{detail.key_line, :text_faint}], width), else: []

    index = Map.get(editor, :index)
    original = Map.get(editor, :original)

    choices =
      editor
      |> Map.get(:choices, [])
      |> Enum.with_index()
      |> Enum.flat_map(fn {choice, at} ->
        {lead, role} =
          cond do
            choice.value == original -> {{ok(caps) <> " ", :success}, :text_muted}
            at == index -> {{Glyphs.for_caps(:crumb, caps) <> " ", :accent}, :text_primary}
            true -> {{"  ", :text_primary}, :text_muted}
          end

        role = if at == index, do: :text_primary, else: role
        hint = Map.get(choice, :hint)

        [[lead, {to_string(choice.label), role}]] ++
          if hint in [nil, ""],
            do: [],
            else:
              Enum.map(
                wrap(state, [{to_string(hint), :text_muted}], width - 2),
                &[{"  ", :text_primary} | &1]
              )
      end)

    footer =
      editing.module.display(editor, Nav.ctx(state))
      |> Map.get(:footer, [])

    [
      plain(title ++ key_line),
      plain(choices),
      ladder_spined(state, detail.layers, width),
      plain(keys(state, footer, width))
    ]
    |> Enum.reject(&(&1 == []))
    |> Enum.intersperse([{[], nil}])
    |> Enum.concat()
  end

  # ----------------------------------------------------------- drawer

  @doc """
  The drawer under 160 columns (R24.5, R24.6): the note in 3 lines at
  120-159 and 90-119 columns (`╰─ ` + the description; the ladder inline with
  the key line right; the keys with `i the whole detail` right), in 2 at
  80-89 (`╰─ ` + the key line + the ladder; the keys). Lines are the page's
  width less the spine cell, which the page draws; nothing is cut with `…`:
  what does not fit is left out whole.
  """
  @spec drawer(map(), Row.t(), Grid.t()) :: [segments()]
  def drawer(state, %Row{} = row, %Grid{drawer_lines: lines} = grid) when lines in [2, 3] do
    caps = state.capabilities
    detail = row.detail || untitled(state, row)
    width = grid.page.width - 1
    hook = {hook(caps) <> " ", :text_faint}
    key_line = if detail.key_line, do: [{detail.key_line, :text_faint}], else: []
    cells = ladder_cells(state, row)
    indent = {"  ", :text_primary}

    keys =
      keys_line(
        state,
        indent,
        Enum.reject(keys_of(row, detail), &(elem(&1, 0) == "i")),
        width
      )

    case lines do
      3 ->
        description =
          case wrap(state, [{detail.description || "", :text_muted}], max(width - 4, 1)) do
            [first | _] -> first
            [] -> []
          end

        [
          Text.fit(state, [hook | description], width),
          fill_right(state, [indent], cells, key_line, width),
          keys
        ]

      2 ->
        lead = [hook | key_line] ++ if(key_line == [], do: [], else: [{" ", :text_primary}])

        [
          fill_right(state, lead, cells, [], width),
          keys
        ]
    end
  end

  def drawer(_state, _row, _grid), do: []

  # `lead`, then as many whole `cells` (three apart) as fit before `right`
  # (right-aligned one cell inside the edge); `right` gives way when not even
  # the first cell fits beside it.
  defp fill_right(state, lead, cells, right, width) do
    right_part = if right == [], do: [], else: right ++ [{" ", :text_primary}]
    room = width - Text.cells(state, lead) - Text.cells(state, right_part) - 1

    case take_cells(state, cells, room) do
      [] when right != [] and cells != [] ->
        fill_right(state, lead, cells, [], width)

      kept ->
        Text.spread(state, lead ++ kept, right_part, width)
    end
  end

  defp take_cells(state, cells, room) do
    cells
    |> Enum.reduce_while({[], 0}, fn cell, {acc, used} ->
      gap = if acc == [], do: 0, else: 3
      size = Text.cells(state, cell)

      if used + gap + size <= room,
        do: {:cont, {[cell | acc], used + gap + size}},
        else: {:halt, {acc, used}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.intersperse([{"   ", :text_primary}])
    |> Enum.concat()
  end

  # The drawer's last line: the keys that fit, `i the whole detail` right.
  defp keys_line(state, indent, keys, width) do
    more = [{"i", :key}, {" the whole detail", :text_faint}, {" ", :text_primary}]
    chunks = Enum.map(keys, fn {key, words} -> [{key, :key}, {" " <> words, :text_faint}] end)
    room = width - Text.cells(state, [indent]) - Text.cells(state, more) - 3
    Text.spread(state, [indent | take_cells(state, chunks, room)], more, width)
  end

  defp hook(caps), do: if(Glyphs.twin?(caps), do: "+-", else: Glyphs.for_caps(:hook, caps))

  # ------------------------------------------------------ detail page

  @doc """
  The whole note as the page (R24.7), while `layer.detail_open`: one group
  titled with the row's label whose lines are the note's body at the page's
  width less four, on a spine `╭ │ ╰`, never banded. Answers the page's
  metadata with no focus line.
  """
  @spec detail_page(map(), Row.t(), Grid.t()) :: map()
  def detail_page(state, %Row{} = row, %Grid{} = grid) do
    caps = state.capabilities
    twin? = Glyphs.twin?(caps)
    title = %{title: [{row.label, :text_muted}], tag: []}
    title_line = SwarmCodeCLI.UI.Projector.Settings.Page.title_line(state, title, grid)
    body = body(state, row, max(grid.page.width - 4, 1))
    last = length(body) - 1

    lines =
      body
      |> Enum.with_index()
      |> Enum.map(fn {line, at} ->
        spine =
          cond do
            twin? -> {" ", :text_primary}
            at == last -> {Glyphs.for_caps(:spine_end, caps), :text_faint}
            true -> {Glyphs.for_caps(:spine, caps), :text_faint}
          end

        Text.fit(state, [spine, {"  ", :text_primary} | line], grid.page.width)
      end)

    all = [title_line | lines]

    # A detail longer than the body names what it hides on its last line,
    # at every width (R22.4: never cut silently).
    {shown, below} =
      if length(all) > grid.body_rows do
        kept = Enum.take(all, max(grid.body_rows - 1, 0))
        below = length(all) - length(kept)
        {kept ++ [below_line(caps, below)], below}
      else
        {all, 0}
      end

    blank = List.duplicate([], grid.body_rows - length(shown))

    %{
      lines: Enum.map(shown ++ blank, &Text.fit(state, &1, grid.page.width)),
      focus_first: nil,
      focus_last: nil,
      group_top: nil,
      above: 0,
      below: below
    }
  end

  defp below_line(caps, count) do
    [
      {"   ", :text_primary},
      {Glyphs.for_caps(:down, caps) <> " ", :text_faint},
      {"#{count} #{if count == 1, do: "line", else: "lines"} below", :text_faint}
    ]
  end

  defp enum_editor(%Layer{mode: :editing, editing: %{module: Editors.Enum, row_id: id} = e}, %Row{
         id: id
       }),
       do: e

  defp enum_editor(_layer, _row), do: nil

  defp picker_open?(%Layer{popover: {:picker, _}}), do: true
  defp picker_open?(%Layer{mode: :editing, editing: %{module: ModelPicker}}), do: true
  defp picker_open?(_layer), do: false

  # A detail-less row is titled by its label as the page draws it: no
  # `▸ `/`→ `/`◐ ` prefix, which went to the mark slot (F6b, 407).
  defp untitled(state, row),
    do: %Detail{
      title: SwarmCodeCLI.UI.Projector.Settings.Page.hoist(row, state.capabilities).label
    }

  defp wrap(state, segments, width), do: Text.wrap_segments(state, segments, width)

  defp pad(text, width), do: String.pad_trailing(to_string(text), width)

  defp ok(caps), do: if(Glyphs.twin?(caps), do: "v", else: Glyphs.for_caps(:ok, caps))

  defp corner(id, caps), do: if(Glyphs.twin?(caps), do: "+", else: Glyphs.for_caps(id, caps))
  defp spine(caps), do: if(Glyphs.twin?(caps), do: "|", else: Glyphs.for_caps(:spine, caps))
end
