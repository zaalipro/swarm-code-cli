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
  The inside of an editor's popover (the model picker, F4) at `inner` cells
  and at most `room` lines: the filter, the column names, the window of rows
  around the focused one, then the keys with `N of M` on the right.
  """
  @spec editor_lines(map(), map(), pos_integer(), pos_integer()) :: [[Text.segment()]]
  def editor_lines(state, popover, inner, room) do
    rows = Map.get(popover, :rows) || []
    models? = Enum.any?(rows, &(&1.kind in [:model, :null, :typed]))
    heading = if models?, do: [picker_heading()], else: []
    list_room = max(room - 5 - length(heading), 3)
    {window, hidden} = picker_window(rows, list_room)
    bar = Glyphs.get(:focus_bar, Glyphs.tier(state.capabilities))

    list =
      Enum.map(window, fn row ->
        line =
          case row.kind do
            :group -> [{" ", :text_primary} | row.segments]
            :info -> [{"  ", :text_primary} | row.segments]
            _ -> [lead(row.focused?, bar), {" ", :text_primary} | row.segments]
          end

        if row.focused?, do: Text.select(line), else: line
      end)

    more =
      if hidden > 0,
        do: [[{"    … #{hidden} more, type to filter", :text_faint}]],
        else: []

    keys =
      (Map.get(popover, :footer) || [])
      |> Enum.flat_map(fn {key, words} ->
        [{key, {:info, [:bold]}}, {" " <> words <> "   ", :text_faint}]
      end)

    footer =
      Text.spread(
        state,
        keys,
        [{to_string(Map.get(popover, :position) || ""), :text_faint}],
        inner
      )

    rule = Glyphs.get(:rule_h, Glyphs.tier(state.capabilities))

    [Map.get(popover, :query) || [], []] ++
      heading ++ list ++ more ++ [[], [{String.duplicate(rule, inner), :border}], footer]
  end

  defp lead(true, bar), do: {bar, :focus}
  defp lead(false, _bar), do: {" ", :text_primary}

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

          role = if Popover.enabled?(confirm), do: :error, else: :text_ghost
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
