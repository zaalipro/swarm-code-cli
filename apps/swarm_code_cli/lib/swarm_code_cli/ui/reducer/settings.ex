defmodule SwarmCodeCLI.UI.Reducer.Settings do
  @moduledoc """
  The settings layer's reducer (cli74, spec §3.7): every `{:settings, event}`
  action and `{:settings_open, arg}` land here. Pure: IO happens through the
  effects the session runtime and the data source run, and their answers come
  back as `{:settings, event}` actions matched by generation and reference.

  This first part keeps `state.prefs` (every cli.json value by json name) in
  step with the file: the runtime's reads and writes answer here, and the
  legacy `/panel`, `/diff`, `/theme`, `/mouse` saves update it as they are
  made, so an open layer shows their change.
  """

  alias SwarmCodeCLI.UI.{SafeText, State}
  alias SwarmCodeCLI.UI.Init.Preferences
  alias SwarmCodeCLI.UI.Settings.Layer

  @conflict_words "cli.json changed elsewhere; /settings shows it"

  @doc "Applies one `{:settings, event}` action."
  @spec event(State.t(), term()) :: {State.t(), list()}
  def event(state, {:cli_snapshot, generation, %{values: values} = snapshot}) do
    state = %{state | prefs: values}
    {put_cli(state, generation, snapshot), []}
  end

  def event(state, {:cli_snapshot, generation, {:error, reason}}),
    do: {put_cli(state, generation, {:error, reason}), []}

  # A legacy save found the key changed in the file since the session read
  # it: the file's value stays, the shell shows it, and the user is told.
  def event(state, {:prefs_conflict, current}) when is_map(current) do
    prefs =
      Enum.reduce(current, state.prefs, fn
        {name, :absent}, acc -> Map.delete(acc, name)
        {name, value}, acc -> Map.put(acc, name, value)
      end)

    {state, effects} = apply_legacy(%{state | prefs: prefs}, Map.keys(current))
    {notice(state, @conflict_words), effects}
  end

  # A cli.json write answered: `state.prefs` follows the file it left; the
  # layer that asked (same generation) takes the outcome.
  def event(state, {:cli_result, generation, ref, result}) do
    state =
      case result do
        {:ok, %{values: values}} -> %{state | prefs: values}
        {:ok, %{values: values}, _warnings} -> %{state | prefs: values}
        _ -> state
      end

    {cli_outcome(state, generation, ref, result), []}
  end

  def event(state, {:folder_result, _generation, result}),
    do: {notice(state, folder_words(result)), []}

  def event(state, _event), do: {state, []}

  @doc """
  Keeps `state.prefs` in step with the legacy saves the reducer emits (the
  `/panel`, `/diff`, `/theme`, `/mouse` paths and the palette's toggles).
  """
  @spec track_legacy(State.t(), list()) :: State.t()
  def track_legacy(state, effects) do
    Enum.reduce(effects, state, fn
      {:save_preferences, wanted}, acc ->
        %{acc | prefs: Map.merge(acc.prefs, Preferences.changes(wanted))}

      _effect, acc ->
        acc
    end)
  end

  @doc "The words the status row shows for an open-folder answer."
  @spec folder_words(term()) :: String.t()
  def folder_words(:ok), do: "Opened the folder"

  def folder_words({:error, :no_desktop}),
    do: "No desktop to open folders here · y copies the path"

  def folder_words({:error, :missing}),
    do: "That folder does not exist yet · n creates the first file in it"

  def folder_words({:error, :busy}), do: "Still opening the last folder"
  def folder_words(_result), do: "Couldn't open the folder · y copies the path"

  defp cli_outcome(
         %{settings: %Layer{generation: generation} = layer} = state,
         generation,
         ref,
         result
       ),
       do: %{
         state
         | settings: %{layer | requests: Map.put(layer.requests, {:cli, ref}, {:done, result})}
       }

  defp cli_outcome(state, _generation, _ref, _result), do: state

  defp put_cli(%{settings: %Layer{generation: layer_generation} = layer} = state, generation, cli)
       when generation in [nil, layer_generation],
       do: %{state | settings: %{layer | data: %{layer.data | cli: cli}}}

  defp put_cli(state, _generation, _cli), do: state

  # The shell's live copies of the four legacy preferences follow the file;
  # the terminal repaints or turns wheel reports over when those moved.
  defp apply_legacy(state, names) do
    legacy = Preferences.legacy(state.prefs)

    Enum.reduce(names, {state, []}, fn
      "panel", {acc, effects} ->
        {%{acc | panel_mode: legacy.panel_mode}, effects}

      "show_diffs", {acc, effects} ->
        {%{acc | show_diffs: legacy.show_diffs}, effects}

      "mouse", {acc, effects} when acc.mouse? != legacy.mouse? ->
        {%{acc | mouse?: legacy.mouse?},
         effects ++ [{:terminal_preferences, %{mouse?: legacy.mouse?}}]}

      "theme", {%{theme_env: nil} = acc, effects}
      when legacy.theme != nil and legacy.theme != acc.theme_mode ->
        {%{acc | theme_mode: legacy.theme},
         effects ++ [{:terminal_preferences, %{theme: legacy.theme}}]}

      _name, acc ->
        acc
    end)
  end

  defp notice(%{settings: %Layer{} = layer} = state, words),
    do: %{state | settings: %{layer | status: %{text: words, role: :text_muted, at: state.now}}}

  defp notice(state, words) do
    {:ok, safe} = SafeText.external(words, SafeText.Limits.content())
    %{state | notice: {:command_feedback, SafeText.value(safe)}}
  end
end
