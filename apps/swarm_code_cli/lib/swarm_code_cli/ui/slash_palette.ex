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
    %{name: "queue", args: "<text>", desc: "Send this after the running turn"},
    %{name: "help", args: "", desc: "List the commands and the keys"},
    %{name: "quit", args: "", desc: "Leave SwarmCode; running work of this session stops"}
  ]
  @local_names Enum.map(@local, & &1.name)

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
        Map.get_lazy(flagged, item.name, fn ->
          Map.merge(item, %{scope: nil, kind: :builtin, client: true})
        end)
      end

    names = Enum.map(local, & &1.name)

    (local ++ Enum.reject(remote, &(&1.name in names)))
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

  defp context(%{focus: "composer", layers: []} = state) do
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

  defp context(_), do: nil
end
