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
  alias SwarmCodeCLI.UI.Settings.{Confirm, Nav, Picker}

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
       :goto,
       :jump
     ]},
    {"change",
     [:enter, :toggle, :big_left, :big_right, :reset, :undo, :redo, :save, :external, :commit]},
    {"search and commands", [:search, :command, :refresh, :needs_you, :complete, :info]},
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

  defp help(state) do
    context = SettingsContext.context(state.settings)
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

    groups =
      Enum.flat_map(@groups, fn {title, verbs} ->
        rows =
          for verb <- verbs,
              binding = Map.get(by_verb, verb),
              binding != nil,
              do: key_row(binding, overrides)

        if rows == [], do: [], else: [[{title, :text_muted}] | rows] ++ [[]]
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
      [
        [
          {"/settings <words> opens straight at a setting · :set <key> <value> · swarmcode config in a shell",
           :text_faint}
        ],
        [{"Remapped yourself out of a key? swarmcode config reset terminal.keys", :text_faint}]
      ]
  end

  defp key_row(binding, overrides) do
    key =
      case Bindings.keys_for(binding.id, overrides) do
        [] -> "unbound"
        keys -> keys |> Enum.take(2) |> Enum.map_join(", ", &KeyName.format(&1, :rich))
      end

    [
      {String.pad_trailing(key, 12), {:info, [:bold]}},
      {binding.label <> " — " <> binding.help, :text_primary}
    ]
  end
end
