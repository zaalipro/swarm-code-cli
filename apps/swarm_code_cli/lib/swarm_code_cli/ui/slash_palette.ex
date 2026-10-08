defmodule SwarmCodeCLI.UI.SlashPalette do
  @moduledoc "Pure builtin command completion. Suggestions never execute or dispatch a command."

  alias SwarmCode.Commands
  alias SwarmCodeCLI.UI.{Drafts, Editor, SlashArgs, State}
  alias SwarmCodeCLI.UI.Reducer.Editing

  # The popup above the composer shows this many rows and scrolls within them.
  @rows 8

  # The commands the client answers itself (`Keymap.local_command/1`). The
  # service's catalogue lists them too once it flags them `client: true`
  # (pass70 C7); until then, and over an older entry of the same name (the
  # catalogue's `resume` used to resume a run), these are the ones shown.
  @local [
    %{name: "new", args: "", desc: "Start a new conversation; this one stays saved"},
    %{name: "resume", args: "", desc: "Open a saved conversation (pick one)"},
    %{
      name: "approval",
      args: "[read-only|auto|full]",
      desc: "How much agents may do without asking"
    },
    %{name: "trust", args: "", desc: "Trust this project: read its AGENTS.md and allow edits"},
    %{
      name: "panel",
      args: "[full|compact|hidden|summaries on|off]",
      desc: "The side agent panel's shape (Ctrl-B cycles it) and its AI status lines; remembered"
    },
    # pass73 T1/T2/T9: display preferences, remembered in cli.json.
    %{
      name: "diff",
      args: "[on|off]",
      desc: "Show or hide diffs and file previews under tool rows; remembered"
    },
    # cli020 E27: a palette name sets `terminal.palette` (D's `/theme`).
    %{
      name: "theme",
      args: "[dark|light|carbon|aurora|dusk|ember|fjord|graphite|obsidian|paper]",
      desc: "Switch dark or light, or the palette; remembered"
    },
    %{
      name: "mouse",
      args: "[on|off]",
      desc: "Wheel scrolling on, or off for the terminal's own selection; remembered"
    },
    # cli74: the settings layer (F2); `/config` and `/prefs` open it too.
    %{
      name: "settings",
      args: "[section or setting]",
      desc: "Every setting: models, providers, search, MCP, keys, this terminal"
    },
    # cli020 E3 (D20): bare `/queue` lists the queue, `clear` and `drop N`
    # edit it; the rewind, effort and delete rows are the client's too.
    %{
      name: "queue",
      args: "<text> | clear | drop N",
      desc: "Send this after the running turn; bare: the queue"
    },
    %{
      name: "rewind",
      args: "",
      desc: "Rewind the conversation and files to before an earlier turn"
    },
    %{name: "undo", args: "", desc: "Rewind the last turn: its messages and its files"},
    %{name: "delete", args: "", desc: "Delete this conversation (asks first)"},
    %{
      name: "effort",
      args: "[default|low|medium|high|max]",
      desc: "Reasoning effort of this conversation's chat model; bare: pick one"
    },
    %{
      name: "worker_effort",
      args: "[default|low|medium|high|max]",
      desc: "Reasoning effort of this conversation's worker model; bare: pick one"
    },
    %{name: "help", args: "", desc: "List the commands and the keys"},
    %{name: "quit", args: "", desc: "Leave ncode; running work of this session stops"}
  ]
  @local_names Enum.map(@local, & &1.name)

  # cli020 E3: local rows for core commands; they replace the catalogue's
  # words in its own order rather than moving to the top.
  @in_place ~w(rewind undo delete effort worker_effort)
  @in_place_rows for item <- @local, item.name in @in_place, into: %{}, do: {item.name, item}

  # pass73: commands whose meaning the client changed; their catalogue entry
  # (`diff` was "the files this conversation changed") lends no words.
  @own_words ~w(diff theme mouse approval settings)

  # cli74: the client's `/settings` answers these names too, so a custom
  # command of the same name is shadowed (Settings › Library says so).
  @shadowed ~w(config prefs)

  # pass73 T4: commands with an optional argument that is their point; Enter
  # on the palette writes `/<name> ` for them and waits, as for a required
  # `<argument>`. Every other command without a required argument runs.
  @wants_text ~w(consensus create-workflow goal plan swarm queue search attach workflow)

  # Names the client answers that no catalogue lists (`Keymap.local_command/1`).
  @quiet ~w(exit conversations config prefs)

  @doc """
  cli021 B4: whether `name` (without the slash) is a command the composer
  draws in the command colour: the client's own, the core registry's and the
  worker commands' hidden old names. A project's custom commands and
  workflows are the daemon's to know, so they read as unknown here.
  """
  @spec known?(term()) :: boolean()
  def known?(name) when is_binary(name) do
    name = String.downcase(name)
    canonical = SlashArgs.canonical(name)

    canonical in @local_names or canonical in @quiet or
      Enum.any?(Commands.catalogue("/" <> canonical), &(&1.name == canonical))
  end

  def known?(_name), do: false

  @doc "Rows of the popup above the composer (pass 70 E5); `visible(state, rows())`."
  def rows, do: @rows

  @doc "Validate a canonical builtin name without accepting input arguments or dynamic atoms."
  def valid_name?(name) do
    is_binary(name) and byte_size(name) <= 256 and String.valid?(name) and
      (name in @local_names or Enum.any?(Commands.catalogue(), &(&1.name == name)))
  end

  @doc "Suggestions only apply to the entire first token, with the caret at its end."
  def entries(state) do
    case context(state) do
      nil -> arg_entries(state)
      {_key, query} -> catalogue(query)
    end
  end

  # ------------------------------------------------- the argument dropdown
  #
  # cli021 B3: once the draft is `/<command> ` (with or without a partial
  # argument) and the command has choices (`SlashArgs`), the same popup lists
  # them instead of the commands: filtered by what is typed, the current value
  # marked in its words. A row is a map like a command's (`name` is the
  # `<command> <label>` the popup draws after its `/`, `desc` its words)
  # plus `arg?: true`, `text` (the draft it completes to, without the slash),
  # `command`, `value`, `current?`. Up/Down move, Tab completes the draft, Enter
  # completes it and runs it (`enter_completion/1`), Esc closes the list only
  # (`dismiss_args/1`) until the draft leaves that command.

  @arg_bytes 600

  @doc "Whether the popup shows a command's argument choices rather than commands."
  @spec args_open?(map()) :: boolean()
  def args_open?(state), do: context(state) == nil and arg_entries(state) != []

  defp arg_entries(state) do
    with {key, command, typed} <- arg_context(state),
         false <- dismissed?(state, key, command),
         [_ | _] = choices <- SlashArgs.matching(state, command, typed) do
      canonical = SlashArgs.canonical(command)

      for choice <- choices do
        %{
          name: canonical <> " " <> choice.label,
          text: canonical <> " " <> choice.value,
          command: canonical,
          value: choice.value,
          label: choice.label,
          args: "",
          desc: choice.desc,
          scope: nil,
          kind: :builtin,
          client: true,
          arg?: true,
          current?: choice.current?
        }
      end
    else
      _ -> []
    end
  end

  # `{draft key, command as typed, the argument typed so far}` while the draft
  # is one line `/<command> <argument>` with the caret at its end.
  defp arg_context(state) do
    with {key, text} <- draft_at_caret(state, @arg_bytes),
         [_, command, typed] <-
           Regex.run(~r/\A\/([A-Za-z0-9_.-]+) ([^\n\r]*)\z/u, text) do
      {key, command, typed}
    else
      _ -> nil
    end
  end

  defp dismissed?(state, key, command) do
    case state.slash_palette do
      %{dismissed: {^key, dismissed}} -> dismissed == SlashArgs.canonical(command)
      _ -> false
    end
  end

  @doc "Esc: closes the argument list until the draft leaves this command."
  @spec dismiss_args(map()) :: map()
  def dismiss_args(state) do
    case arg_context(state) do
      {key, command, _typed} ->
        base = if is_map(state.slash_palette), do: state.slash_palette, else: %{}
        %{state | slash_palette: Map.put(base, :dismissed, {key, SlashArgs.canonical(command)})}

      nil ->
        state
    end
  end

  @doc """
  What an edit of the draft leaves of the palette's state: nothing, except
  that a closed argument list stays closed while the draft is still the same
  command's arguments.
  """
  @spec after_edit(map()) :: map()
  def after_edit(state) do
    with %{dismissed: {key, command} = dismissed} <- state.slash_palette,
         {^key, typed_command, _typed} <- arg_context(state),
         true <- SlashArgs.canonical(typed_command) == command do
      %{state | slash_palette: %{dismissed: dismissed}}
    else
      _ -> %{state | slash_palette: nil}
    end
  end

  @doc """
  The draft an argument row completes to: replaces the draft with
  `/<text>` (one undoable edit), the row must be one the list shows.
  """
  @spec complete_argument(map(), binary()) :: {map(), list()}
  def complete_argument(state, text) do
    with true <- is_binary(text),
         {key, _command, _typed} <- arg_context(state),
         true <- Enum.any?(arg_entries(state), &(&1.text == text)),
         draft <- Drafts.fetch(state.drafts, key),
         true <- byte_size("/" <> text) <= draft.editor.max_bytes do
      {selected, effects} = Editing.apply(state, :editor, key, :select_all)
      {completed, edits} = Editing.apply(selected, :editor, key, {:paste, "/" <> text})
      {%{completed | slash_palette: nil}, effects ++ edits}
    else
      _ -> {state, []}
    end
  end

  @doc "The argument row `text` is, when the list shows it; else nil."
  @spec argument_row(map(), binary()) :: map() | nil
  def argument_row(state, text), do: Enum.find(arg_entries(state), &(&1.text == text))

  @doc """
  The service's commands and the client's own for `query` (`"/"`, `"/re"`):
  best match first, the client's first among equals, each name once.
  """
  def catalogue(query) do
    remote = Commands.catalogue(query)
    flagged = for item <- remote, Map.get(item, :client) == true, into: %{}, do: {item.name, item}
    needle = query |> String.trim_leading("/") |> String.downcase()

    # The client's commands keep their place at the top; an entry the catalogue
    # flags `client: true` (pass70 C7) lends its words but not its position.
    local =
      for item <- @local, item.name not in @in_place, score(item.name, needle) != nil do
        own = Map.merge(item, %{scope: nil, kind: :builtin, client: true})
        if item.name in @own_words, do: own, else: Map.get(flagged, item.name, own)
      end

    names = Enum.map(local, & &1.name)

    # cli020 E3: a core command whose bare form the client answers keeps the
    # catalogue's place (so `/sw` still means `/swarm`) with the local words.
    remote =
      for item <- remote, item.name not in names and item.name not in @shadowed do
        case Map.get(@in_place_rows, item.name) do
          nil -> item
          own -> Map.merge(item, Map.put(own, :client, true))
        end
      end

    (local ++ remote)
    |> Enum.with_index()
    |> Enum.sort_by(fn {item, index} -> {score(item.name, needle), index} end)
    |> Enum.map(&elem(&1, 0))
  end

  # The catalogue's own ranking: a prefix of the name, then of one of its parts.
  defp score(_name, ""), do: 0

  defp score(name, needle) do
    cond do
      String.starts_with?(name, needle) -> 0
      Enum.any?(String.split(name, ["-", "_", "."]), &String.starts_with?(&1, needle)) -> 1
      true -> nil
    end
  end

  def open?(state), do: entries(state) != []

  def selected(state) do
    Enum.at(entries(state), index(state))
  end

  @doc "A bounded window which always includes the current selection."
  def visible(state, limit) when is_integer(limit) and limit > 0 do
    items = entries(state)
    selected = index(state)
    first = max(0, min(selected, length(items) - limit))

    items
    |> Enum.with_index()
    |> Enum.drop(first)
    |> Enum.take(limit)
    |> Enum.map(fn {item, position} -> Map.put(item, :selected?, position == selected) end)
  end

  def visible(_, _), do: []

  def move(state, direction) when direction in [:next, :previous, :first, :last] do
    items = entries(state)

    if items == [] do
      state
    else
      next =
        case direction do
          :first -> 0
          :last -> length(items) - 1
          :next -> Integer.mod(index(state) + 1, length(items))
          :previous -> Integer.mod(index(state) - 1, length(items))
        end

      %{state | slash_palette: %{context: context(state), index: next}}
    end
  end

  @doc """
  pass73 T4: what Enter does while the palette is open. `{:complete, name}`
  writes `/<name> ` and waits for the argument; `{:run, name}` runs the
  highlighted command at once (it takes no argument); nil when the palette
  is closed or the draft already names a command exactly (Enter sends it as
  typed).
  """
  @spec enter_completion(map()) :: {:complete | :run, binary()} | nil
  def enter_completion(state) do
    case context(state) do
      nil -> arg_enter(state)
      _ -> command_enter(state)
    end
  end

  # cli021 B3: Enter on the argument list completes the highlighted row and
  # runs the command, unless the draft already says exactly one of the rows.
  defp arg_enter(state) do
    with {_key, _command, typed} <- arg_context(state),
         [_ | _] = rows <- arg_entries(state),
         needle = typed |> String.trim() |> String.downcase(),
         false <- Enum.any?(rows, &exact?(&1, needle)),
         %{text: text} <- selected(state) do
      {:run_argument, text}
    else
      _ -> nil
    end
  end

  # A model typed by its own name (`/model gpt-5.5`) is as complete as the
  # `provider|model` pair the row inserts.
  defp exact?(row, needle),
    do:
      needle != "" and
        needle in [String.downcase(row.value), String.downcase(Map.get(row, :label, ""))]

  defp command_enter(state) do
    with {_key, query} <- context(state),
         items when items != [] <- catalogue(query),
         name = query |> String.trim_leading("/") |> String.downcase(),
         false <- name != "" and Enum.any?(items, &(&1.name == name)),
         %{name: selected} = item <- selected(state) do
      if runs_bare?(item), do: {:run, selected}, else: {:complete, selected}
    else
      _ -> nil
    end
  end

  @doc """
  Whether a palette entry runs without an argument: it takes none, or only
  an optional one that is not its point. A required `<argument>` or one of
  the text commands (`/consensus [task]`) waits for the argument.
  """
  @spec runs_bare?(map()) :: boolean()
  def runs_bare?(%{name: name} = item) do
    args = Map.get(item, :args) || ""

    cond do
      String.trim(args) == "" -> true
      String.contains?(args, "<") -> false
      name in @wants_text -> false
      true -> true
    end
  end

  def runs_bare?(_item), do: false

  @doc "Replace only the current matching draft, as one undoable editor replacement."
  def complete(state, name) do
    with true <- valid_name?(name),
         {key, _} <- context(state),
         true <- Enum.any?(entries(state), &(&1.name == name)),
         draft <- Drafts.fetch(state.drafts, key),
         true <- byte_size("/" <> name <> " ") <= draft.editor.max_bytes do
      {selected, effects} = Editing.apply(state, :editor, key, :select_all)
      {completed, edits} = Editing.apply(selected, :editor, key, {:paste, "/" <> name <> " "})
      {%{completed | slash_palette: nil}, effects ++ edits}
    else
      _ -> {state, []}
    end
  end

  defp index(state) do
    case state.slash_palette do
      %{context: saved, index: index} when is_integer(index) and index >= 0 ->
        if saved == context(state), do: min(index, max(0, length(entries(state)) - 1)), else: 0

      _ ->
        initial_index(state)
    end
  end

  # cli022 F3: the argument list opens with its cursor on the current value
  # (the first marked row), the command list on its first row.
  defp initial_index(state) do
    if context(state) == nil,
      do: Enum.find_index(entries(state), &(Map.get(&1, :current?) == true)) || 0,
      else: 0
  end

  defp context(state), do: if(gate?(state), do: draft_context(state))

  # The palette belongs to the composer's draft: focused with no layer over
  # it, or (pass73 G1, QA Q1-01) a draft typed under an approval card that
  # opened by itself (`Keymap.typing_under_card?/1`), so its `/com` lists,
  # completes and runs `/compact` as it does without the card.
  defp gate?(%{focus: "composer", layers: []}), do: true

  defp gate?(%{layers: [{:approval, _} | _]} = state),
    do: SwarmCodeCLI.UI.Keymap.typing_under_card?(state)

  defp gate?(_state), do: false

  defp draft_context(state) do
    with {key, text} <- draft_at_caret(state, 257),
         true <- Regex.match?(~r/^\/[A-Za-z0-9_.-]*\z/, text) do
      {key, text}
    else
      _ -> nil
    end
  end

  # The composer's draft as `{key, text}` while the caret ends it with no
  # selection and it is no longer than `max` bytes; else nil.
  defp draft_at_caret(state, max) do
    with true <- gate?(state),
         key when not is_nil(key) <- State.current_draft_key(state),
         draft <- Drafts.fetch(state.drafts, key),
         text <- Editor.text(draft.editor),
         true <- byte_size(text) <= max,
         true <- Editor.cursor(draft.editor) == String.length(text),
         nil <- Editor.selection(draft.editor) do
      {key, text}
    else
      _ -> nil
    end
  end
end
