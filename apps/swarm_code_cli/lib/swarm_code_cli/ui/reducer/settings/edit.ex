defmodule SwarmCodeCLI.UI.Reducer.Settings.Edit do
  @moduledoc """
  The editor of a settings row while it is open (spec §3.7.2, §3.7.8):
  `open/3` starts the row's `{module, opts}` editor, `event/2` hands it one
  event, and its answer continues, commits (through the section's
  `commit/3`, else the generic commit path), cancels or runs ops.

  An editor from another owner that is not in this build (the model picker,
  the colour editor) falls back to a text editor over the entry's own text
  form, so any branch edits every row.
  """

  alias SwarmCode.Settings.Registry
  alias SwarmCodeCLI.UI.Reducer.Settings.{Commit, Ops}
  alias SwarmCodeCLI.UI.Settings.{Editors, Layer, Nav, Row, Sections}

  @verb_events %{
    commit: {:key, :enter},
    enter: {:key, :enter},
    escape: {:key, :escape},
    back: {:key, :escape},
    left: {:key, :left},
    right: {:key, :right},
    up: {:key, :up},
    down: {:key, :down},
    page_up: {:key, :page_up},
    page_down: {:key, :page_down},
    first: {:key, :home},
    last: {:key, :end},
    big_left: {:key, {:shift, :left}},
    big_right: {:key, {:shift, :right}},
    line_start: {:key, {:ctrl, "a"}},
    line_end: {:key, {:ctrl, "e"}},
    delete_word: {:key, {:ctrl, "w"}},
    clear_line: {:key, {:ctrl, "u"}},
    backspace: {:key, :backspace},
    delete_forward: {:key, :delete},
    complete: {:key, :tab},
    save: {:key, {:ctrl, "s"}},
    external: {:key, {:ctrl, "x"}},
    toggle: {:key, :space}
  }

  @doc "The editor event a layer verb means while an editor is open (nil: not the editor's)."
  @spec verb_event(atom()) :: term() | nil
  def verb_event(verb), do: Map.get(@verb_events, verb)

  @doc "Opens the editor of `row` (with `extra` merged into its opts)."
  @spec open(map(), Row.t(), map()) :: {map(), list()}
  def open(state, row, extra \\ %{})

  def open(%{settings: %Layer{}} = state, %Row{editor: {module, opts}} = row, extra) do
    ctx = Nav.ctx(state)
    opts = Map.merge(opts, extra)

    case init(module, row, opts, ctx) do
      {:ok, module, editor_state} ->
        editing = %{
          row_id: row.id,
          key: row.key,
          row: row,
          module: module,
          state: editor_state,
          context: :settings_edit
        }

        state = put_editing(state, editing)
        {state |> refresh_context() |> clear_error(row.id), []}

      {:error, words} ->
        {Commit.status(state, words, :error), []}
    end
  end

  def open(state, _row, _extra), do: {state, []}

  defp init(module, row, opts, ctx) do
    case module.init(row, opts, ctx) do
      {:ok, editor_state} -> {:ok, module, editor_state}
      {:error, words} -> {:error, words}
    end
  rescue
    error in UndefinedFunctionError ->
      if error.module == module and error.function == :init,
        do: fallback(row, opts, ctx),
        else: reraise(error, __STACKTRACE__)
  end

  # The model picker or the colour editor is not in this build: the entry's
  # text form (`provider/model`, `#RRGGBB`) is edited as text.
  defp fallback(%Row{key: key} = row, opts, ctx) when is_binary(key) do
    case Registry.fetch(key) do
      {:ok, entry} ->
        value = Map.get(opts, :current, Map.get(opts, :value))

        text =
          if value in [nil, ""], do: "", else: SwarmCode.Settings.TextValue.format(entry, value)

        opts = %{value: text, max: 400, parse: entry, nullable: entry.nullable}
        {:ok, editor_state} = Editors.Text.init(row, opts, ctx)
        {:ok, Editors.Text, editor_state}

      :error ->
        {:error, "This row can't be edited here"}
    end
  end

  defp fallback(_row, _opts, _ctx), do: {:error, "This row can't be edited here"}

  @doc """
  One event for the open editor. Ctrl-C clears the text first and cancels
  when there is nothing left to clear.
  """
  @spec event(map(), term()) :: {map(), list()}
  def event(%{settings: %Layer{editing: %{} = editing}} = state, :interrupt) do
    ctx = Nav.ctx(state)

    case editing.module.handle(editing.state, {:key, {:ctrl, "u"}}, ctx) do
      {:cont, same} when same == editing.state -> cancel(state)
      answer -> answer(state, editing, answer)
    end
  end

  def event(%{settings: %Layer{editing: %{} = editing}} = state, event) do
    answer(state, editing, editing.module.handle(editing.state, event, Nav.ctx(state)))
  end

  def event(state, _event), do: {state, []}

  defp answer(state, editing, {:cont, editor_state}),
    do: {state |> put_editing(%{editing | state: editor_state}) |> refresh_context(), []}

  defp answer(state, editing, {:commit, value, _editor_state}) do
    state = close(state)
    commit(state, editing.row, value)
  end

  defp answer(state, _editing, {:cancel, _editor_state}), do: cancel(state)

  defp answer(state, editing, {:ops, ops, editor_state}) do
    state |> put_editing(%{editing | state: editor_state}) |> refresh_context() |> Ops.run(ops)
  end

  @doc "Closes the editor and puts the old value back."
  @spec cancel(map()) :: {map(), list()}
  def cancel(state), do: {close(state), []}

  @doc "Closes the editor (the layer browses again)."
  @spec close(map()) :: map()
  def close(%{settings: %Layer{} = layer} = state),
    do: %{state | settings: %{layer | editing: nil, mode: :browse}}

  @doc """
  Writes `value` for `row`: the section's `commit/3` first, else the
  generic path (a registry key's patch).
  """
  @spec commit(map(), Row.t() | map(), term()) :: {map(), list()}
  def commit(%{settings: %Layer{} = layer} = state, row, value) do
    ctx = Nav.ctx(state)

    case Sections.commit(Layer.section(layer), ctx, row, value) do
      ops when is_list(ops) ->
        Ops.run(state, ops)

      _default ->
        case Map.get(row, :key) do
          key when is_binary(key) -> Commit.patch(state, key, value, reason: :edit)
          _ -> {state, []}
        end
    end
  end

  # The keymap context follows what the editor says it needs.
  defp refresh_context(%{settings: %Layer{editing: %{} = editing} = layer} = state) do
    display = editing.module.display(editing.state, Nav.ctx(state))
    context = Map.get(display, :context, :settings_edit)
    %{state | settings: %{layer | editing: %{editing | context: context}}}
  end

  defp refresh_context(state), do: state

  defp put_editing(%{settings: %Layer{} = layer} = state, editing),
    do: %{state | settings: %{layer | editing: editing, mode: :editing}}

  defp clear_error(%{settings: %Layer{} = layer} = state, row_id),
    do: %{state | settings: %{layer | row_errors: Map.delete(layer.row_errors, row_id)}}
end
