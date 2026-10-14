defmodule SwarmCodeCLI.UI.Projector.Home do
  @moduledoc """
  orbit: Home on screen. It covers the whole screen the way Settings does and is
  projected before the agent overlay and the shell (D7: too_small, Settings,
  Home, Overlay, Shell).

  The screen is drawn on a `Home.Canvas` after the designer's frames (D.html,
  `gen_D.py`), by the size class `Home.Grid` picks:

      row 0     the title row: mark, project, `▌ home`, the version
      row 1     each orbit's project name over its top
      2..       the mark, the arcs with their beads, the age ticks at the right
      +1        each orbit's count under its bottom
      +2..+4    the legend: ring, bars, dot (never only a picture)
      +6        `resume in <project>` and the keys that open a row
      +7..      the resume list, and beside it the preview of the selected row
      rows - 3  the composer (grows to three lines), then its hint row
      rows - 1  the status row (`Status.project(…, home: true)`)

  Smaller classes drop what they cannot hold: `:orbit_s` the preview, `:compact`
  the ellipses (one line per project), `:minimal` the orbits altogether.
  """

  alias SwarmCodeCLI.UI.{Drafts, Editor, Keymap, SafeText, Width}
  alias SwarmCodeCLI.UI.Home
  alias SwarmCodeCLI.UI.Home.{Canvas, Grid, Mark, Orbits, View}
  alias SwarmCodeCLI.UI.Keymap.Bindings
  alias SwarmCodeCLI.UI.Projector.{Density, KeyLabel, Status}
  alias SwarmCodeCLI.UI.Projector.Panel.Glyph
  alias SwarmCodeCLI.UI.SafeText.Limits
  alias SwarmCodeCLI.UI.Scene.{Cursor, Rect, Region}
  alias SwarmCodeCLI.UI.Settings.Glyphs

  # How the list and the preview sit on each orbit class (columns).
  @columns %{
    orbit_m: %{title: 32, words: 42, runs: 60, end: 77, preview: 81},
    orbit_l: %{title: 36, words: 48, runs: 70, end: 92, preview: 97},
    orbit_s: %{title: 32, words: 42, runs: 60, end: nil, preview: nil}
  }

  @placeholder "Type to start a new conversation, or / for commands…"

  @doc "Home's regions and cursor, or nil while it is closed or the terminal is too small."
  @spec project(map(), term()) :: nil | {[Region.t()], Cursor.t() | nil}
  def project(%{home: %Home{}} = state, layout) do
    %{columns: width, rows: height} = state.size
    tier = Glyph.tier(state.capabilities)
    grid = Grid.for(width, height, tier, max(length(View.projects(state)), 1))

    if layout.class == :too_small or grid.class == :too_small do
      nil
    else
      canvas = Canvas.new(state, width, height - 1)
      {canvas, cursor} = draw(canvas, state, grid, tier)
      status = Status.project(state, layout.class, width, home: true)

      region = %Region{
        id: "home",
        role: :main,
        rect: %Rect{x: 0, y: 0, width: width, height: height},
        label: SafeText.chrome(:empty),
        blocks: Canvas.rows(canvas, state) ++ status,
        focus: :active
      }

      {[region], cursor}
    end
  end

  def project(_state, _layout), do: nil

  # ---------------------------------------------------------------- classes

  defp draw(canvas, state, %{class: class} = grid, tier)
       when class in [:orbit_l, :orbit_m, :orbit_s] do
    canvas
    |> title_row(state)
    |> orbits(state, grid, tier)
    |> legend(state, grid, tier)
    |> resume(state, grid, tier)
    |> composer(state, grid, tier)
  end

  defp draw(canvas, state, grid, tier) do
    # :compact and :minimal arrive with U6.
    canvas
    |> title_row(state)
    |> composer(state, grid, tier)
  end

  # ------------------------------------------------------------- title row

  defp title_row(canvas, state) do
    logo = :logo_mark |> SwarmCodeCLI.UI.Projector.Support.glyph(state) |> SafeText.value()
    marker = Glyphs.for_caps(:focus_bar, state.capabilities)

    {canvas, _} = Canvas.puts(canvas, 0, 0, [{" " <> logo <> " ", {:accent, [:bold]}}])

    {canvas, col} =
      Canvas.puts(canvas, 0, 3, [
        {View.project_name(state), {:text_primary, [:bold]}},
        {"   ", :text_primary}
      ])

    {canvas, stop} =
      Canvas.puts(canvas, 0, col, [{marker, :accent}, {" home ", :text_primary}])

    canvas = Canvas.paint(canvas, 0, col, stop, :hover)

    case View.version(state) do
      nil -> canvas
      version -> canvas |> Canvas.rputs(0, canvas.width - 1, [{version, :text_ghost}]) |> elem(0)
    end
  end

  # ------------------------------------------------- the mark and the orbits

  defp orbits(canvas, state, grid, tier) do
    {r0, c0} = grid.mark_origin
    mark = Mark.cells(grid.mark, View.mark_opts(state))

    canvas =
      Enum.reduce(mark, canvas, fn {r, c, char, role}, acc ->
        Canvas.put_locked(acc, r0 + r, c0 + c, char, role)
      end)

    projects = View.projects(state) |> Enum.take(grid.orbit_slots)

    case projects do
      [] -> name_only(canvas, state, grid)
      _ -> draw_orbits(canvas, state, grid, tier, projects)
    end
  end

  # Until the overview answers: this project's name over its orbit and nothing else.
  defp name_only(canvas, state, grid) do
    o = Orbits.new(grid.mark, grid.mark_origin, [grid.orbit_first])
    col = Orbits.col_at(o, 0, grid.r_top)

    {canvas, _} =
      Canvas.put(canvas, grid.r_top - 1, col, View.project_name(state), {:text_primary, [:bold]})

    canvas
  end

  defp draw_orbits(canvas, state, grid, tier, projects) do
    cols = Grid.orbit_columns(grid, length(projects))
    o = Orbits.new(grid.mark, grid.mark_origin, cols)
    map_focus = state.home.focus == :map
    selected_orbit = if map_focus, do: state.home.orbit
    indexed = Enum.with_index(projects)

    # Arcs first, so beads and labels clear room in them.
    canvas =
      Enum.reduce(indexed, canvas, fn {project, k}, acc ->
        role =
          cond do
            k == selected_orbit -> :text_muted
            project.current -> :text_faint
            true -> :text_ghost
          end

        step = if project.current or k == selected_orbit, do: 1, else: 2
        arc(acc, o, k, role, step)
      end)

    {canvas, spots} =
      Enum.reduce(indexed, {canvas, %{}}, fn {project, k}, {acc, spots} ->
        {acc, row_spots} = beads(acc, state, o, k, project, tier, selected_orbit)
        {acc, Map.put(spots, k, row_spots)}
      end)

    canvas =
      Enum.reduce(o |> Orbits.ticks(), canvas, fn {row, label}, acc ->
        acc |> Canvas.rputs(row, canvas.width - 1, [{label, :text_ghost}]) |> elem(0)
      end)

    canvas = Enum.reduce(indexed, canvas, &orbit_labels(&2, state, o, &1, selected_orbit))

    if grid.wide_extras?,
      do: wide_titles(canvas, o, indexed, spots, selected_orbit),
      else: canvas
  end

  defp arc(canvas, o, k, role, step) do
    cells = Orbits.arc_cells(o, k, step, canvas.locks)

    Enum.reduce(cells, canvas, fn {{row, col}, bits}, acc ->
      if Canvas.free_for_arc?(acc, row, col),
        do: acc |> Canvas.put(row, col, <<0x2800 + bits::utf8>>, role) |> elem(0),
        else: acc
    end)
  end

  defp beads(canvas, state, o, k, project, tier, selected_orbit) do
    spots = Orbits.bead_spots(o, k, View.ages(project, state.now))

    canvas =
      project.conversations
      |> Enum.zip(spots)
      |> Enum.with_index()
      |> Enum.reduce(canvas, fn {{conversation, {row, col}}, index}, acc ->
        {text, role, bold?} = Orbits.bead(conversation, state.now, tier)
        role = if bold?, do: {role, [:bold]}, else: role
        {acc, _} = Canvas.put(acc, row, col, text, role)

        acc =
          if k == selected_orbit and index == state.home.bead,
            do: Canvas.paint(acc, row, col, col + 1, :selection),
            else: acc

        acc
        |> Canvas.clear_braille(row, col - 1, col)
        |> Canvas.clear_braille(row, col + 1, col + 2)
      end)

    {canvas, spots}
  end

  # Each orbit is named at its top ("now") and counted at its bottom (30 d).
  defp orbit_labels(canvas, _state, o, {project, k}, selected_orbit) do
    name_role =
      cond do
        k == selected_orbit -> {:text_primary, [:bold]}
        project.current -> {:text_primary, [:bold]}
        true -> :text_muted
      end

    {canvas, _} =
      Canvas.put(canvas, o.r_top - 1, Orbits.col_at(o, k, o.r_top), project.name, name_role)

    canvas =
      if k == selected_orbit,
        do:
          Canvas.paint(
            canvas,
            o.r_top - 1,
            Orbits.col_at(o, k, o.r_top),
            Orbits.col_at(o, k, o.r_top) + Canvas.cells(canvas, project.name),
            :selection
          ),
        else: canvas

    {count, live} = View.count_words(project)

    count_role =
      if project.current and project.conversation_count == 0, do: :accent, else: :text_faint

    parts =
      [{count, count_role}] ++ if(live, do: [{" · ", :text_ghost}, {live, :text_muted}], else: [])

    Canvas.puts(canvas, o.r_bot + 1, Orbits.col_at(o, k, o.r_bot), parts) |> elem(0)
  end

  # The wide class titles the newest bead of every orbit, two columns to its right.
  defp wide_titles(canvas, o, indexed, spots, selected_orbit) do
    Enum.reduce(indexed, canvas, fn {project, k}, acc ->
      with [conversation | _] <- project.conversations,
           true <- k != selected_orbit,
           [{row, col} | _] <- Map.get(spots, k) do
        title = Canvas.clip(acc, conversation.title, 24)
        at = col + 2
        acc = Canvas.clear_braille(acc, row, at - 1, at + Canvas.cells(acc, title) + 1)
        role = if project.current, do: :text_primary, else: :text_muted
        _ = o
        acc |> Canvas.put(row, at, title, role) |> elem(0)
      else
        _ -> acc
      end
    end)
  end

  # ------------------------------------------------------------- the legend

  defp legend(canvas, state, grid, tier) do
    row = grid.legend_row
    ring = View.ring(state)
    ready? = View.overview(state) != nil
    pending = if ready?, do: nil, else: [{"…", :text_ghost}]

    canvas = ring_row(canvas, state, row, grid, ring, tier, pending)
    canvas = scheduled_row(canvas, state, row, grid, tier)
    canvas = bars_row(canvas, state, row + 1, pending)
    dot_row(canvas, state, row + 2, pending)
  end

  defp ring_row(canvas, state, row, grid, ring, tier, pending) do
    lit_role =
      cond do
        ring.frac == nil -> :text_ghost
        ring.frac >= 1.0 -> :error
        ring.frac >= 0.9 -> :warning
        true -> :accent
      end

    lit = View.gauge_cells(ring.frac)
    on = Glyph.get(:gauge_on, tier)
    off = Glyph.get(:gauge_off, tier)

    gauge =
      if tier == :ascii do
        [
          {"[", :text_ghost},
          {String.duplicate(on, lit), lit_role},
          {String.duplicate(off, 10 - lit), :text_ghost},
          {"]", :text_ghost}
        ]
      else
        [{String.duplicate(on, lit), lit_role}, {String.duplicate(off, 10 - lit), :text_ghost}]
      end

    # The words end two cells before the scheduled task, which starts at its column.
    room = scheduled_col(grid) - 2 - (4 + 5 + 10 + 2)

    words =
      cond do
        pending -> [{"  …", :text_ghost}]
        ring.words -> [{"  " <> Canvas.clip(canvas, ring.words, room), :text_muted}]
        true -> []
      end

    {canvas, _} = Canvas.puts(canvas, row, 4, [{"ring ", :text_ghost}] ++ gauge ++ words)
    _ = state
    canvas
  end

  defp scheduled_row(canvas, state, row, grid, tier) do
    case View.scheduled(state) do
      nil ->
        canvas

      {name, project, minutes} ->
        col = scheduled_col(grid)
        mark = Glyph.get(:dot_off, tier)

        parts = [
          {mark, {:info, [:bold]}},
          {" " <> name, :text_muted},
          {" · " <> (project || "scheduled"), :text_faint},
          {" · " <> View.in_words(minutes), :text_faint}
        ]

        Canvas.puts(canvas, row, col, parts) |> elem(0)
    end
  end

  defp scheduled_col(grid), do: if(grid.class == :orbit_l, do: 52, else: 44)

  defp bars_row(canvas, _state, row, [{_, _}] = pending),
    do: Canvas.puts(canvas, row, 4, [{"bars ", :text_ghost}] ++ pending) |> elem(0)

  defp bars_row(canvas, state, row, nil) do
    live = View.live(state)

    parts =
      if live.count == 0 do
        [{"bars ", :text_ghost}, {"nothing running", :text_faint}]
      else
        kinds =
          live.kinds
          |> Enum.map(&[{" ", :text_primary}, {Atom.to_string(&1), Mark.kind_role(&1)}])
          |> List.flatten()
          |> Enum.drop(1)

        more = if live.overflow > 0, do: [{" +#{live.overflow}", :text_faint}], else: []

        [{"bars ", :text_ghost}, {"#{live.count} live", :text_primary}, {" · ", :text_ghost}] ++
          kinds ++ more
      end

    Canvas.puts(canvas, row, 4, parts) |> elem(0)
  end

  defp dot_row(canvas, _state, row, [{_, _}] = pending),
    do: Canvas.puts(canvas, row, 4, [{"dot  ", :text_ghost}] ++ pending) |> elem(0)

  defp dot_row(canvas, state, row, nil) do
    parts =
      case View.waiting(state) do
        0 ->
          [{"dot  ", :text_ghost}, {"nothing waits for you", :text_faint}]

        count ->
          [
            {"dot  ", :text_ghost},
            {"#{count} needs you", {:warning, [:bold]}},
            {" · ", :text_ghost},
            {key_label(state, :home_next_need, "Ctrl-N"), {:text_muted, [:bold]}},
            {" go", :text_faint}
          ]
      end

    Canvas.puts(canvas, row, 4, parts) |> elem(0)
  end

  # ---------------------------------------------------- the resume list zone

  defp resume(canvas, state, grid, tier) do
    cols = Map.fetch!(@columns, grid.class)
    list_end = cols.end || canvas.width - 3
    header = grid.header_row
    project = View.project_name(state)
    extra = max(draft_rows(state, canvas.width) - 1, 0)
    list = View.list(state, max(grid.list_rows - extra, 1))

    canvas = resume_header(canvas, state, header, project, list_end, tier)

    canvas =
      list.rows
      |> Enum.with_index()
      |> Enum.reduce(canvas, fn {entry, index}, acc ->
        list_row(acc, state, grid.list_first + index, entry, cols, list_end)
      end)

    canvas = if list.rows == [], do: empty_list(canvas, state, grid.list_first), else: canvas

    case {cols.preview, list.rows} do
      {nil, _} ->
        canvas

      {_, []} ->
        canvas

      {col, rows} ->
        preview(canvas, state, header, col, Enum.find(rows, & &1.selected?) || hd(rows))
    end
  end

  defp resume_header(canvas, state, row, project, list_end, _tier) do
    searching? = state.home.focus == :list or state.home.filter != ""

    left =
      if searching? do
        filter = state.home.filter

        [{"search ", :text_faint}] ++
          if(filter == "",
            do: [{"type to search every conversation", :text_ghost}],
            else: [{filter, :text_primary}]
          )
      else
        [{"resume in " <> project, :text_faint}]
      end

    {canvas, _} = Canvas.puts(canvas, row, 4, left)

    hint =
      [
        {digits_label(state), {:text_muted, [:bold]}},
        {" open", :text_faint},
        {"   ", :text_primary},
        {down_label(state), {:text_muted, [:bold]}},
        {" search all", :text_faint}
      ]

    Canvas.rputs(canvas, row, list_end, hint) |> elem(0)
  end

  defp list_row(canvas, state, row, entry, cols, list_end) do
    {bead, bead_role, bold?} = entry.bead
    bead_role = if bold?, do: {bead_role, [:bold]}, else: bead_role
    marker = Glyphs.for_caps(:focus_bar, state.capabilities)

    canvas =
      if entry.selected?,
        do: canvas |> Canvas.put(row, 2, marker, :accent) |> elem(0),
        else: canvas

    {canvas, _} = Canvas.put(canvas, row, 4, Integer.to_string(entry.n), {:text_muted, [:bold]})
    {canvas, _} = Canvas.put(canvas, row, 7, bead, bead_role)

    {canvas, _} =
      Canvas.put(
        canvas,
        row,
        9,
        Canvas.clip(canvas, entry.summary.title, cols.title),
        entry.title_role
      )

    canvas =
      case entry.words do
        nil ->
          canvas

        {text, role} ->
          Canvas.put(canvas, row, cols.words, Canvas.clip(canvas, text, 16), role) |> elem(0)
      end

    {canvas, _} = Canvas.put(canvas, row, cols.runs, entry.runs, :text_faint)
    {canvas, _} = Canvas.rputs(canvas, row, list_end, [{entry.age, :text_faint}])

    if entry.selected? do
      background = if state.home.focus == :list, do: :selection, else: :hover
      Canvas.paint(canvas, row, 3, list_end + 1, background)
    else
      canvas
    end
  end

  defp empty_list(canvas, state, row) do
    words =
      if state.home.filter != "",
        do: "No conversation matches \"" <> state.home.filter <> "\".",
        else: "No conversations yet."

    Canvas.put(canvas, row, 4, words, :text_faint) |> elem(0)
  end

  defp preview(canvas, state, header, col, entry) do
    data = View.preview(state, entry)
    width = min(canvas.width - 2 - col, 44)

    {canvas, _} =
      Canvas.put(
        canvas,
        header,
        col,
        Canvas.clip(canvas, data.title, width),
        {:text_primary, [:bold]}
      )

    {canvas, _} =
      Canvas.put(canvas, header + 1, col, Canvas.clip(canvas, data.facts, width), :text_faint)

    base = header + 3

    canvas =
      case data.last_prompt do
        nil ->
          canvas

        prompt ->
          {canvas, _} = Canvas.put(canvas, base, col, "last prompt", :text_ghost)

          state
          |> SwarmCodeCLI.UI.Projector.Settings.Text.wrap(prompt, min(width, 36))
          |> Enum.take(2)
          |> Enum.with_index(1)
          |> Enum.reduce(canvas, fn {line, j}, acc ->
            Canvas.put(acc, base + j, col, line, {:text_muted, [:italic]}) |> elem(0)
          end)
      end

    if data.waiting > 0 do
      bang = Glyph.get(:bang, Glyph.tier(state.capabilities))
      {canvas, _} = Canvas.put(canvas, header + 7, col, bang, {:warning, [:bold]})

      {canvas, _} =
        Canvas.put(canvas, header + 7, col + 2, View.waiting_words(data.waiting), :warning)

      Canvas.puts(
        canvas,
        header + 9,
        col,
        key_pairs([
          {key_label(state, :home_enter, "Enter"), "open"},
          {key_label(state, :home_next_need, "Ctrl-N"), "go to the approval"}
        ])
      )
      |> elem(0)
    else
      Canvas.puts(
        canvas,
        header + 9,
        col,
        key_pairs([{key_label(state, :home_enter, "Enter"), "open"}])
      )
      |> elem(0)
    end
  end

  # ----------------------------------------------------------- the composer

  defp composer(canvas, state, grid, tier) do
    focused? = state.home.focus == :composer
    width = canvas.width
    {lines, caret} = draft_lines(state, width)
    rows = length(lines)
    first = grid.composer_row - (rows - 1)
    prompt = Glyphs.for_caps(:crumb, state.capabilities)

    canvas =
      lines
      |> Enum.with_index()
      |> Enum.reduce(canvas, fn {line, index}, acc ->
        row = first + index

        acc =
          if index == 0 do
            acc
            |> Canvas.put(row, 1, prompt, if(focused?, do: {:accent, [:bold]}, else: :text_ghost))
            |> elem(0)
          else
            acc
          end

        text_role =
          if line.placeholder?,
            do: if(focused?, do: :text_faint, else: :text_ghost),
            else: :text_primary

        acc
        |> Canvas.put(row, 3, line.text, text_role)
        |> elem(0)
        |> Canvas.paint(row, 0, width, :card)
      end)

    hint_row = grid.hint_row
    canvas = Canvas.paint(canvas, hint_row, 0, width, :card)
    canvas = Canvas.puts(canvas, hint_row, 3, hint_parts(state)) |> elem(0)
    _ = tier

    cursor =
      if focused? and state.terminal_focus == :gained do
        {row, col} = caret
        %Cursor{x: 3 + col, y: first + row, shape: :bar, visible?: true}
      end

    cursor = cursor || list_cursor(state, grid)
    {canvas, cursor}
  end

  # The caret of the list's search field, on the header row.
  defp list_cursor(%{home: %Home{focus: :list} = home} = state, grid) do
    if state.terminal_focus == :gained do
      %Cursor{
        x:
          4 + String.length("search ") +
            Width.cells(home.filter, state.capabilities.ambiguous_width),
        y: grid.header_row,
        shape: :bar,
        visible?: true
      }
    end
  end

  defp list_cursor(_state, _grid), do: nil

  # How many rows the draft takes (1..3).
  defp draft_rows(state, width), do: state |> draft_lines(width) |> elem(0) |> length()

  # The visible lines of the Home draft (at most 3) and the caret as {row, col}.
  defp draft_lines(state, width) do
    policy = state.capabilities.ambiguous_width
    draft = Drafts.fetch(state.drafts, {state.source_epoch, :home})
    editor_width = max(width - 4, 1)
    slice = Editor.visible_slice(draft.editor, editor_width, 3, policy)

    if slice.text == "" do
      {[
         %{
           text: Canvas.clip(Canvas.new(state, width, 1), placeholder(state), editor_width),
           placeholder?: true
         }
       ], {0, 0}}
    else
      limits = %{Limits.composer_viewport() | ambiguous_width: policy}

      lines =
        slice.text
        |> Density.external(limits)
        |> SafeText.value()
        |> Width.wrap(editor_width, policy)

      before =
        slice.text
        |> String.graphemes()
        |> Enum.take(slice.cursor_offset)
        |> Enum.join()
        |> Density.external(limits)
        |> SafeText.value()

      prefix = Width.wrap(before, editor_width, policy)
      caret_row = max(length(prefix) - 1, 0)
      first = max(caret_row - 2, 0)
      shown = lines |> Enum.drop(first) |> Enum.take(3)
      col = min(editor_width - 1, Width.cells(List.last(prefix) || "", policy))
      {Enum.map(shown, &%{text: &1, placeholder?: false}), {min(caret_row - first, 2), col}}
    end
  end

  defp placeholder(_state), do: @placeholder

  defp hint_parts(state) do
    text = state |> home_draft_text() |> String.trim()
    enter = key_label(state, :home_enter, "Enter")
    escape = key_label(state, :home_escape, "Esc")
    project = View.project_name(state)

    cond do
      state.home.focus != :composer ->
        key_pairs([
          {escape, "back to the composer"},
          {key_label(state, :home_focus_next, "Tab"), "next"}
        ])

      (command = Keymap.local_command(text)) != nil ->
        key_pairs([{enter, "run /" <> Atom.to_string(command)}])

      true ->
        title =
          case Home.current_summary(state) do
            %{title: title} when title != "" -> title
            _ -> "the conversation"
          end

        back = if state.home.entered == :boot, do: "continue the latest: ", else: "back to: "

        key_pairs([
          {enter, "new conversation in " <> project},
          {escape, back <> Canvas.clip(Canvas.new(state, 200, 1), title, 40)}
        ])
    end
  end

  defp home_draft_text(state) do
    state.drafts
    |> Drafts.fetch({state.source_epoch, :home})
    |> Map.fetch!(:editor)
    |> Editor.text()
  end

  # ---------------------------------------------------------------- helpers

  defp key_pairs(pairs) do
    pairs
    |> Enum.map(fn {key, words} ->
      [{key, {:text_muted, [:bold]}}, {" " <> words, :text_faint}]
    end)
    |> Enum.intersperse([{"   ", :text_primary}])
    |> List.flatten()
  end

  # The first key of a Home binding in the current Home context, spelled for the
  # terminal; the default is the key's name when the binding is gone.
  defp key_label(state, id, default) do
    context = Keymap.Context.of(state)
    overrides = Keymap.overrides(state)

    with %{} = binding <- Bindings.fetch(id),
         key when key != nil <- Bindings.key_in_context(binding, context, overrides) do
      KeyLabel.label(key, state.capabilities.ascii?)
    else
      _ -> default
    end
  end

  defp digits_label(state) do
    Status.home_key_words(
      :digits,
      :home_composer,
      Keymap.overrides(state),
      state.capabilities.ascii?
    ) ||
      "Alt-1…9"
  end

  defp down_label(state) do
    case Bindings.fetch(:home_down) do
      %{} = binding ->
        case Bindings.key_in_context(binding, :home_composer, Keymap.overrides(state)) do
          nil -> "↓"
          key -> KeyLabel.label(key, state.capabilities.ascii?)
        end

      _ ->
        "↓"
    end
  end
end
