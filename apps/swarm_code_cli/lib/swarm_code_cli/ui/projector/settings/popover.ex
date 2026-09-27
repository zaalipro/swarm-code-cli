defmodule SwarmCodeCLI.UI.Projector.Settings.Popover do
  @moduledoc """
  The lines of the settings layer's popovers (spec §4.8, §4.12, T§12): the
  keys sheet grouped *move · change · this row · search and commands ·
  leave* with the effective keys (overrides applied, `unbound` when a
  binding has none), a confirmation with its buttons (the focused one on
  the selection, the destructive one `error`, disabled until a typed word
  matches or the counts arrive), a picker with its filter, its window of
  options around the cursor and `N of M · Enter chooses · Esc closes`, and
  the pending-on-leave question.
  """

  alias SwarmCodeCLI.UI.Keymap
  alias SwarmCodeCLI.UI.Keymap.{Bindings, KeyName, SettingsBindings}
  alias SwarmCodeCLI.UI.Projector.Settings.Text
  alias SwarmCodeCLI.UI.Reducer.Settings.Popover
  alias SwarmCodeCLI.UI.Settings, as: SettingsContext
  alias SwarmCodeCLI.UI.Settings.{Confirm, Glyphs, Nav, Picker}

  # QA F-5: every settings binding has a group (the sheet listed the seven
  # keys the help popover itself answers).
  @groups [
    {"move",
     [
       :up,
       :down,
       :page_up,
       :page_down,
       :first,
       :last,
       :left,
       :right,
       :prev_section,
       :next_section,
       :next_region,
       :goto,
       :jump
     ]},
    {"change",
     [
       :enter,
       :toggle,
       :big_left,
       :big_right,
       :reset,
       :undo,
       :redo,
       :save,
       :external,
       :commit,
       :add,
       :add_key,
       :delete,
       :delete_record,
       :remove_all,
       :move_up,
       :move_down,
       :test,
       :fetch,
       :restart,
       :all_on,
       :all_off,
       :alt,
       :cancel_task,
       :new,
       :clear,
       :edit_external,
       :open_related,
       :copy
     ]},
    {"while typing",
     [
       :line_start,
       :line_end,
       :delete_word,
       :clear_line,
       :backspace,
       :delete_forward,
       :complete,
       :paste_commit,
       :paste_clear,
       :paste_type,
       :next_button,
       :previous_button
     ]},
    {"search and commands", [:search, :command, :refresh, :needs_you, :info]},
    {"leave", [:escape, :interrupt, :help]}
  ]

  @picker_rows 12

  @doc """
  A popover's rounded frame (pass 75, E) `width` cells wide around `lines`:
  `╭─ title ───… right ─╮`, `│ line │`, `╰─ bottom ───…─╯`; the frame is
  `text_faint`, and every cell sits on the `popover` fill. An empty title,
  right or bottom leaves the rule unbroken there.
  """
  @spec frame(
          map(),
          [[Text.segment()]],
          [Text.segment()],
          [Text.segment()],
          [Text.segment()],
          pos_integer()
        ) ::
          [[Text.segment()]]
  def frame(state, lines, title, right, bottom, width) do
    # the twin (NO_COLOR or ASCII) draws the box from `+ - |`
    g =
      if Glyphs.twin?(state.capabilities),
        do: &Glyphs.get(&1, :ascii),
        else: &Glyphs.for_caps(&1, state.capabilities)

    h = g.(:rule_h)
    v = g.(:rule_v)

    {bottom, bottom_right} =
      case bottom do
        {left, right} -> {left, right}
        left -> {left, []}
      end

    top = border(state, g.(:corner_tl), title, right, g.(:corner_tr), h, width)
    foot = border(state, g.(:corner_bl), bottom, bottom_right, g.(:corner_br), h, width)

    sides =
      Enum.map(lines, fn line ->
        [{v, :text_faint}, {" ", :text_primary}] ++
          Text.fit(state, line, max(width - 4, 0)) ++ [{" ", :text_primary}, {v, :text_faint}]
      end)

    Enum.map([top | sides] ++ [foot], &on_popover/1)
  end

  # `╭─ title ───… right ─╮` (or `╰─ bottom ───…─╯`), the words kept whole
  # when they fit, the title clipped first when they do not.
  defp border(state, left_corner, words, right, right_corner, h, width) do
    lead =
      if words == [],
        do: [{left_corner <> h, :text_faint}],
        else: [{left_corner <> h <> " ", :text_faint}]

    tail =
      if right == [],
        do: [{h <> right_corner, :text_faint}],
        else: [{" ", :text_faint}] ++ right ++ [{" " <> h <> right_corner, :text_faint}]

    room = width - Text.cells(state, lead) - Text.cells(state, tail) - 1

    words =
      if words == [], do: [], else: Text.clip(state, words, max(room, 0)) ++ [{" ", :text_faint}]

    used = Text.cells(state, lead) + Text.cells(state, words) + Text.cells(state, tail)
    lead ++ words ++ [{String.duplicate(h, max(width - used, 0)), :text_faint}] ++ tail
  end

  defp on_popover(line) do
    Enum.map(line, fn
      {text, {_role, :on, _background}} = segment when is_binary(text) -> segment
      {text, {_role, modifiers} = spec} when is_list(modifiers) -> {text, {spec, :on, :popover}}
      {text, role} -> {text, {role, :on, :popover}}
    end)
  end

  @doc "The page and rail behind a popover, every foreground faint (the scrim)."
  @spec scrim([[Text.segment()]]) :: [[Text.segment()]]
  def scrim(lines), do: Enum.map(lines, &Text.scrim/1)

  @doc "The popover's lines (segments), without its frame."
  @spec lines(map(), term()) :: [[Text.segment()]]
  def lines(state, {:help, %{scroll: scroll}}) do
    lines = help(state)
    Enum.drop(lines, min(scroll, max(length(lines) - 4, 0)))
  end

  def lines(_state, {:confirm, %{confirm: %Confirm{} = confirm}}) do
    title =
      [{confirm.title, {:text_primary, [:bold]}}] ++
        if(confirm.undoable?, do: [], else: [{"   not undoable", :warning}])

    body =
      Enum.map(confirm.lines, fn
        line when is_binary(line) -> [{line, :text_primary}]
        line -> line
      end)

    typed =
      case confirm.typed do
        nil ->
          []

        word ->
          [
            [],
            [
              {"type ", :text_muted},
              {word, {:text_primary, [:bold]}},
              {" to confirm: ", :text_muted},
              {confirm.input, :text_primary},
              {"▏", :focus}
            ]
          ]
      end

    counting = if confirm.counting?, do: [[{"counting…", :text_faint}]], else: []

    [title, []] ++ body ++ counting ++ typed ++ [[], buttons(confirm)]
  end

  def lines(_state, {kind, %Picker{} = picker}) when kind in [:picker, :project_picker] do
    visible = Picker.visible(picker)
    count = length(visible)
    start = max(min(picker.cursor - div(@picker_rows, 2), count - @picker_rows), 0)

    title =
      if picker.query == "",
        do: [{picker.title, {:text_primary, [:bold]}}],
        else: [{picker.title, {:text_primary, [:bold]}}, {"  / " <> picker.query, :info}]

    options =
      visible
      |> Enum.with_index()
      |> Enum.slice(start, @picker_rows)
      |> Enum.map(fn {option, index} ->
        current =
          if option.value == picker.current, do: {"• ", :accent}, else: {"  ", :text_primary}

        hint = if option.hint, do: [{"  " <> option.hint, :text_faint}], else: []
        line = [current, {option.label, :text_primary}] ++ hint
        if index == picker.cursor, do: Text.select(line), else: line
      end)

    empty = if count == 0, do: [[{"nothing matches", :text_muted}]], else: []
    position = if count == 0, do: "0 of 0", else: "#{picker.cursor + 1} of #{count}"

    [title, []] ++
      options ++ empty ++ [[], [{position <> " · Enter chooses · Esc closes", :text_faint}]]
  end

  def lines(_state, {:pending, %{items: items}}) do
    count = length(items)
    noun = if count == 1, do: "thing is", else: "things are"

    [[{"#{count} #{noun} not saved here", {:text_primary, [:bold]}}], []] ++
      Enum.map(items, &[{"· " <> &1, :text_primary}]) ++
      [
        [],
        [
          {"s", {:info, [:bold]}},
          {" save what can be saved   ", :text_faint},
          {"d", {:info, [:bold]}},
          {" discard   ", :text_faint},
          {"Esc", {:info, [:bold]}},
          {" stay", :text_faint}
        ]
      ]
  end

  def lines(_state, {kind, _body}), do: [[{to_string(kind), :text_primary}]]

  @doc """
  The model picker as F4 draws it (pass 75, R26.4), framed and `width` cells
  wide in at most `room` lines: the title and the counts on the top border,
  the legend and `Esc close` on the bottom one, the lines of
  `editor_lines/4` inside.
  """
  @spec picker_frame(map(), map(), pos_integer(), pos_integer()) :: [[Text.segment()]]
  def picker_frame(state, popover, width, room) do
    content = editor_lines(state, popover, max(width - 4, 1), max(room - 2, 3))

    title =
      [{to_string(Map.get(popover, :title) || ""), {:text_primary, [:bold]}}] ++
        case Map.get(popover, :subtitle) do
          nil -> []
          sub -> [{" · " <> to_string(sub), :text_faint}]
        end

    right =
      case Map.get(popover, :meta) do
        {providers, models} ->
          [{providers, :text_muted}, {" · ", :text_faint}, {models, :text_muted}]

        meta when is_binary(meta) and meta != "" ->
          [{meta, :text_faint}]

        _ ->
          []
      end

    bottom = {Map.get(popover, :legend) || [], [{"Esc close", :text_faint}]}
    frame(state, content, title, right, bottom, width)
  end

  @doc "The model picker's legend on its bottom border: `✓ current   ! used but unpriced`."
  @spec picker_legend((atom() -> String.t())) :: [Text.segment()]
  def picker_legend(glyphs) do
    [
      {glyphs.(:ok), :success},
      {" current   ", :text_faint},
      {"!", :warning},
      {" used but unpriced", :text_faint}
    ]
  end

  @doc """
  The inside of an editor's popover (the model picker, F4) at `inner` cells
  and at most `room` lines: the filter with `i of n` right, the column names,
  the `none` row, each provider's models on a spine under its heading, and
  `+N more · type to filter` when the list is windowed. The keys are the
  status line's (`PICK`); another editor's popover keeps its keys line.
  """
  @spec editor_lines(map(), map(), pos_integer(), pos_integer()) :: [[Text.segment()]]
  def editor_lines(state, popover, inner, room) do
    rows = Map.get(popover, :rows) || []
    picker? = Map.get(popover, :kind) == :picker
    models? = Enum.any?(rows, &(&1.kind in [:model, :null, :typed]))
    heading = if models?, do: [picker_heading()], else: []
    list_room = max(room - if(picker?, do: 2, else: 4) - length(heading), 3)
    {window, hidden} = picker_window(rows, list_room)
    caps = state.capabilities
    g = &Glyphs.for_caps(&1, caps)
    pad = {" ", :text_primary}

    list =
      window
      |> Enum.with_index()
      |> Enum.map(fn {row, at} ->
        next = Enum.at(window, at + 1)
        closes? = if next, do: next.kind != :model, else: hidden == 0

        line =
          case row.kind do
            :group ->
              {left, right} = split_heading(row.segments)
              Text.spread(state, [pad | left], right ++ [pad], inner)

            :info ->
              [{"  ", :text_primary} | row.segments]

            :model ->
              spine =
                cond do
                  row.focused? -> {g.(:focus_bar), :accent}
                  closes? -> {g.(:spine_end), :text_faint}
                  true -> {g.(:spine), :text_faint}
                end

              [pad, spine | row.segments]

            _ ->
              [pad, if(row.focused?, do: {g.(:focus_bar), :accent}, else: pad) | row.segments]
          end

        if row.focused?,
          do: [pad | Text.band(Text.fit(state, tl(line), max(inner - 1, 0)))],
          else: line
      end)

    more =
      if hidden > 0,
        do: [
          [
            pad,
            {g.(:spine_end), :text_faint},
            {"  ", :text_primary},
            {"+#{hidden} more · type to filter", :text_faint}
          ]
        ],
        else: []

    query =
      Text.spread(
        state,
        [pad | Map.get(popover, :query) || []],
        position(Map.get(popover, :position)) ++ [pad],
        inner
      )

    tail = if picker?, do: [], else: [[], footer(state, popover, inner)]

    [query, []] ++ heading ++ list ++ more ++ tail
  end

  defp split_heading({left, right}), do: {left, right}
  defp split_heading(segments) when is_list(segments), do: {segments, []}

  # `3 of 145`: the figure muted, the rest faint.
  defp position(nil), do: []

  defp position(words) do
    case String.split(to_string(words), " of ", parts: 2) do
      [i, n] -> [{i, :text_muted}, {" of " <> n, :text_faint}]
      [words] -> [{words, :text_faint}]
    end
  end

  defp footer(state, popover, inner) do
    keys =
      (Map.get(popover, :footer) || [])
      |> Enum.flat_map(fn {key, words} ->
        [{key, {:info, [:bold]}}, {" " <> words <> "   ", :text_faint}]
      end)

    Text.spread(state, keys, [], inner)
  end

  defp picker_heading do
    [
      {"    " <>
         String.pad_trailing("model", 34) <>
         String.pad_trailing("context", 16) <>
         "$ per M tokens · in · out", :text_faint}
    ]
  end

  # The rows around the focused one that fit, and how many are left below.
  defp picker_window(rows, room) when length(rows) <= room, do: {rows, 0}

  defp picker_window(rows, room) do
    room = room - 1
    focused = Enum.find_index(rows, & &1.focused?) || 0
    start = focused |> Kernel.-(div(room, 2)) |> max(0) |> min(length(rows) - room)
    window = Enum.slice(rows, start, room)
    {window, length(rows) - start - length(window)}
  end

  defp buttons(%Confirm{} = confirm) do
    safe = [{"[ #{confirm.safe} ]", :text_primary}]
    safe = if confirm.focus == :safe, do: Text.select(safe), else: safe

    danger =
      case confirm.danger do
        "" ->
          []

        words ->
          # cli74 F20: eleven confirmations name the letter in their words
          # already ("T  Trust"); it was drawn twice ("[ T  T  Trust ]").
          label =
            if confirm.letter && not String.starts_with?(words, confirm.letter <> "  "),
              do: "[ #{confirm.letter}  #{words} ]",
              else: "[ #{words} ]"

          role = if Popover.enabled?(confirm), do: :error, else: :text_faint
          line = [{label, role}]

          [
            {"   ", :text_primary}
            | if(confirm.focus == :danger, do: Text.select(line), else: line)
          ]
      end

    safe ++ danger
  end

  # ------------------------------------------------------------- help

  @doc "The groups of the keys sheet: `{title, verbs}`."
  def help_groups, do: @groups

  defp help(state) do
    # The keys of the layer under the sheet, not the sheet's own (QA F-5).
    context = SettingsContext.context(%{state.settings | popover: nil})
    overrides = Keymap.overrides(state)
    bindings = Enum.filter(SettingsBindings.all(), &(context in &1.contexts))

    by_verb =
      Map.new(bindings, fn binding ->
        verb =
          case binding.action do
            {:settings, {:verb, verb}} -> verb
            {:special, :settings_close} -> :escape
            {:special, :settings_rail} -> :next_region
            _ -> binding.id
          end

        {verb, binding}
      end)

    entries =
      for {title, verbs} <- @groups,
          found =
            for(verb <- verbs, binding = Map.get(by_verb, verb), binding != nil, do: binding),
          found != [],
          do: {title, found}

    inner = help_width(state)
    wide? = inner >= 120

    groups =
      if wide?,
        do: flow(entries, inner, overrides),
        else:
          Enum.flat_map(entries, fn {title, found} ->
            [[{title, :text_muted}] | Enum.map(found, &key_row(&1, overrides))] ++ [[]]
          end)

    this_row =
      case Nav.current(state) do
        %{keys: [_ | _] = keys} ->
          [
            [{"this row", :text_muted}]
            | Enum.map(keys, fn {key, _verb, words} ->
                [{String.pad_trailing(key, 12), {:info, [:bold]}}, {words, :text_primary}]
              end)
          ] ++ [[]]

        _ ->
          []
      end

    [[{"Keys in settings", {:text_primary, [:bold]}}], []] ++
      groups ++
      this_row ++
      legend(state, if(wide?, do: inner, else: nil)) ++
      [
        [
          {"/settings <words> opens straight at a setting · :set <key> <value> · swarmcode config in a shell",
           :text_faint}
        ],
        [{"Remapped yourself out of a key? swarmcode config reset terminal.keys", :text_faint}]
      ]
  end

  # The sheet's inner width: the popover's frame and margins off the screen's.
  defp help_width(%{size: %{columns: columns}}) when is_integer(columns), do: columns - 10
  defp help_width(_state), do: 70

  # F13 at 120 columns and more: the groups flow down three columns, one key
  # and its short name per line, so every key of the page shows at once.
  defp flow(entries, inner, overrides) do
    column = div(inner - 4, 3)

    lines =
      entries
      |> Enum.map(fn {title, found} ->
        [[{String.pad_trailing(title, column), :text_muted}]] ++
          Enum.map(found, fn binding ->
            key = binding.id |> Bindings.keys_for(overrides) |> key_words()

            [
              {String.pad_trailing(key, 15), {:info, [:bold]}},
              {String.pad_trailing(short_help(binding, column - 15), column - 15), :text_primary}
            ]
          end)
      end)
      |> Enum.intersperse([[{String.duplicate(" ", column), :text_primary}]])
      |> Enum.concat()

    height = div(length(lines) + 2, 3)

    lines
    |> Enum.chunk_every(height)
    |> columns(column)
  end

  # Rows of side-by-side column lines (a short column is padded with blanks).
  defp columns(chunks, column) do
    height = chunks |> Enum.map(&length/1) |> Enum.max(fn -> 0 end)
    blank = [{String.duplicate(" ", column), :text_primary}]
    padded = Enum.map(chunks, &(&1 ++ List.duplicate(blank, height - length(&1))))

    padded
    |> Enum.zip()
    |> Enum.map(fn row ->
      row |> Tuple.to_list() |> Enum.intersperse([{"  ", :text_primary}]) |> Enum.concat()
    end)
    |> Kernel.++([[]])
  end

  # The help's first clause when it fits the column, else the binding's name.
  defp short_help(binding, room) do
    clause =
      binding.help
      |> String.split([" (", "; "], parts: 2)
      |> hd()
      |> String.trim_trailing(".")

    if String.length(clause) <= room, do: clause, else: binding.label
  end

  defp key_words([]), do: "unbound"

  defp key_words(keys),
    do: keys |> Enum.take(2) |> Enum.map_join(", ", &KeyName.format(&1, :rich))

  # F13: what every mark and tag means, then where a value comes from.
  defp legend(state, inner) do
    tier = Glyphs.tier(state.capabilities)
    g = &Glyphs.get(&1, tier)

    marks = [
      {g.(:changed), :text_muted, "changed from its default"},
      {"!", :warning, "needs your attention"},
      {g.(:fail), :error, "failed, or not allowed"},
      {g.(:ok), :success, "answered, allowed, the winner"},
      {g.(:running), :info, "running now"},
      {g.(:focus_bar), :focus, "focus"},
      {g.(:check_on) <> " on  " <> g.(:check_off) <> " off", :text_muted, ""},
      {g.(:secret), :text_muted, "a secret, never shown"},
      {g.(:action), :text_muted, "an action, not a value"},
      {if(tier == :ascii, do: "...", else: "…"), :text_muted, "opens a confirmation first"}
    ]

    mark_lines =
      case inner do
        nil ->
          Enum.map(marks, fn {mark, role, words} ->
            [{String.pad_trailing(mark, 12), role}, {words, :text_primary}]
          end)

        inner ->
          column = div(inner - 4, 3)

          marks
          |> Enum.map(fn {mark, role, words} ->
            [
              {String.pad_trailing(mark, 15), role},
              {String.pad_trailing(words, column - 15), :text_primary}
            ]
          end)
          |> Enum.chunk_every(3)
          |> Enum.map(fn row ->
            row |> Enum.intersperse([{"  ", :text_primary}]) |> Enum.concat()
          end)
      end

    # Pass 75 (R25.8, D19): after the `•` line, what a coloured spine says.
    spine =
      if Glyphs.twin?(state.capabilities),
        do: [
          {"* ", :text_primary},
          {"set  ", :text_muted},
          {"| ", :text_faint},
          {"default  ", :text_muted},
          {"! ", :warning},
          {"attention", :text_muted}
        ],
        else: [
          {"│  ", :text_faint},
          {"a coloured spine: the layer that set the value  ", :text_muted},
          {"session", :agent_lane_1},
          {"  ", :text_muted},
          {"project", :agent_lane_2},
          {"  ", :text_muted},
          {"env", :agent_lane_4},
          {"  ", :text_muted},
          {"flag", :agent_lane_5},
          {"  ", :text_muted},
          {"cli.json", :run_consensus_judge}
        ]

    spine_lines = Text.wrap_segments(state, spine, inner || help_width(state))

    mark_lines =
      case mark_lines do
        [first | rest] -> [first | spine_lines] ++ rest
        [] -> spine_lines
      end

    [[{"marks", :text_muted}]] ++
      mark_lines ++
      [
        [],
        [{"where a value comes from, strongest first", :text_muted}],
        [
          {"flag ", :text_primary},
          {"this launch's command line · ", :text_faint},
          {"env ", :text_primary},
          {"a variable in your shell · ", :text_faint},
          {"session ", :text_primary},
          {"this conversation", :text_faint}
        ],
        [
          {"project ", :text_primary},
          {"this project · ", :text_faint},
          {"cli.json ", :text_primary},
          {"this machine's terminal · ", :text_faint},
          {"global ", :text_primary},
          {"shared with the desktop app", :text_faint}
        ],
        [
          {"project file ", :text_primary},
          {".swarm_code/config.json, fills gaps only · ", :text_faint},
          {"default ", :text_primary},
          {"built in", :text_faint}
        ],
        [
          {"flag and env are read at launch and are not changed here; their row names the flag or the variable.",
           :text_faint}
        ],
        []
      ]
  end

  defp key_row(binding, overrides) do
    key = binding.id |> Bindings.keys_for(overrides) |> key_words()

    [
      {String.pad_trailing(key, 12), {:info, [:bold]}},
      {binding.label <> " — " <> binding.help, :text_primary}
    ]
  end
end
