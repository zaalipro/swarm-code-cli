defmodule SwarmCodeCLI.UI.Keymap.Layers do
  @moduledoc """
  cli020 lane D: the keys of the layers D opens and E draws (§8.3):
  `{:rewind, …}`, `{:rewind_confirm, turn}` (D10), `{:effort_picker, …}`
  (D18), `{:history_search, …}` (D19) and `{:queue_list}` (D20). A key a
  layer does not take answers `:pass` and goes through the binding table
  as usual (Esc closes the top layer, Ctrl-C interrupts).
  """

  alias SwarmCodeCLI.UI.Keymap

  @doc "The action for `code`/`mods` over the top layer, or `:pass`."
  @spec key(term(), [atom()], map()) :: {:ok, term()} | :ignore | :pass
  def key(:enter, [], %{layers: [{:effort_picker, _} | _]} = state), do: enter(state)
  def key(code, mods, %{layers: [layer | _]}), do: layer_key(layer, code, mods)

  # fix round U7: Alt-← goes back from the composer too, while the draft is
  # empty (a word move has nothing to move over then): the previous place, or
  # from a run view that was opened first, the run's conversation.
  def key(:left, [:alt], %{layers: []} = state) do
    with :composer <- Keymap.Context.of(state),
         "" <- String.trim(Keymap.draft_text(state)),
         {:ok, action} <- back_action(state) do
      Keymap.result(action)
    else
      _ -> :pass
    end
  end

  def key(_code, _mods, _state), do: :pass

  defp back_action(%{history: [_ | _]}), do: {:ok, :back}

  defp back_action(%{destination: {:run, id}} = state) do
    case Map.get(state.read_model.runs, id) do
      %{conversation_id: conversation} when is_binary(conversation) ->
        {:ok, {:navigate, {:conversation, conversation}}}

      _ ->
        :error
    end
  end

  defp back_action(_state), do: :error

  # D10: the list of turns.
  defp layer_key({:rewind, _}, :up, []), do: Keymap.result({:rewind_move, -1})
  defp layer_key({:rewind, _}, :down, []), do: Keymap.result({:rewind_move, 1})
  defp layer_key({:rewind, _}, :enter, []), do: Keymap.result({:rewind_open})

  # D10: the confirm's three choices.
  defp layer_key({:rewind_confirm, _}, code, []) when code in [:enter, "b"],
    do: Keymap.result({:rewind_choose, :both})

  defp layer_key({:rewind_confirm, _}, "c", []),
    do: Keymap.result({:rewind_choose, :conversation})

  defp layer_key({:rewind_confirm, _}, "f", []), do: Keymap.result({:rewind_choose, :files})

  # D19: the history search's query and rows.
  defp layer_key({:history_search, _}, :up, []), do: Keymap.result({:history_move, -1})
  defp layer_key({:history_search, _}, :down, []), do: Keymap.result({:history_move, 1})
  defp layer_key({:history_search, _}, :enter, []), do: Keymap.result({:history_pick})

  defp layer_key({:history_search, _}, :backspace, []),
    do: Keymap.result({:history_query, :backspace})

  defp layer_key({:history_search, _}, code, mods)
       when is_binary(code) and mods in [[], [:shift]],
       do: Keymap.result({:history_query, {:append, code}})

  # D20: the queue list.
  defp layer_key({:queue_list}, :up, []), do: Keymap.result({:queue_move, -1})
  defp layer_key({:queue_list}, :down, []), do: Keymap.result({:queue_move, 1})
  defp layer_key({:queue_list}, "d", []), do: Keymap.result({:queue_drop})
  defp layer_key({:queue_list}, :enter, []), do: Keymap.result({:queue_take})

  # D18: the effort picker's rows.
  defp layer_key({:effort_picker, _}, :up, []), do: Keymap.result({:effort_move, -1})
  defp layer_key({:effort_picker, _}, :down, []), do: Keymap.result({:effort_move, 1})

  defp layer_key(_layer, _code, _mods), do: :pass

  @doc false
  # Enter needs the level under the cursor, so it reads the state.
  def enter(%{layers: [{:effort_picker, target} | _]} = state) do
    case SwarmCodeCLI.UI.Reducer.EffortPicker.selected(state, target) do
      level when is_binary(level) -> Keymap.result({:effort_pick, level})
      _ -> :ignore
    end
  end
end
