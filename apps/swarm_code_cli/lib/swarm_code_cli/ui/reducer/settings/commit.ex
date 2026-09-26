defmodule SwarmCodeCLI.UI.Reducer.Settings.Commit do
  @moduledoc """
  The settings layer's commit path (spec §3.7.6): a value written from an
  editor, a step, a reset, an undo or a redo.

    * **One write in flight per write key.** A second value for the same
      key while one is in flight becomes its `queued` value; it is sent when
      the first answers `accepted` (with `expected` = the value the first
      stored), and dropped (named in the status, or kept as *mine* in the
      conflict row) when the first fails.
    * The row shows the new value at once; after 300 ms without an answer
      its tag reads `saving…` (a timer).
    * Terminal (`:cli`) keys go to the session runtime
      (`{:settings_cli_write, generation, ref, changes, expected}`); the
      answer comes back as `{:settings, {:cli_result, …}}`. Daemon keys go
      through `Settings.Wire` (the service's `settings.command`).
    * `accepted` → toast, undo step, changelog, live consumers (§3.8.5);
      `unchanged` → nothing; `conflict` → the conflict row (§3.7.9);
      `rejected` → `✗ <message>` under the row and the status.

  Pure: writes happen through the effects this returns.
  """

  alias SwarmCode.Settings.{CliFile, Entry, Registry}
  alias SwarmCodeCLI.UI.Keymap.Overrides
  alias SwarmCodeCLI.UI.Layout.Preferences, as: LayoutPreferences
  alias SwarmCodeCLI.UI.Init.Preferences
  alias SwarmCodeCLI.UI.Settings.{Data, Display, Layer, Nav, Provenance, Rows, Undo, Wire}
  alias SwarmCodeCLI.UI.Vim
  alias SwarmCodeCLI.UI.State

  @saving_ms 300
  @toast_ms 4_000
  @error_ms 6_000

  @doc "How long a toast stays: 4 s, 6 s for an error."
  def toast_ms(:error), do: @error_ms
  def toast_ms(_role), do: @toast_ms

  # ------------------------------------------------------------- writes

  @doc """
  Writes `value` to registry key `key`. `opts`: `:reason` (`:edit`,
  `:reset`, `:undo`, `:redo`, `:step`), `:step` (the undo step an undo or
  redo re-sends), `:expected` (a CAS value other than the stored one: a
  conflict's *theirs*, an invalid raw).
  """
  @spec patch(State.t(), String.t(), term(), keyword()) :: {State.t(), list()}
  def patch(%{settings: %Layer{}} = state, key, value, opts \\ []) do
    case Registry.fetch(key) do
      {:ok, %Entry{} = entry} ->
        state = clear_row(state, "key:" <> key)
        write(state, entry, cli_value(entry, value), opts)

      :error ->
        {status(state, "Couldn't save: that setting is not known here", :error), []}
    end
  end

  # A nil commit on a nullable terminal key removes it from cli.json.
  defp cli_value(%Entry{storage: {:cli, _}, nullable: true}, nil), do: :remove
  defp cli_value(%Entry{storage: {:cli, _}}, :absent), do: :remove
  defp cli_value(_entry, value), do: value

  @doc """
  `Couldn't save: <words>`, once: the service's messages may already say it
  (QA F-11: `Couldn't save: Couldn't save: name can't be blank`).
  """
  @spec couldnt_save(String.t()) :: String.t()
  def couldnt_save("Couldn't save" <> _ = words), do: words
  def couldnt_save(words), do: "Couldn't save: " <> words

  @doc "Resets registry keys to their defaults (terminal keys are removed from cli.json)."
  @spec reset(State.t(), [String.t()]) :: {State.t(), list()}
  def reset(state, keys) do
    Enum.reduce(keys, {state, []}, fn key, {acc, effects} ->
      case Registry.fetch(key) do
        {:ok, %Entry{storage: {:cli, _}} = entry} ->
          {acc, more} = write(acc, entry, :remove, reason: :reset)
          {acc, effects ++ more}

        {:ok, %Entry{} = entry} ->
          {acc, more} =
            write(acc, entry, SwarmCode.Settings.TextValue.reset_value(entry), reason: :reset)

          {acc, effects ++ more}

        :error ->
          {acc, effects}
      end
    end)
  end

  defp write(%{settings: %Layer{} = layer} = state, entry, value, opts) do
    key = Rows.write_key(entry)

    case Map.get(layer.writes, key) do
      %{} = inflight ->
        writes =
          Map.put(layer.writes, key, %{
            inflight
            | queued: {value, opts},
              value: shown(state, entry, value)
          })

        {put_layer(state, %{layer | writes: writes, conflicts: Map.delete(layer.conflicts, key)}),
         []}

      nil ->
        send_write(state, entry, value, opts)
    end
  end

  defp send_write(
         %{settings: %Layer{} = layer} = state,
         %Entry{storage: {:cli, name}} = entry,
         value,
         opts
       ) do
    {ref, layer} = next_ref(layer)
    expected = Keyword.get(opts, :expected, Map.get(state.prefs, name, :absent))
    old = current(state, entry)

    write = %{
      ref: ref,
      kind: :cli,
      key: entry.key,
      name: name,
      sent: value,
      value: shown(state, entry, value),
      old: old,
      expected: expected,
      saving?: false,
      queued: nil,
      reason: Keyword.get(opts, :reason, :edit),
      step: Keyword.get(opts, :step)
    }

    layer = %{
      layer
      | writes: Map.put(layer.writes, Rows.write_key(entry), write),
        conflicts: Map.delete(layer.conflicts, Rows.write_key(entry))
    }

    {timer, state} = saving_timer(put_layer(state, layer), ref)

    {state,
     [{:settings_cli_write, layer.generation, ref, %{name => value}, %{name => expected}}, timer]}
  end

  defp send_write(%{settings: %Layer{} = layer} = state, %Entry{} = entry, value, opts) do
    {ref, layer} = next_ref(layer)
    setting = Map.get(layer.data.values, entry.key)
    expected = Keyword.get(opts, :expected, setting && Map.get(setting, :base))
    expected = if expected == :absent, do: nil, else: expected
    old = current(state, entry)

    change = %{"key" => entry.key, "value" => value, "target" => change_target(state, entry)}

    params = %{
      "action" => "values.patch",
      "target" => nil,
      "attributes" => %{"changes" => [change]},
      "expected" => %{entry.key => wire_expected(expected)}
    }

    case Wire.command(put_layer(state, layer), params, %{kind: :write, write_ref: ref}) do
      {:error, words, state} ->
        {status(state, couldnt_save(words), :error), []}

      {state, effects} ->
        write = %{
          ref: ref,
          kind: :daemon,
          key: entry.key,
          name: nil,
          sent: value,
          value: value,
          old: old,
          expected: expected,
          saving?: false,
          queued: nil,
          reason: Keyword.get(opts, :reason, :edit),
          step: Keyword.get(opts, :step)
        }

        layer = state.settings

        layer = %{
          layer
          | writes: Map.put(layer.writes, Rows.write_key(entry), write),
            conflicts: Map.delete(layer.conflicts, Rows.write_key(entry))
        }

        {timer, state} = saving_timer(put_layer(state, layer), ref)
        {state, effects ++ [timer]}
    end
  end

  # Session keys name the session's conversation; project keys the page's project.
  defp change_target(state, %Entry{scope: :session}),
    do: %{"conversation_id" => state.settings.data.conversation_id}

  defp change_target(state, %Entry{scope: :project}),
    do: %{"project_id" => Wire.project_id(state)}

  defp change_target(_state, _entry), do: %{}

  # A value never read (nil base) is written unconditionally.
  defp wire_expected(nil), do: %{"$any" => true}
  defp wire_expected(expected), do: expected

  @doc """
  A daemon value write answered (`DTO.SettingsResult`, or the words of a
  failed request): the write `write_ref` takes its outcome.
  """
  @spec daemon_result(State.t(), pos_integer(), term()) :: {State.t(), list()}
  def daemon_result(%{settings: %Layer{} = layer} = state, write_ref, result) do
    case find(layer, write_ref) do
      {key, write} ->
        layer = %{layer | writes: Map.delete(layer.writes, key)}
        outcome(put_layer(state, layer), key, write, daemon_outcome(result, write))

      nil ->
        {state, []}
    end
  end

  def daemon_result(state, _write_ref, _result), do: {state, []}

  defp daemon_outcome({:failed, words}, _write), do: {:failed, words}

  defp daemon_outcome(%{status: :accepted} = result, write),
    do: if(row(result, write) == :unchanged, do: :unchanged, else: :accepted)

  defp daemon_outcome(%{status: :unchanged}, _write), do: :unchanged

  defp daemon_outcome(%{status: :conflict} = result, write) do
    current =
      case Enum.find(result.results || [], &(Map.get(&1, :target) == write.key)) do
        %{current: current} -> current
        _ -> nil
      end

    {:conflict, current}
  end

  defp daemon_outcome(%{status: :rejected} = result, write) do
    message =
      case Enum.find(result.results || [], &(Map.get(&1, :target) == write.key)) do
        %{message: message} when is_binary(message) -> message
        _ -> result.message || "is invalid"
      end

    {:rejected, message}
  end

  defp daemon_outcome(%{corrective_action: :refresh}, _write),
    do: {:failed, "Couldn't tell whether that was saved; reloading."}

  defp daemon_outcome(result, _write),
    do: {:failed, Map.get(result, :message) || "the service could not save it"}

  defp row(result, write) do
    case Enum.find(result.results || [], &(Map.get(&1, :target) == write.key)) do
      %{status: :unchanged} -> :unchanged
      _ -> :accepted
    end
  end

  defp saving_timer(%{settings: %Layer{generation: generation}} = state, ref) do
    {id, state} = State.next_id(state, :timer)
    {{:start_timer, id, @saving_ms, {:settings, {:saving, generation, ref}}}, state}
  end

  @doc "300 ms passed without an answer: the row's tag reads `saving…`."
  @spec saving(State.t(), non_neg_integer(), pos_integer()) :: State.t()
  def saving(%{settings: %Layer{generation: generation} = layer} = state, generation, ref) do
    case find(layer, ref) do
      {key, write} ->
        put_layer(state, %{layer | writes: Map.put(layer.writes, key, %{write | saving?: true})})

      nil ->
        state
    end
  end

  def saving(state, _generation, _ref), do: state

  # --------------------------------------------------------- outcomes

  @doc "A cli.json write answered (the runtime's `{:settings_cli_result, …}`)."
  @spec cli_result(State.t(), non_neg_integer(), pos_integer(), term()) :: {State.t(), list()}
  def cli_result(
        %{settings: %Layer{generation: generation} = layer} = state,
        generation,
        ref,
        result
      ) do
    case find(layer, ref) do
      {key, write} ->
        layer = %{layer | writes: Map.delete(layer.writes, key)}
        outcome(put_layer(state, layer), key, write, cli_outcome(result, write))

      nil ->
        {state, []}
    end
  end

  def cli_result(state, _generation, _ref, _result), do: {state, []}

  defp cli_outcome({:ok, _snapshot}, write), do: accepted(write)
  defp cli_outcome({:ok, _snapshot, _warnings}, write), do: accepted(write)

  defp cli_outcome({:conflict, current}, write),
    do: {:conflict, Map.get(current, write.name, :absent)}

  defp cli_outcome({:error, :invalid, messages}, write),
    do:
      {:rejected,
       Map.get(messages, write.name) || messages |> Map.values() |> List.first() || "is invalid"}

  defp cli_outcome({:error, reason}, _write), do: {:failed, cli_words(reason)}

  @doc """
  Why a cli.json write did not happen, in words that follow "Couldn't save: "
  (a session without a cli.json — the demo, a test — says so).
  """
  @spec cli_words(term()) :: String.t()
  def cli_words(:unavailable), do: "this session keeps no cli.json (a demo or a test session)"

  def cli_words(reason) when reason in [:symlink, :busy, :too_large, :not_json, :unreadable],
    do: CliFile.words(reason)

  def cli_words(reason) when is_atom(reason), do: "cli.json could not be written (#{reason})"
  def cli_words(_reason), do: "cli.json could not be written"

  defp accepted(%{sent: sent, expected: expected}) do
    if sent == expected or (sent == :remove and expected == :absent),
      do: :unchanged,
      else: :accepted
  end

  @doc """
  Applies the outcome of the write `write` (already removed from the
  layer): `:accepted | :unchanged | {:conflict, theirs} | {:rejected,
  message} | {:failed, words}`.
  """
  @spec outcome(State.t(), term(), map(), term()) :: {State.t(), list()}
  def outcome(state, key, write, :unchanged) do
    state = settled(state, Registry.fetch!(write.key), write.sent)
    send_queued(state, key, write, write.sent)
  end

  def outcome(state, key, write, :accepted) do
    entry = Registry.fetch!(write.key)
    state = settled(state, entry, write.sent)
    {state, live} = live(state, entry)
    state = state |> history(entry, write) |> next_launch(entry) |> toast(entry, write)
    {state, queued} = send_queued(state, key, write, write.sent)
    {state, live ++ queued}
  end

  def outcome(%{settings: layer} = state, key, write, {:conflict, theirs}) do
    mine =
      case write.queued do
        {value, _opts} -> value
        nil -> write.sent
      end

    entry = Registry.fetch!(write.key)

    conflict = %{
      mine: display_value(state, entry, mine),
      theirs: display_value(state, entry, theirs),
      mine_wire: mine,
      theirs_wire: theirs,
      origin: "elsewhere in this session"
    }

    state = restore_step(state, write)
    {put_layer(state, %{layer | conflicts: Map.put(layer.conflicts, key, conflict)}), []}
  end

  def outcome(%{settings: layer} = state, _key, write, {:rejected, message}) do
    entry = Registry.fetch!(write.key)
    row = "key:" <> write.key
    layer = %{layer | row_errors: Map.put(layer.row_errors, row, message)}
    state = state |> put_layer(layer) |> restore_step(write)
    {status(state, couldnt_save(message) <> dropped(entry, write), :error), []}
  end

  def outcome(state, _key, write, {:failed, words}) do
    entry = Registry.fetch!(write.key)
    state = restore_step(state, write)
    {status(state, couldnt_save(words) <> dropped(entry, write), :error), []}
  end

  # A daemon write the service accepted is what its home layer now holds:
  # the row's base (the next write's `expected`) and, unless a stronger layer
  # wins, its value — at once, not when the re-read arrives (a second change
  # of the same key made meanwhile must not conflict with the first).
  defp settled(%{settings: %Layer{data: data} = layer} = state, %Entry{} = entry, sent) do
    case Map.get(data.values, entry.key) do
      %{} = setting when entry.home not in [:cli, nil] and sent != :remove ->
        home = entry.home

        layers =
          Enum.map(Map.get(setting, :layers) || [], fn
            %{layer: ^home} = l -> %{l | value: sent, set: true}
            l -> l
          end)

        wins? = Map.get(setting, :winner) in [home, :default, nil]

        setting = %{
          setting
          | base: sent,
            layers: layers,
            value: if(wins?, do: sent, else: setting.value),
            winner: if(wins?, do: home, else: setting.winner),
            state: if(wins?, do: :ok, else: setting.state)
        }

        values = Map.put(data.values, entry.key, setting)
        put_layer(state, %{layer | data: %{data | values: values}})

      _ ->
        state
    end
  end

  defp settled(state, _entry, _sent), do: state

  defp dropped(_entry, %{queued: nil}), do: ""
  defp dropped(entry, _write), do: "; your later change to #{entry.label} was not sent"

  defp send_queued(state, _key, %{queued: nil}, _stored), do: {state, []}

  defp send_queued(state, _key, %{queued: {value, opts}} = write, stored) do
    entry = Registry.fetch!(write.key)
    expected = if stored == :remove, do: :absent, else: stored
    send_write(state, entry, value, Keyword.put(opts, :expected, expected))
  end

  # A failed undo or redo puts its step back where it was.
  defp restore_step(%{settings_history: history} = state, %{reason: reason, step: step})
       when reason in [:undo, :redo] and is_map(step),
       do: %{state | settings_history: Undo.restore(history, step, reason)}

  defp restore_step(state, _write), do: state

  # ----------------------------------------------------- undo and toasts

  defp history(%{settings_history: history} = state, entry, write) do
    new_words = display_value(state, entry, write.sent)
    old_words = Display.toast_words(entry, write.old)

    history =
      case write.reason do
        reason when reason in [:undo, :redo] ->
          history

        _other ->
          Undo.push(history, %{
            write_key: Rows.write_key(entry),
            label: entry.label,
            old: old_words,
            new: new_words,
            inverse: {:patch, entry.key, undo_value(entry, write)},
            redo: {:patch, entry.key, write.sent}
          })
      end

    %{state | settings_history: history}
  end

  # The value an undo writes back: a terminal key that was absent is removed again.
  defp undo_value(%Entry{storage: {:cli, _}}, %{expected: :absent}), do: :absent
  defp undo_value(%Entry{storage: {:cli, _}}, %{expected: expected}), do: expected
  defp undo_value(_entry, %{old: old}), do: old

  defp next_launch(%{settings: layer} = state, %Entry{applies: :next_launch} = entry),
    do: put_layer(state, %{layer | next_launch: MapSet.put(layer.next_launch, entry.key)})

  defp next_launch(state, _entry), do: state

  defp toast(state, entry, write) do
    words = display_value(state, entry, write.sent)

    text =
      case write.reason do
        :undo -> "Undid: #{entry.label} #{Display.toast_words(entry, write.old)} → #{words}"
        :redo -> "Redid: #{entry.label} #{Display.toast_words(entry, write.old)} → #{words}"
        :reset -> "#{entry.label} back to #{words}"
        _ -> "#{entry.label} → #{words}"
      end

    text = text <> still_wins(state, entry) <> applies(entry)
    history = Undo.log(state.settings_history, state.now, text, key: entry.key)
    status(%{state | settings_history: history}, text, :success)
  end

  defp still_wins(state, entry) do
    setting = Rows.setting(Nav.ctx(state), entry)

    case setting && Provenance.overrides(setting, entry) do
      [layer | _] ->
        home = if entry.home == :cli, do: "cli.json", else: Provenance.word(entry.home)
        " · saved to #{home} · #{Map.get(layer, :source)}=#{Map.get(layer, :raw)} still wins"

      _ ->
        ""
    end
  end

  defp applies(%Entry{applies: :next_launch}), do: " · applies at the next launch"
  defp applies(%Entry{applies: :at_once}), do: ""
  defp applies(%Entry{applies: :desktop}), do: ""
  defp applies(%Entry{applies: applies}), do: " · " <> Rows.applies_words(applies)

  @doc "Puts `text` on the layer's status row (a toast) with `role`."
  @spec status(State.t(), String.t(), atom()) :: State.t()
  def status(%{settings: %Layer{} = layer} = state, text, role),
    do:
      put_layer(state, %{
        layer
        | status: %{text: text, role: role, at: state.now, ms: toast_ms(role)}
      })

  def status(state, _text, _role), do: state

  # ---------------------------------------------------- live consumers

  @doc """
  The shell follows a terminal key that was just written (§3.8.5): the
  live copies in the state, and the terminal's own preferences.
  """
  @spec live(State.t(), Entry.t()) :: {State.t(), list()}
  def live(state, %Entry{storage: {:cli, name}}), do: apply_names(state, [name])
  def live(state, _entry), do: {state, []}

  @doc "Applies the live consumers of the json names `names` from `state.prefs`."
  @spec apply_names(State.t(), [String.t()]) :: {State.t(), list()}
  def apply_names(state, names) do
    legacy = Preferences.legacy(state.prefs)
    Enum.reduce(names, {state, []}, &consume(&1, &2, legacy))
  end

  defp consume("panel", {state, effects}, legacy),
    do: {%{state | panel_mode: legacy.panel_mode}, effects}

  defp consume("show_diffs", {state, effects}, legacy),
    do: {%{state | show_diffs: legacy.show_diffs}, effects}

  defp consume("mouse", {state, effects}, legacy) do
    if env?(state, "terminal.mouse") or state.mouse? == legacy.mouse?,
      do: {state, effects},
      else:
        {%{state | mouse?: legacy.mouse?},
         effects ++ [{:terminal_preferences, %{mouse?: legacy.mouse?}}]}
  end

  defp consume("theme", {%{theme_env: nil} = state, effects}, legacy) do
    mode = legacy.theme || follow_mode(state)

    if mode == state.theme_mode,
      do: {state, effects},
      else: {%{state | theme_mode: mode}, effects ++ [{:terminal_preferences, %{theme: mode}}]}
  end

  defp consume("keymap", {state, effects}, _legacy) do
    keymap = if Map.get(state.prefs, "keymap") == "vim", do: :vim, else: :default

    cond do
      env?(state, "terminal.keymap") -> {state, effects}
      keymap == state.keymap -> {state, effects}
      true -> {%{state | keymap: keymap, vim: %Vim{}}, effects}
    end
  end

  defp consume("composer_rows", {state, effects}, _legacy) do
    height = state.prefs |> Map.get("composer_rows", 3) |> clamp(1, 8)

    {%{
       state
       | composer_height: height,
         preferences: %{state.preferences | composer_height: height}
     }, effects}
  end

  defp consume("inspector_width", {state, effects}, _legacy) do
    preset =
      case Map.get(state.prefs, "inspector_width") do
        "compact" -> :compact
        "wide" -> :wide
        _ -> :balanced
      end

    {%{state | preferences: LayoutPreferences.preset(state.preferences, :inspector, preset)},
     effects}
  end

  defp consume("keys", {state, effects}, _legacy),
    do: {%{state | key_overrides: Overrides.compile(Map.get(state.prefs, "keys"))}, effects}

  # notice_seconds, wheel_lines, editor, hint_letters and diff_lines are read
  # from `state.prefs` where they are used; the rest apply at the next launch.
  defp consume(_name, acc, _legacy), do: acc

  defp clamp(value, low, high) when is_integer(value), do: value |> max(low) |> min(high)
  defp clamp(_value, low, _high), do: low

  # `follow`: the desktop's mode when the layer has read it, else dark.
  defp follow_mode(%{settings: %Layer{data: %{values: values}}}) do
    case Map.get(values, "desktop.mode") do
      %{value: "light"} -> :light
      _ -> :dark
    end
  end

  defp follow_mode(_state), do: :dark

  defp env?(state, key) do
    case state.launch_facts |> get(:env_overrides) |> get_key(key) do
      %{} = override -> get(override, :ignored) != true
      _ -> false
    end
  end

  defp get(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp get(_map, _key), do: nil
  defp get_key(map, key) when is_map(map), do: Map.get(map, key)
  defp get_key(_map, _key), do: nil

  # ----------------------------------------------------------- helpers

  defp next_ref(%Layer{next_ref: ref} = layer), do: {ref, %{layer | next_ref: ref + 1}}

  defp find(%Layer{writes: writes}, ref),
    do: Enum.find(writes, fn {_key, write} -> write.ref == ref end)

  # What the row shows for a value being written (a removed terminal key
  # shows what wins without it).
  defp shown(state, %Entry{storage: {:cli, name}} = entry, :remove) do
    layer = state.settings

    Provenance.cli_value(
      entry,
      Map.delete(state.prefs, name),
      Data.cli_invalid(layer.data) -- [name],
      state.launch_facts,
      layer.data.values
    ).value
  end

  defp shown(_state, _entry, value), do: value

  defp display_value(state, entry, value),
    do: Display.toast_words(entry, shown(state, entry, normal(value)))

  defp normal(:absent), do: :remove
  defp normal(value), do: value

  defp current(state, entry) do
    ctx = Nav.ctx(state)
    Rows.shown(ctx, entry, Rows.setting(ctx, entry))
  end

  defp clear_row(%{settings: %Layer{} = layer} = state, row),
    do: put_layer(state, %{layer | row_errors: Map.delete(layer.row_errors, row)})

  defp put_layer(state, layer), do: %{state | settings: layer}
end
