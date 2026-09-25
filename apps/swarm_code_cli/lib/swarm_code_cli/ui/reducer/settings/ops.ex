defmodule SwarmCodeCLI.UI.Reducer.Settings.Ops do
  @moduledoc """
  What a section's answer does (spec §3.7.2 `Op`), and the generic meaning of
  a row's keys when the section answers `:default` (§4.3 *Row letters*):
  Enter edits, Space toggles, ←/→ step an enum or a number in place, `r`
  resets, `u`/`U` undo and redo, `y` copies the key; any other letter says
  it does nothing on this row.

  Ops are run in order; each returns the state and the effects to add. Ops
  this build does not know are dropped (`Op.valid?/1`).
  """

  alias SwarmCode.Settings.{Entry, Registry}
  alias SwarmCodeCLI.UI.Keymap.{KeyName, SettingsBindings}
  alias SwarmCodeCLI.UI.Reducer.Settings.{Commit, Edit}

  alias SwarmCodeCLI.UI.Settings.{
    Editors,
    Layer,
    Nav,
    Normalize,
    Op,
    Page,
    Paste,
    Row,
    Rows,
    Sections,
    Undo
  }

  alias SwarmCodeCLI.UI.State

  @number_settle_ms 600
  @nothing_ms 2_000

  # ------------------------------------------------------------- run ops

  @doc "Runs `ops` in order."
  @spec run(map(), [term()]) :: {map(), list()}
  def run(state, ops) when is_list(ops) do
    ops
    |> Enum.map(&Normalize.op/1)
    |> Enum.reduce({state, []}, fn op, {acc, effects} ->
      if Op.valid?(op) do
        {acc, more} = one(acc, op)
        {acc, effects ++ more}
      else
        {acc, effects}
      end
    end)
  end

  def run(state, _ops), do: {state, []}

  defp one(state, {:patch, key, value}), do: Commit.patch(state, key, value, reason: :edit)
  defp one(state, {:reset, keys}), do: Commit.reset(state, keys)
  # A section's reset asks first, listing every value that changes.
  defp one(state, {:reset_section, id}) do
    ctx = Nav.ctx(state)
    title = SwarmCodeCLI.UI.Settings.Sections.title(id)

    case changed_keys(state, id) do
      [] ->
        {Commit.status(state, "Nothing to reset in #{title}", :text_muted), []}

      keys ->
        lines =
          Enum.map(keys, fn key ->
            entry = Registry.fetch!(key)

            now =
              SwarmCodeCLI.UI.Settings.Display.toast_words(
                entry,
                Rows.shown(ctx, entry, Rows.setting(ctx, entry))
              )

            back = SwarmCodeCLI.UI.Settings.Display.toast_words(entry, entry.default)
            "#{entry.label}  #{now} → #{back}"
          end)

        count = length(keys)
        noun = if count == 1, do: "value", else: "values"

        confirm = %SwarmCodeCLI.UI.Settings.Confirm{
          id: "reset_section",
          title: "Reset #{title}?",
          lines: lines,
          safe: "Keep them",
          danger: "Reset #{count} #{noun}",
          letter: "R"
        }

        one(
          state,
          {:confirm, confirm,
           then: [{:reset, keys}, {:toast, "Reset #{count} #{noun} in #{title}", :success}]}
        )
    end
  end

  defp one(state, {:toast, text, role}), do: {Commit.status(state, text, role), []}

  defp one(%{settings: layer} = state, {:open, %Page{} = page}),
    do: {state |> put_layer(Layer.push(layer, page)) |> Nav.settle(), []}

  defp one(%{settings: layer} = state, :back) do
    case Layer.pop(layer) do
      {:ok, layer} -> {state |> put_layer(layer) |> Nav.settle(), []}
      :top -> {state, []}
    end
  end

  defp one(%{settings: layer} = state, {:section, id}) do
    layer = %{layer | rail_cursor: id, stack: [Page.section(id)], mode: :browse, search: nil}
    {state |> put_layer(layer) |> Nav.settle(), []}
  end

  defp one(%{settings: layer} = state, {:confirm, confirm, then: ops}),
    do:
      {put_layer(state, %{layer | popover: {:confirm, %{confirm: confirm, then: ops, focus: 0}}}),
       []}

  defp one(%{settings: layer} = state, {:picker, picker}),
    do: {put_layer(state, %{layer | popover: {:picker, picker}}), []}

  defp one(%{settings: layer} = state, {:paste, target}),
    do: {put_layer(state, %{layer | paste: Paste.new(target), mode: :paste}), []}

  defp one(state, {:edit, row_id}), do: one(state, {:edit, row_id, %{}})

  defp one(state, {:edit, row_id, opts}) when is_binary(row_id) and is_map(opts) do
    case Enum.find(Nav.rows(state), &(&1.id == row_id)) do
      %Row{editor: {_, _}} = row -> Edit.open(Nav.put_cursor(state, row_id), row, opts)
      _ -> {state, []}
    end
  end

  # The layer remembers what the edit was of (never its content) to route
  # the text that comes back.
  defp one(%{settings: layer} = state, {:external_edit, spec}) do
    {ref, layer} = next_ref(layer)
    kept = Map.take(spec, [:ref, :fingerprint, :suffix, :name, :save])
    layer = %{layer | requests: Map.put(layer.requests, {:external, ref}, kept)}
    {put_layer(state, layer), [{:settings_external_edit, layer.generation, ref, spec}]}
  end

  defp one(%{settings: layer} = state, {:cli_write, changes}) do
    {ref, layer} = next_ref(layer)
    expected = Map.new(changes, fn {name, _} -> {name, Map.get(state.prefs, name, :absent)} end)
    write = %{ref: ref, kind: :cli_batch, names: Map.keys(changes), changes: changes}
    layer = %{layer | writes: Map.put(layer.writes, {:cli_batch, ref}, write)}
    {put_layer(state, layer), [{:settings_cli_write, layer.generation, ref, changes, expected}]}
  end

  defp one(%{settings: layer} = state, {:open_folder, path}),
    do: {state, [{:settings_open_folder, layer.generation, path}]}

  defp one(state, {:copy, text}) when text != "", do: {state, [{:copy, text}]}

  defp one(state, {:leave, then}) when is_list(then), do: run(state, then)
  defp one(state, {:leave, _then}), do: {state, []}

  defp one(%{settings: layer} = state, {:draft_put, kind, fields}) when is_map(fields) do
    drafts = Map.update(layer.drafts, kind, fields, &Map.merge(&1, fields))
    {put_layer(state, %{layer | drafts: drafts}), []}
  end

  defp one(%{settings: layer} = state, {:draft_discard, kind}),
    do: {put_layer(state, %{layer | drafts: Map.delete(layer.drafts, kind)}), []}

  defp one(%{settings: layer} = state, {:stage, target, fields}) when is_map(fields) do
    staged = Map.update(layer.staged, target, fields, &Map.merge(&1, fields))
    {put_layer(state, %{layer | staged: staged}), []}
  end

  defp one(%{settings: layer} = state, {:unstage, target, :all}),
    do: {put_layer(state, %{layer | staged: Map.delete(layer.staged, target)}), []}

  defp one(%{settings: layer} = state, {:unstage, target, fields}) when is_list(fields) do
    staged =
      case Map.get(layer.staged, target) do
        nil ->
          layer.staged

        current ->
          left = Map.drop(current, fields)

          if left == %{},
            do: Map.delete(layer.staged, target),
            else: Map.put(layer.staged, target, left)
      end

    {put_layer(state, %{layer | staged: staged}), []}
  end

  defp one(%{settings: layer} = state, {:row_error, row_id, message}),
    do: {put_layer(state, %{layer | row_errors: Map.put(layer.row_errors, row_id, message)}), []}

  defp one(%{settings: layer} = state, {:treat_secret, mark}),
    do: {put_layer(state, %{layer | treat_secret: MapSet.put(layer.treat_secret, mark)}), []}

  defp one(%{settings: layer} = state, {:conflict_discard, {:file, ref}}),
    do: {put_layer(state, %{layer | file_conflicts: Map.delete(layer.file_conflicts, ref)}), []}

  defp one(%{settings: layer} = state, {:project, project_id}),
    do: {state |> put_layer(%{layer | page_project_id: project_id}) |> Nav.settle(), []}

  # Service requests (commands, tasks, loads): `Settings.Wire`.
  defp one(state, op), do: SwarmCodeCLI.UI.Settings.Wire.op(state, op)

  # A section's reset: its writable keys whose value is not the default.
  defp changed_keys(state, section) do
    ctx = Nav.ctx(state)

    section
    |> Registry.for_section()
    |> Enum.filter(&(Entry.writable?(&1) and &1.resettable))
    |> Enum.filter(fn entry ->
      case Rows.setting(ctx, entry) do
        %{winner: winner} -> winner not in [:default, nil]
        _ -> false
      end
    end)
    |> Enum.map(& &1.key)
  end

  # --------------------------------------------------------- row verbs

  @doc """
  A key on the focused row of the page: the section's `act/3` answers
  first; `:default` runs the generic meaning.
  """
  @spec row_verb(map(), atom()) :: {map(), list()}
  def row_verb(%{settings: %Layer{}} = state, verb) do
    {state, settled} = settle_step(state, verb)
    layer = state.settings
    row = Nav.current(state)

    {state, effects} =
      case row do
        nil ->
          generic(state, nil, verb)

        %Row{} = row ->
          case Sections.act(Layer.section(layer), Nav.ctx(state), row, section_verb(row, verb)) do
            ops when is_list(ops) -> run(state, ops)
            _default -> generic(state, row, verb)
          end
      end

    {state, settled ++ effects}
  end

  # Enter is `:open_row` for the sections; ←/→ are `:step` on rows that list it.
  defp section_verb(_row, :enter), do: :open_row

  defp section_verb(%Row{keys: keys}, verb) when verb in [:left, :right, :big_left, :big_right] do
    if Enum.any?(keys, &match?({_, :step, _}, &1)), do: :step, else: verb
  end

  defp section_verb(_row, verb), do: verb

  # -- Enter
  defp generic(%{settings: layer} = state, %Row{} = row, :enter) do
    conflict = Map.get(layer.conflicts, {:value, row.key})

    cond do
      conflict != nil ->
        Commit.patch(state, row.key, conflict.mine_wire,
          reason: :edit,
          expected: conflict.theirs_wire
        )

      match?({:reset_section, _}, row.target) ->
        run(state, [row.target])

      match?({Editors.Toggle, _}, row.editor) ->
        {_, opts} = row.editor
        Edit.commit(state, row, not Map.get(opts, :value, false))

      match?({_, _}, row.editor) ->
        Edit.open(state, row)

      true ->
        {state, []}
    end
  end

  # -- Space
  defp generic(state, %Row{editor: {Editors.Toggle, opts}} = row, :toggle),
    do: Edit.commit(state, row, not Map.get(opts, :value, false))

  # -- ← → on an enum steps and writes; on a number it steps and settles.
  defp generic(state, %Row{editor: {Editors.Enum, opts}} = row, verb)
       when verb in [:left, :right] do
    value = Editors.Enum.step(opts, Map.get(opts, :value), if(verb == :left, do: -1, else: 1))
    if value == Map.get(opts, :value), do: {state, []}, else: Edit.commit(state, row, value)
  end

  defp generic(state, %Row{editor: {Editors.Number, opts}} = row, verb)
       when verb in [:left, :right, :big_left, :big_right] do
    delta = if verb in [:left, :big_left], do: -1, else: 1
    size = if verb in [:big_left, :big_right], do: :big, else: :small
    value = step_base(state, row, opts)
    stepped = Editors.Number.step(opts, value, delta, size)

    if stepped == value,
      do: {state, []},
      else: start_step(state, row, stepped)
  end

  defp generic(%{settings: layer} = state, _row, :left),
    do: {put_layer(state, %{layer | region: :rail}), []}

  # -- r
  defp generic(%{settings: layer} = state, %Row{key: key} = row, :reset) when is_binary(key) do
    case Registry.fetch(key) do
      {:ok, %Entry{resettable: true} = entry} ->
        if Entry.writable?(entry) do
          conflicts = Map.delete(layer.conflicts, {:value, key})
          state = put_layer(state, %{layer | conflicts: conflicts})
          reset_one(state, entry, row)
        else
          nothing(state, :reset)
        end

      _ ->
        nothing(state, :reset)
    end
  end

  # -- u / U
  defp generic(state, _row, :undo), do: undo(state, :undo)
  defp generic(state, _row, :redo), do: undo(state, :redo)

  # -- y copies the key (never a secret's value)
  defp generic(state, %Row{key: key}, :copy) when is_binary(key),
    do: {Commit.status(state, "Copied #{key}", :text_muted), [{:copy, key}]}

  # -- c stops the running task of the page (the only one, or the row's).
  defp generic(%{settings: layer} = state, row, :cancel_task) do
    running =
      for {id, task} <- layer.tasks,
          SwarmCodeCLI.UI.Settings.Tasks.running?(task),
          SwarmCodeCLI.UI.Settings.Tasks.cancellable?(Map.get(task, "action")),
          do: id

    case {row && row.target, running} do
      {{:task, id}, _} when is_binary(id) -> run(state, [{:cancel_task, id}])
      {_, [id]} -> run(state, [{:cancel_task, id}])
      _ -> nothing(state, :cancel_task)
    end
  end

  # -- Esc on a conflict takes theirs.
  defp generic(state, _row, :right), do: {state, []}
  defp generic(state, _row, :open_row), do: {state, []}
  defp generic(state, _row, :step), do: {state, []}
  defp generic(state, _row, verb), do: nothing(state, verb)

  # An invalid stored value (D34) is reset with the raw value as the CAS.
  defp reset_one(state, entry, _row) do
    setting = Rows.setting(Nav.ctx(state), entry)

    if (setting && Map.get(setting, :state) in [:invalid, "invalid"]) and
         not match?({:cli, _}, entry.storage) do
      Commit.patch(state, entry.key, SwarmCode.Settings.TextValue.reset_value(entry),
        reason: :reset,
        expected: Map.get(setting, :base)
      )
    else
      Commit.reset(state, [entry.key])
    end
  end

  defp nothing(state, verb) do
    words = "#{key_label(verb)} does nothing on this row"
    %{settings: layer} = state = Commit.status(state, words, :text_muted)
    {put_layer(state, %{layer | status: %{layer.status | ms: @nothing_ms}}), []}
  end

  @doc "The default key of a layer verb, as the help prints it."
  @spec key_label(atom()) :: String.t()
  def key_label(verb) do
    case Enum.find(SettingsBindings.all(), &(&1.action == {:settings, {:verb, verb}})) do
      %{keys: [key | _]} -> KeyName.format(key, :rich)
      _ -> to_string(verb)
    end
  end

  # ------------------------------------------------------------ undo

  defp undo(%{settings_history: history} = state, how) do
    popped = if how == :undo, do: Undo.pop(history), else: Undo.unpop(history)

    case popped do
      :empty ->
        {Commit.status(
           state,
           if(how == :undo, do: "Nothing to undo", else: "Nothing to redo"),
           :text_muted
         ), []}

      {step, history} ->
        state = %{state | settings_history: history}

        case if(how == :undo, do: step.inverse, else: step.redo) do
          {:patch, key, value} -> Commit.patch(state, key, value, reason: how, step: step)
          op -> run(state, [op])
        end
    end
  end

  # ------------------------------------------------- number stepping

  # The value a step starts from: the one being stepped, else the row's.
  defp step_base(%{settings: %Layer{step: %{row_id: id, value: value}}}, %Row{id: id}, _opts),
    do: value

  defp step_base(_state, _row, opts), do: Map.get(opts, :value)

  defp start_step(%{settings: layer} = state, row, value) do
    cancel = if layer.step, do: [{:cancel_timer, layer.step.timer}], else: []
    {timer, state} = State.next_id(state, :timer)
    layer = state.settings

    step = %{row_id: row.id, key: row.key, row: row, value: value, timer: timer}

    {put_layer(state, %{layer | step: step}),
     cancel ++
       [{:start_timer, timer, @number_settle_ms, {:settings, {:settle, layer.generation, timer}}}]}
  end

  @doc "The settle timer of a number step fired: its value is written."
  @spec settle(map(), non_neg_integer(), String.t()) :: {map(), list()}
  def settle(
        %{settings: %Layer{generation: generation, step: %{timer: timer}}} = state,
        generation,
        timer
      ),
      do: flush_step(state)

  def settle(state, _generation, _timer), do: {state, []}

  @doc "Writes a pending number step now (focus leaves the row, the layer closes)."
  @spec flush_step(map()) :: {map(), list()}
  def flush_step(%{settings: %Layer{step: %{} = step} = layer} = state) do
    state = put_layer(state, %{layer | step: nil})
    {state, effects} = Edit.commit(state, step.row, step.value)
    {state, [{:cancel_timer, step.timer} | effects]}
  end

  def flush_step(state), do: {state, []}

  # Any key other than another step writes a pending step first.
  defp settle_step(%{settings: %Layer{step: %{}}} = state, verb)
       when verb not in [:left, :right, :big_left, :big_right],
       do: flush_step(state)

  defp settle_step(state, _verb), do: {state, []}

  # ----------------------------------------------------------- helpers

  defp next_ref(%Layer{next_ref: ref} = layer), do: {ref, %{layer | next_ref: ref + 1}}
  defp put_layer(state, layer), do: %{state | settings: layer}
end
