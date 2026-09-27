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
    detail = row.detail || %Detail{title: row.label}
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

  def ladder(state, %Row{detail: %Detail{layers: layers}}, :inline) do
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
    |> Enum.intersperse([{"   ", :text_primary}])
    |> Enum.concat()
  end

  def ladder(_state, _row, :column), do: []
  def ladder(_state, _row, :inline), do: []

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
          {pad(Overview.layer_word(id), 10), word},
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
    detail = row.detail || %Detail{title: row.label}

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

  defp enum_editor(%Layer{mode: :editing, editing: %{module: Editors.Enum, row_id: id} = e}, %Row{
         id: id
       }),
       do: e

  defp enum_editor(_layer, _row), do: nil

  defp picker_open?(%Layer{popover: {:picker, _}}), do: true
  defp picker_open?(%Layer{mode: :editing, editing: %{module: ModelPicker}}), do: true
  defp picker_open?(_layer), do: false

  defp wrap(state, segments, width), do: Text.wrap_segments(state, segments, width)

  defp pad(text, width), do: String.pad_trailing(to_string(text), width)

  defp ok(caps), do: if(Glyphs.twin?(caps), do: "v", else: Glyphs.for_caps(:ok, caps))

  defp corner(id, caps), do: if(Glyphs.twin?(caps), do: "+", else: Glyphs.for_caps(id, caps))
  defp spine(caps), do: if(Glyphs.twin?(caps), do: "|", else: Glyphs.for_caps(:spine, caps))
end
