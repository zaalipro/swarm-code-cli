defmodule SwarmCodeCLI.UI.SlashPalette do
  @moduledoc "Pure builtin command completion. Suggestions never execute or dispatch a command."

  alias SwarmCode.Commands
  alias SwarmCodeCLI.UI.{Drafts, Editor, State}
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
      args: "[full|compact|hidden]",
      desc: "The side agent panel's shape (Ctrl-B cycles it); remembered"
    },
    # pass73 T1/T2/T9: display preferences, remembered in cli.json.
    %{
      name: "diff",
      args: "[on|off]",
      desc: "Show or hide diffs and file previews under tool rows; remembered"
    },
    %{name: "theme", args: "[dark|light]", desc: "Switch the dark or light theme; remembered"},
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
    %{name: "queue", args: "<text>", desc: "Send this after the running turn"},
    %{name: "help", args: "", desc: "List the commands and the keys"},
    %{name: "quit", args: "", desc: "Leave SwarmCode; running work of this session stops"}
  ]
  @local_names Enum.map(@local, & &1.name)

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
      nil -> []
      {_key, query} -> catalogue(query)
    end
  end

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
      for item <- @local, score(item.name, needle) != nil do
        own = Map.merge(item, %{scope: nil, kind: :builtin, client: true})
        if item.name in @own_words, do: own, else: Map.get(flagged, item.name, own)
      end

    names = Enum.map(local, & &1.name)

    (local ++ Enum.reject(remote, &(&1.name in names or &1.name in @shadowed)))
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
        0
    end
  end

  defp context(%{focus: "composer", layers: []} = state), do: draft_context(state)

  # pass73 G1 (QA Q1-01): a draft typed under an approval card that opened by
  # itself is still the composer's (`Keymap.typing_under_card?/1`), so its
  # `/com` lists, completes and runs `/compact` as it does without the card.
  defp context(%{layers: [{:approval, _} | _]} = state) do
    if SwarmCodeCLI.UI.Keymap.typing_under_card?(state), do: draft_context(state), else: nil
  end

  defp context(_), do: nil

  defp draft_context(state) do
    with key when not is_nil(key) <- State.current_draft_key(state),
         draft <- Drafts.fetch(state.drafts, key),
         text <- Editor.text(draft.editor),
         true <- byte_size(text) <= 257 and Regex.match?(~r/^\/[A-Za-z0-9_.-]*\z/, text),
         true <- Editor.cursor(draft.editor) == String.length(text),
         nil <- Editor.selection(draft.editor) do
      {key, text}
    else
      _ -> nil
    end
  end
end
