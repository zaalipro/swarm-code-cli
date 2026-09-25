defmodule SwarmCodeCLI.UI.Settings.Editors.Toggle do
  @moduledoc """
  A toggle (spec §3.7.8): Space, Enter, ← or → flips it and writes at once;
  there is nothing to type. Opts: `value` (boolean), `on`/`off` words
  (default `on`/`off`).
  """

  @behaviour SwarmCodeCLI.UI.Settings.Editor

  @impl true
  def init(_row, opts, _ctx) do
    {:ok,
     %{
       value: Map.get(opts, :value) == true,
       on: Map.get(opts, :on, "on"),
       off: Map.get(opts, :off, "off")
     }}
  end

  @impl true
  def handle(state, {:key, key}, _ctx) when key in [:space, :enter, :left, :right],
    do: {:commit, not state.value, %{state | value: not state.value}}

  def handle(state, {:text, " "}, ctx), do: handle(state, {:key, :space}, ctx)
  def handle(state, {:key, :escape}, _ctx), do: {:cancel, state}
  def handle(state, _event, _ctx), do: {:cont, state}

  @impl true
  def display(state, _ctx) do
    %{
      value: [{if(state.value, do: state.on, else: state.off), :text_primary}],
      lines: [],
      popover: nil,
      context: :settings,
      footer: [{"Space", "switch"}]
    }
  end

  @doc "The words of a toggle's value."
  @spec words(boolean(), map()) :: String.t()
  def words(value, opts \\ %{}),
    do: if(value == true, do: Map.get(opts, :on, "on"), else: Map.get(opts, :off, "off"))
end
