defmodule SwarmCodeCLI.UI.Projector.Settings.Chrome do
  @moduledoc """
  The settings layer's chrome (pass 75, E): the crumb on row 0, the search
  well with the page's counts on row 1, and under 120 columns the section
  strip on row 2. Every function takes the projector state (it reads
  `state.settings`, the capabilities and the read model), the frame's
  `Settings.Grid` and `glyphs`, the frame's `&Glyphs.for_caps(&1, caps)`, and
  answers one screen line of segments exactly `grid.columns` cells wide.
  """

  alias SwarmCodeCLI.UI.Projector.Settings.Text

  alias SwarmCodeCLI.UI.Settings.{
    Editors,
    Glyphs,
    Grid,
    Layer,
    ModelPicker,
    Nav,
    Page,
    Row,
    Rows,
    Sections
  }

  alias SwarmCodeCLI.UI.Settings.Sections.Overview

  @type segments :: [Text.segment()]
  @type glyphs :: (atom() -> String.t())

  # ------------------------------------------------------------ crumb

  @doc "Row 0: `Settings › Section › record` left, the needs-you chip and `Esc …` right."
  @spec crumb(map(), Grid.t(), glyphs()) :: segments()
  def crumb(state, %Grid{} = grid, glyphs) do
    layer = state.settings
    page = Layer.page(layer)
    joint = {" " <> glyphs.(:crumb) <> " ", :text_faint}

    trail =
      case Page.level(page) do
        :section -> [Sections.title(page.section)]
        :record -> [Sections.title(page.section), record_name(state, page)]
        :sub -> [Sections.title(page.section), sub_title(state, page)]
      end

    left =
      [margin(grid), {"Settings", :text_muted}] ++
        Enum.flat_map(trail, &[joint, {&1, {:text_primary, [:bold]}}])

    words =
      cond do
        Layer.depth(layer) > 1 or layer.detail_open -> " back"
        grid.class == :small and layer.region != :rail -> " sections"
        true -> " back to chat"
      end

    right = needs_you(state) ++ [{"Esc", :key}, {words, :text_faint}, margin(grid)]
    Text.spread(state, left, right, grid.columns)
  end

  # A draft is not a record yet: the crumb says `new`, not the draft's id.
  defp record_name(_state, %Page{record: {_kind, "draft"}}), do: "new"

  # QA #2 P2-5: a search engine's record has no name field; its label names it
  # (`Search & web › Exa`, not `› exa`).
  defp record_name(_state, %Page{record: {"search_provider", id}}),
    do: SwarmCodeCLI.UI.Settings.Sections.SearchWeb.label(id)

  defp record_name(state, %Page{record: {kind, id}}) do
    case Map.get(state.settings.data.record, {kind, id}) do
      %{fields: fields} when is_map(fields) ->
        name = Map.get(fields, "name") || Map.get(fields, :name)
        if is_binary(name) and name != "", do: name, else: to_string(id)

      _ ->
        to_string(id)
    end
  end

  # cli74 F18: a sub-page without a name of its own (a provider's delete
  # page) is named by its section's title (the provider), not "…".
  defp sub_title(state, page) do
    section = Sections.title(page.section)

    case sub_name(page) do
      "…" ->
        title = Sections.page_title(page.section, Nav.ctx(state))

        cond do
          not is_binary(title) or title in ["", section] ->
            "…"

          String.starts_with?(title, section <> " › ") ->
            String.replace_prefix(title, section <> " › ", "")

          true ->
            title
        end

      name ->
        name
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

  # ------------------------------------------------------------- well

  @doc """
  Row 1: the search well (a `hover` fill of `grid.well_width` cells) with the
  placeholder, the query, the page filter or the command line, and on the
  right the page's counts or the search's result count.
  """
  @spec well(map(), Grid.t(), glyphs()) :: segments()
  def well(state, %Grid{} = grid, glyphs) do
    layer = state.settings
    {inside, right} = well_parts(state, layer, grid, glyphs)
    field = fill(state, inside, grid.well_width, :hover)
    Text.spread(state, [margin(grid) | field], right ++ [margin(grid)], grid.columns)
  end

  defp well_parts(
         _state,
         %Layer{mode: :command_line, command_line: %{text: text} = line},
         _grid,
         glyphs
       ) do
    right =
      if line.error,
        do: [{glyphs.(:fail) <> " " <> line.error, :error}],
        else: [{"Enter runs · Esc leaves", :text_faint}]

    {typed(":", text, glyphs, true), right}
  end

  defp well_parts(state, %Layer{mode: :search, search: nil, filter: %{} = filter}, _grid, glyphs) do
    shown = state |> Nav.rows() |> Enum.count(&Row.focusable?/1)
    matches = if shown == 1, do: "match", else: "matches"

    {typed("/", filter.query, glyphs, true),
     [{"filter #{filter.total} rows · #{shown} #{matches}", :text_faint}]}
  end

  defp well_parts(_state, %Layer{mode: :search, search: %{query: query} = search}, _grid, glyphs),
    do: {typed("/", query, glyphs, true), found(search)}

  defp well_parts(_state, %Layer{search: %{query: query} = search}, _grid, glyphs)
       when query != "",
       do: {typed("/", query, glyphs, false), found(search)}

  defp well_parts(state, _layer, grid, _glyphs) do
    words =
      if grid.class in [:strip, :small],
        do: "search #{scalar_count()} settings",
        else: "search #{scalar_count()} settings, providers, servers and keys"

    {[{"  ", :text_primary}, {"/", :key}, {"  ", :text_primary}, {words, :text_faint}],
     counts(state, grid)}
  end

  defp typed(prefix, text, glyphs, caret?) do
    [{"  ", :text_primary}, {prefix, :key}, {"  ", :text_primary}, {text, :text_primary}] ++
      if(caret?, do: [{glyphs.(:caret), :accent}], else: [])
  end

  # §4.1.7 (QA F-13): `7 of 212 · 3 sections`.
  defp found(search) do
    case Map.get(search, :found) do
      %{results: results} ->
        sections = results |> Enum.map(&elem(&1, 1).section) |> Enum.uniq() |> length()

        [
          {"#{length(results)}", :text_primary},
          {" of #{scalar_count()}", :text_muted},
          {" · ", :text_faint},
          {"#{sections}", :text_primary},
          {if(sections == 1, do: " section", else: " sections"), :text_muted}
        ]

      _ ->
        [{"Esc leaves", :text_faint}]
    end
  end

  @doc """
  The idle well's right side: values changed from their default, the
  attention chip and values the environment sets, each only when non-zero
  (`• 14   ! 3   2 env` under 120 columns).
  """
  @spec counts(map(), Grid.t()) :: segments()
  def counts(state, %Grid{} = grid) do
    summary = Overview.summary(Nav.ctx(state))
    short? = grid.class in [:strip, :small]
    changed = Glyphs.for_caps(:changed, state.capabilities)
    twin? = Glyphs.twin?(state.capabilities)

    chip = fn words ->
      if twin?, do: {"[" <> words <> "]", :text_primary}, else: {" " <> words <> " ", :chip_warn}
    end

    [
      if(summary.changed > 0,
        do: [
          {changed <> " ", :text_faint},
          {"#{summary.changed}", :text_primary}
          | if(short?, do: [], else: [{" changed from default", :text_muted}])
        ]
      ),
      if(summary.attention > 0,
        do: [
          chip.(
            if(short?,
              do: "! #{summary.attention}",
              else: "! #{summary.attention} need attention"
            )
          )
        ]
      ),
      if(summary.env > 0,
        do: [
          {"#{summary.env}", :text_primary},
          {if(short?, do: " env", else: " from env"), :text_muted}
        ]
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.intersperse([{"   ", :text_primary}])
    |> Enum.concat()
  end

  # ------------------------------------------------------------ strip

  @doc """
  Row 2 under 120 columns: `‹ Overview  [Models & effort •15]  Providers 1 … ›`
  with the current section as a `hover` pill and `N of 22` on the right; the
  window keeps the current section in view.
  """
  @spec strip(map(), Grid.t(), glyphs()) :: segments()
  def strip(state, %Grid{} = grid, glyphs) do
    layer = state.settings
    ids = Sections.ids()
    current = Layer.section(layer)
    index = Enum.find_index(ids, &(&1 == current)) || 0
    marks = rail_marks(state, glyphs)
    right = [{"#{index + 1}", :text_primary}, {" of #{length(ids)}", :text_faint}]
    room = grid.columns - 2 * grid.margin - Text.cells(state, right) - 8

    names =
      ids
      |> strip_window(index, room, &strip_cost(state, &1, marks))
      |> Enum.map(fn id ->
        mark = Map.get(marks, id, [])
        title = Sections.title(id)

        if id == current do
          mark = if mark == [], do: [], else: [{" ", :text_primary} | mark]

          on_hover(
            [{" ", :text_primary}, {title, {:text_primary, [:bold]}}] ++
              mark ++ [{" ", :text_primary}]
          )
        else
          mark = if mark == [], do: [], else: [{" ", :text_primary} | mark]
          [{title, :text_muted} | mark]
        end
      end)
      |> Enum.intersperse([{"   ", :text_primary}])
      |> Enum.concat()

    left =
      [margin(grid), {glyphs.(:step_left), :text_faint}, {"  ", :text_primary}] ++
        names ++ [{"  ", :text_primary}, {glyphs.(:step_right), :text_faint}]

    Text.spread(state, left, right ++ [margin(grid)], grid.columns)
  end

  defp strip_cost(state, id, marks) do
    Text.text_cells(state, Sections.title(id)) + Text.cells(state, Map.get(marks, id, [])) + 5
  end

  # The window of sections that fits `room`, around the current one.
  defp strip_window(ids, index, room, cost),
    do: grow(ids, index, index, cost.(Enum.at(ids, index)), room, cost)

  # Widens [lo, hi] a section at a time (right, then left) while it fits.
  defp grow(ids, lo, hi, used, room, cost) do
    {lo2, hi2, used2} =
      Enum.reduce([hi + 1, lo - 1], {lo, hi, used}, fn at, {l, h, u} = acc ->
        id = if at >= 0, do: Enum.at(ids, at)

        cond do
          id == nil or u + cost.(id) > room -> acc
          at > h -> {l, at, u + cost.(id)}
          true -> {at, h, u + cost.(id)}
        end
      end)

    if {lo2, hi2} == {lo, hi},
      do: Enum.slice(ids, lo..hi//1),
      else: grow(ids, lo2, hi2, used2, room, cost)
  end

  # ---------------------------------------------------- message row

  @doc """
  The message row: the toast for its 4 s, else the consequence of the open
  enum editor's candidate, else the Overview's tip; on the right, where a
  change of the focused row is written.
  """
  @spec message(map(), Grid.t(), glyphs(), Row.t() | nil | :auto) :: segments()
  def message(state, %Grid{} = grid, glyphs, current \\ :auto) do
    layer = state.settings
    current = current(state, current)

    left =
      toast(state, layer, glyphs) || consequence(state, layer, current, glyphs) ||
        tip(layer)

    right =
      case writes_to(state, current) do
        nil -> []
        words -> [{"writes to ", :text_faint}, {words, :text_muted}]
      end

    Text.spread(state, [margin(grid) | left], right ++ [margin(grid)], grid.columns)
  end

  defp toast(state, layer, glyphs) do
    case layer.status do
      %{text: text, role: role, at: at} = status ->
        if state.now - at < Map.get(status, :ms, 4_000) do
          glyph =
            case role do
              :success -> [{glyphs.(:ok) <> " ", :success}]
              :error -> [{glyphs.(:fail) <> " ", :error}]
              :warning -> [{"! ", :warning}]
              _ -> []
            end

          glyph ++ [{text, :text_primary}]
        end

      _ ->
        nil
    end
  end

  # `Approvals Read-only → Auto for swarm-code once you press Enter`.
  defp consequence(
         state,
         %Layer{mode: :editing, editing: %{module: Editors.Enum, state: editor}},
         %Row{key: key} = row,
         glyphs
       )
       when is_binary(key) do
    with %{choices: choices, index: index, original: original} <- editor,
         %{value: value, label: label} <- Enum.at(choices, index),
         true <- value != original,
         words when is_binary(words) <- writes_to(state, row) do
      saved = Enum.find_value(choices, to_string(original), &(&1.value == original && &1.label))

      [
        {row.label, :text_primary},
        {" ", :text_primary},
        {to_string(saved), :text_primary},
        {" " <> glyphs.(:link) <> " ", :text_faint},
        {to_string(label), :text_primary},
        {" for " <> words <> " once you press Enter", :text_muted}
      ]
    else
      _ -> nil
    end
  end

  defp consequence(_state, _layer, _current, _glyphs), do: nil

  # The Overview's quiet line when nothing was said.
  defp tip(layer) do
    if Layer.section(layer) == :overview and Layer.depth(layer) == 1,
      do: [
        {"/settings <words> opens straight at a setting · : runs a settings command such as :set theme light",
         :text_muted}
      ],
      else: []
  end

  # §4.1.5 (QA F-13): where a change of the focused row is written.
  defp writes_to(state, %{key: key} = current) when is_binary(key) do
    case SwarmCode.Settings.Registry.fetch(key) do
      {:ok, entry} ->
        words =
          case entry.home do
            :cli -> "cli.json · this machine's terminal"
            home -> Rows.scope_words(Nav.ctx(state), %{entry | scope: home})
          end

        if SwarmCode.Settings.Entry.writable?(entry) and is_binary(words), do: words

      :error ->
        record_writes_to(current)
    end
  end

  defp writes_to(_state, _current), do: nil

  # A record's field (a provider's API key) has no registry entry; the
  # record lives in the shared database (F3, 407).
  defp record_writes_to(%{kind: :field, layer: :global}),
    do: "global · shared with the desktop app"

  defp record_writes_to(_current), do: nil

  # ---------------------------------------------------- status line

  @doc """
  The status line on a `surface` fill: the mode word, the keys of the focused
  row or the open editor, and the legend (project and conversation) right.
  """
  @spec status(map(), Grid.t(), glyphs(), Row.t() | nil | :auto) :: segments()
  def status(state, %Grid{} = grid, _glyphs, current \\ :auto) do
    layer = state.settings
    current = current(state, current)

    chunks =
      (keys(state, layer, current) ++ [{"?", "keys"}])
      |> Enum.map(fn {key, words} -> [{key, :key}, {" " <> words, :text_faint}] end)

    base = [margin(grid), mode_word(layer), {"   ", :text_primary}]
    legend = legend(state, grid)
    right = legend ++ [margin(grid)]
    all = base ++ join_keys(chunks)

    # the keys that fit are drawn whole, never cut; the legend only beside all of them
    line =
      if legend != [] and Text.cells(state, all) + 3 + Text.cells(state, right) <= grid.columns do
        Text.spread(state, all, right, grid.columns)
      else
        room = grid.columns - Text.cells(state, base) - grid.margin

        kept =
          chunks
          |> Enum.reduce_while({[], 0}, fn chunk, {acc, used} ->
            size = Text.cells(state, chunk) + if(acc == [], do: 0, else: 3)

            if used + size <= room,
              do: {:cont, {acc ++ [chunk], used + size}},
              else: {:halt, {acc, used}}
          end)
          |> elem(0)

        Text.fit(state, base ++ join_keys(kept), grid.columns)
      end

    on(line, :surface)
  end

  defp join_keys(chunks),
    do: chunks |> Enum.intersperse([{"   ", :text_primary}]) |> Enum.concat()

  @doc "The mode word the status line opens with (decision D11)."
  @spec mode_word(Layer.t()) :: {String.t(), Text.segment() | term()}
  def mode_word(%Layer{mode: :capture}), do: {"KEY", {:accent, [:bold]}}
  def mode_word(%Layer{mode: :command_line}), do: {"COMMAND", {:info, [:bold]}}
  def mode_word(%Layer{mode: :search}), do: {"SEARCH", {:info, [:bold]}}
  def mode_word(%Layer{mode: :paste}), do: {"SECRET", {:warning, [:bold]}}

  def mode_word(%Layer{mode: :editing} = layer) do
    cond do
      secret?(layer.editing) -> {"SECRET", {:warning, [:bold]}}
      picker?(layer) -> {"PICK", {:accent, [:bold]}}
      true -> {"EDIT", {:accent, [:bold]}}
    end
  end

  def mode_word(%Layer{}), do: {"BROWSE", {:text_primary, [:bold]}}

  defp picker?(%Layer{popover: {:picker, _}}), do: true
  defp picker?(%Layer{editing: %{module: ModelPicker}}), do: true
  defp picker?(_layer), do: false

  defp secret?(%{state: %{opts: %{secret: true}}}), do: true
  defp secret?(_editing), do: false

  # The keys per mode, as the pass-74 footer listed them.
  defp keys(state, layer, current) do
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

  @doc """
  The status line's legend: the project (`agent_lane_2`) and the
  conversation's title (`agent_lane_1`), the two hues the page's spines use
  most; shorter under 120 columns, the title alone under 90.
  """
  @spec legend(map(), Grid.t()) :: segments()
  def legend(state, %Grid{} = grid) do
    ctx = Nav.ctx(state)

    name =
      case ctx.project do
        %{"name" => name} when is_binary(name) and name != "" -> name
        _ -> nil
      end

    title = session_title(ctx)

    parts =
      case grid.class do
        class when class in [:wide, :rail] ->
          [
            name && [{"project ", :text_faint}, {name, :agent_lane_2}],
            title && [{"conversation ", :text_faint}, {title, :agent_lane_1}]
          ]

        :strip ->
          [name && [{name, :agent_lane_2}], title && [{title, :agent_lane_1}]]

        _small ->
          [title && [{title, :agent_lane_1}]]
      end

    parts
    |> Enum.reject(&is_nil/1)
    |> Enum.intersperse([{" · ", :text_faint}])
    |> Enum.concat()
  end

  defp session_title(ctx) do
    with {:ok, entry} <- SwarmCode.Settings.Registry.fetch("session.title"),
         title when is_binary(title) and title != "" <-
           Rows.shown(ctx, entry, Rows.setting(ctx, entry)) do
      title
    else
      _ -> nil
    end
  end

  defp current(state, :auto), do: Nav.current(state, Nav.rows(state))
  defp current(_state, current), do: current

  # ------------------------------------------------------- rail marks

  @counted [:providers, :mcp, :library]

  @doc """
  Per section, the mark the rail and the strip draw: `!N` attention items
  (the overview's, `warning`), else `•N` values changed from their default
  (terminal keys and the loaded daemon ones; `•` faint, the count muted),
  else the record count of Providers, MCP servers and Library (faint).
  """
  @spec rail_marks(map(), glyphs()) :: %{atom() => segments()}
  def rail_marks(state, glyphs) do
    layer = state.settings
    changed = glyphs.(:changed)

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
    ctx = Nav.ctx(state)

    Sections.ids()
    |> Enum.flat_map(fn id ->
      records =
        if id in @counted,
          do: Map.get(Sections.counts(id, ctx), :records) || glance_count(layer.data.overview, id)

      cond do
        Map.get(attention, id, 0) > 0 ->
          [{id, [{"!#{attention[id]}", :warning}]}]

        Map.get(changed_counts, id, 0) > 0 ->
          [{id, [{changed, :text_faint}, {"#{changed_counts[id]}", :text_muted}]}]

        # §4.1.1 (QA F-13): a plain number is the section's record count,
        # once its records are loaded.
        is_integer(records) ->
          [{id, [{"#{records}", :text_faint}]}]

        true ->
          []
      end
    end)
    |> Map.new()
  end

  # QA #2 P2-11: before a section's records are loaded its count comes from
  # the Overview's glance (`providers 4`), so the rail shows it from the start.
  defp glance_count(%{glance: %{} = glance}, :providers),
    do: glance_int(glance, "providers", "count")

  defp glance_count(%{glance: %{} = glance}, :mcp), do: glance_int(glance, "mcp", "servers")
  defp glance_count(_overview, _id), do: nil

  defp glance_int(glance, name, key) do
    case Map.get(glance, name) do
      %{} = fragment -> if is_integer(fragment[key]), do: fragment[key]
      _ -> nil
    end
  end

  # ---------------------------------------------------------- helpers

  # §4.1.2: the placeholder and the result count name the scalar settings.
  defp scalar_count, do: length(SwarmCode.Settings.Registry.scalar_keys())

  defp margin(%Grid{margin: margin}), do: {String.duplicate(" ", margin), :text_primary}

  @doc false
  # `segments` padded to `width` cells, every segment on the `bg` fill.
  def fill(state, segments, width, bg), do: state |> Text.fit(segments, width) |> on(bg)

  defp on_hover(segments), do: on(segments, :hover)

  defp on(segments, bg) do
    Enum.map(segments, fn
      {text, {_, :on, _}} = segment when is_binary(text) -> segment
      {text, role} -> {text, {role, :on, bg}}
    end)
  end
end
