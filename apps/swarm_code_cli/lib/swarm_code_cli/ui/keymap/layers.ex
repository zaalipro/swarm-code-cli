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
  def key(code, mods, %{layers: [layer | _]}), do: layer_key(layer, code, mods)
  def key(_code, _mods, _state), do: :pass

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

  defp layer_key(_layer, _code, _mods), do: :pass
end
