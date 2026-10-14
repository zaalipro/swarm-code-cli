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

  # How the list and the preview sit on each class: the column of the marker,
  # the digit, the bead and the title; where the state words and the run count
  # start; the right edge of the ages (`end`) and of the selected row's fill
  # (`fill`, exclusive); the preview column. The orbit classes follow the
  # designer's 120 x 36 and 160 x 44 frames, the small classes the 80 x 24 one.
  defp list_layout(%{class: :orbit_m}, _width),
    do: %{
      marker: 2,
      digit: 4,
      bead: 7,
      title_at: 9,
      title: 32,
      words: 42,
      runs: 60,
      end: 77,
      fill: 78,
      fill_from: 3,
      preview: 81,
      left: 4,
      search: "search all"
    }

  defp list_layout(%{class: :orbit_l}, _width),
    do: %{
      marker: 2,
      digit: 4,
      bead: 7,
      title_at: 9,
      title: 36,
      words: 48,
      runs: 70,
      end: 92,
      fill: 93,
      fill_from: 3,
      preview: 97,
      left: 4,
      search: "search all"
    }

  defp list_layout(%{class: :orbit_s}, width),
    do: %{
      marker: 2,
      digit: 4,
      bead: 7,
      title_at: 9,
      title: 32,
      words: 42,
      runs: 60,
      end: width - 3,
      fill: width - 2,
      fill_from: 3,
      preview: nil,
      left: 4,
      search: "search all"
    }

  # :compact and :minimal: no run counts, no preview; the state words sit at
  # column 41 (earlier on a narrow screen, so they never meet the age).
  defp list_layout(_grid, width) do
    words = min(41, width - 28)

    %{
      marker: 1,
      digit: 3,
      bead: 5,
      title_at: 7,
      title: words - 8,
      words: words,
      runs: nil,
      end: width - 1,
      fill: width - 1,
      fill_from: 2,
      preview: nil,
      left: 2,
      search: "search"
    }
  end

  @placeholder "Type to start a new conversation, or / for commands…"
  @small_placeholder "Type to start a new conversation…"

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

  defp draw(canvas, state, %{class: :compact} = grid, tier) do
    canvas
    |> title_row(state)
    |> summary_rows(state, tier, true)
    |> line_orbits(state, grid, tier)
    |> resume(state, grid, tier)
    |> composer(state, grid, tier)
  end

  defp draw(canvas, state, grid, tier) do
    canvas
    |> title_row(state)
    |> summary_rows(state, tier, false)
    |> resume(state, grid, tier)
    |> composer(state, grid, tier)
  end

  # ------------------------------------------- compact and minimal summary

  # Rows 2 and 3 of the two small classes: the inline glyph with the ring's
  # words, then the scheduled task and the branch.
  defp summary_rows(canvas, state, tier, gauge?) do
    opts = View.mark_opts(state)
    ring = View.ring(state)
    ready? = View.overview(state) != nil
    {canvas, _} = Canvas.puts(canvas, 2, 2, Mark.inline(tier, opts))

    words =
      if ready? do
        live = View.live(state)
        waiting = View.waiting(state)

        [
          ring.words && {ring.words, :text_muted},
          live.count > 0 && {"#{live.count} live", :text_primary},
          waiting > 0 && {"#{waiting} needs you", {:warning, [:bold]}}
        ]
        |> Enum.filter(& &1)
        |> Enum.intersperse({" · ", :text_ghost})
      else
        [{"…", :text_ghost}]
      end

    lead =
      cond do
        not gauge? -> []
        true -> gauge(ring.frac, tier) ++ [{" ", :text_primary}]
      end

    {canvas, _} = Canvas.puts(canvas, 2, 14, lead ++ words)

    scheduled =
      case View.scheduled(state) do
        nil ->
          []

        {name, project, minutes} ->
          [
            {Glyph.get(:dot_off, tier), {:info, [:bold]}},
            {" " <> name, :text_muted}
          ] ++
            if(project, do: [{" · " <> project, :text_faint}], else: []) ++
            [{" " <> View.in_words(minutes), :text_muted}]
      end

    branch =
      case View.branch(state) do
        nil ->
          []

        {name, dirty} ->
          mark = if canvas.ascii?, do: "br: ", else: "⎇ "
          [{mark <> name <> if(dirty && dirty > 0, do: " +#{dirty}", else: ""), :text_muted}]
      end

    Canvas.puts(canvas, 3, 14, join_parts(scheduled, branch)) |> elem(0)
  end

  defp join_parts([], branch), do: branch
  defp join_parts(scheduled, []), do: scheduled
  defp join_parts(scheduled, branch), do: scheduled ++ [{" · ", :text_ghost}] ++ branch

  # --------------------------------------------------------- line orbits

  # Each project's orbit unrolled: its name, a rule with the beads along it by
  # age on the log scale, and the count at the right edge; the age ticks below.
  defp line_orbits(canvas, _state, %{orbit_slots: 0}, _tier), do: canvas

  defp line_orbits(canvas, state, grid, tier) do
    {t0, t1} = Grid.line_range(canvas.width)
    projects = state |> View.projects() |> Enum.take(grid.orbit_slots)
    ghost_rule = if canvas.ascii?, do: "-", else: "─"
    rule = String.duplicate(ghost_rule, t1 - t0 + 1)

    shown =
      case projects do
        [] ->
          [%{name: View.project_name(state), current: true, conversations: [], count: nil}]

        _ ->
          Enum.map(
            projects,
            &%{
              name: &1.name,
              current: &1.current,
              conversations: &1.conversations,
              count: &1.conversation_count
            }
          )
      end

    canvas =
      shown
      |> Enum.take(grid.orbit_slots)
      |> Enum.with_index()
      |> Enum.reduce(canvas, fn {project, k}, acc ->
        row = grid.r_top + k
        name_role = if project.current, do: {:text_primary, [:bold]}, else: :text_muted
        {acc, _} = Canvas.put(acc, row, 2, Canvas.clip(acc, project.name, t0 - 3), name_role)

        {acc, _} =
          Canvas.put(acc, row, t0, rule, if(project.current, do: :text_faint, else: :text_ghost))

        acc =
          Enum.reduce(project.conversations, acc, fn conversation, acc2 ->
            {text, role, bold?} = Orbits.bead(conversation, state.now, tier)
            x = Orbits.line_x(t0, t1, Orbits.age_minutes(conversation, state.now))
            Canvas.put(acc2, row, x, text, if(bold?, do: {role, [:bold]}, else: role)) |> elem(0)
          end)

        case project.count do
          nil ->
            acc

          count ->
            Canvas.rputs(acc, row, acc.width - 1, [{Integer.to_string(count), :text_faint}])
            |> elem(0)
        end
      end)

    tick_row = grid.r_bot + 1

    Enum.reduce(Orbits.line_ticks(t0, t1), canvas, fn {col, label}, acc ->
      Canvas.put(acc, tick_row, col, label, :text_ghost) |> elem(0)
    end)
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
    # The words end two cells before the scheduled task, which starts at its column.
    room = scheduled_col(grid) - 2 - (4 + 5 + 10 + 2)

    words =
      cond do
        pending -> [{"  …", :text_ghost}]
        ring.words -> [{"  " <> Canvas.clip(canvas, ring.words, room), :text_muted}]
        true -> []
      end

    _ = state

    {canvas, _} =
      Canvas.puts(canvas, row, 4, [{"ring ", :text_ghost}] ++ gauge(ring.frac, tier) ++ words)

    canvas
  end

  # The ten-cell gauge of a fraction: lit cells in the ring's role, the rest ghost.
  defp gauge(frac, tier) do
    lit_role =
      cond do
        frac == nil -> :text_ghost
        frac >= 1.0 -> :error
        frac >= 0.9 -> :warning
        true -> :accent
      end

    lit = View.gauge_cells(frac)
    on = Glyph.get(:gauge_on, tier)
    off = Glyph.get(:gauge_off, tier)

    cells = [
      {String.duplicate(on, lit), lit_role},
      {String.duplicate(off, 10 - lit), :text_ghost}
    ]

    if tier == :ascii, do: [{"[", :text_ghost}] ++ cells ++ [{"]", :text_ghost}], else: cells
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
    cols = list_layout(grid, canvas.width)
    header = grid.header_row
    extra = max(draft_rows(state, canvas.width) - 1, 0)
    rows = max(grid.list_rows - extra, 1)
    list = View.list(state, rows)

    canvas = resume_header(canvas, state, grid, cols)

    canvas =
      list.rows
      |> Enum.with_index()
      |> Enum.reduce(canvas, fn {entry, index}, acc ->
        list_row(acc, state, grid.list_first + index, entry, cols)
      end)

    canvas =
      if list.rows == [],
        do: empty_list(canvas, state, grid.list_first, cols.left),
        else: canvas

    canvas =
      case {cols.preview, list.rows} do
        {nil, _} ->
          canvas

        {_, []} ->
          canvas

        {col, listed} ->
          preview(canvas, state, header, col, Enum.find(listed, & &1.selected?) || hd(listed))
      end

    if grid.wide_extras?, do: before_you_start(canvas, state, grid, rows, tier), else: canvas
  end

  # The wide class's last block: the provider windows, the branch, what is
  # uncommitted. MCP status is not on the shell snapshot, so it is not shown.
  defp before_you_start(canvas, state, grid, list_rows, tier) do
    row = grid.list_first + list_rows + 1
    segments = start_segments(canvas, state, tier)

    if segments == [] or row + 1 >= composer_top(state, grid, canvas.width) do
      canvas
    else
      {canvas, _} = Canvas.put(canvas, row, 4, "before you start something big", :text_faint)

      {canvas, _} =
        Enum.reduce(segments, {canvas, 4}, fn parts, {acc, col} ->
          cells = Canvas.parts_cells(acc, parts)
          gap = if col == 4, do: 0, else: 5

          if col + gap + cells <= acc.width - 2 do
            Canvas.puts(acc, row + 1, col + gap, parts)
          else
            {acc, col}
          end
        end)

      canvas
    end
  end

  defp start_segments(canvas, state, tier) do
    limits =
      for limit <- View.limits(state, 3) do
        percent = round(limit.used_percent)
        lit = percent |> div(10) |> min(10) |> max(0)

        [{limit.provider, :text_muted}] ++
          if(limit.scope in [nil, ""], do: [], else: [{" " <> limit.scope, :text_faint}]) ++
          [
            {" ", :text_primary},
            {String.duplicate(Glyph.get(:gauge_on, tier), lit), :text_muted},
            {String.duplicate(Glyph.get(:gauge_off, tier), 10 - lit), :text_ghost},
            {" #{percent}%", :text_faint}
          ]
      end

    branch =
      case View.branch(state) do
        nil ->
          []

        {name, dirty} ->
          mark = if canvas.ascii?, do: "br:", else: "⎇"

          words =
            case dirty do
              nil -> ""
              0 -> " · clean"
              1 -> " · 1 file uncommitted"
              n -> " · #{n} files uncommitted"
            end

          [[{mark, :text_muted}, {" " <> name <> words, :text_muted}]]
      end

    limits ++ branch
  end

  # The first row the composer occupies (it grows upwards with the draft).
  defp composer_top(state, grid, width),
    do: grid.composer_row - (draft_rows(state, width) - 1)

  defp resume_header(canvas, state, grid, cols) do
    row = grid.header_row
    searching? = state.home.focus == :list or state.home.filter != ""

    left =
      cond do
        searching? ->
          filter = state.home.filter

          [{"search ", :text_faint}] ++
            if(filter == "",
              do: [{"type to search every conversation", :text_ghost}],
              else: [{filter, :text_primary}]
            )

        grid.class in [:compact, :minimal] ->
          [{"resume", :text_faint}]

        true ->
          [{"resume in " <> View.project_name(state), :text_faint}]
      end

    {canvas, _} = Canvas.puts(canvas, row, cols.left, left)

    hint = [
      {digits_label(state), {:text_muted, [:bold]}},
      {" open", :text_faint},
      {"   ", :text_primary},
      {down_label(state), {:text_muted, [:bold]}},
      {" " <> cols.search, :text_faint}
    ]

    Canvas.rputs(canvas, row, cols.end, hint) |> elem(0)
  end

  defp list_row(canvas, state, row, entry, cols) do
    {bead, bead_role, bold?} = entry.bead
    bead_role = if bold?, do: {bead_role, [:bold]}, else: bead_role
    marker = Glyphs.for_caps(:focus_bar, state.capabilities)

    canvas =
      if entry.selected?,
        do: canvas |> Canvas.put(row, cols.marker, marker, :accent) |> elem(0),
        else: canvas

    {canvas, _} =
      Canvas.put(canvas, row, cols.digit, Integer.to_string(entry.n), {:text_muted, [:bold]})

    {canvas, _} = Canvas.put(canvas, row, cols.bead, bead, bead_role)

    {canvas, _} =
      Canvas.put(
        canvas,
        row,
        cols.title_at,
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

    canvas =
      if cols.runs,
        do: canvas |> Canvas.put(row, cols.runs, entry.runs, :text_faint) |> elem(0),
        else: canvas

    {canvas, _} = Canvas.rputs(canvas, row, cols.end, [{entry.age, :text_faint}])

    if entry.selected? do
      background = if state.home.focus == :list, do: :selection, else: :hover
      Canvas.paint(canvas, row, cols.fill_from, cols.fill, background)
    else
      canvas
    end
  end

  defp empty_list(canvas, state, row, col) do
    words =
      if state.home.filter != "",
        do: "No conversation matches \"" <> state.home.filter <> "\".",
        else: "No conversations yet."

    Canvas.put(canvas, row, col, words, :text_faint) |> elem(0)
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

  defp placeholder(state), do: if(small?(state), do: @small_placeholder, else: @placeholder)

  # The two classes with no preview and no room for sentences in the hint row.
  defp small?(state) do
    %{columns: columns, rows: rows} = state.size
    tier = Glyph.tier(state.capabilities)
    Grid.class(columns, rows, tier) in [:compact, :minimal]
  end

  defp map_drawn?(state) do
    %{columns: columns, rows: rows} = state.size
    tier = Glyph.tier(state.capabilities)
    Grid.class(columns, rows, tier) != :minimal
  end

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

        if small?(state) do
          key_pairs(
            [
              {enter, "new"},
              {escape, if(state.home.entered == :boot, do: "latest", else: "back")}
            ] ++
              if(map_drawn?(state),
                do: [{key_label(state, :home_focus_next, "Tab"), "map"}],
                else: []
              )
          )
        else
          key_pairs([
            {enter, "new conversation in " <> project},
            {escape, back <> Canvas.clip(Canvas.new(state, 200, 1), title, 40)}
          ])
        end
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
