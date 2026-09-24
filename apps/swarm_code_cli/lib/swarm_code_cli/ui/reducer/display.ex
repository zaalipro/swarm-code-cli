defmodule SwarmCodeCLI.UI.Reducer.Display do
  @moduledoc """
  pass73-K: the display preferences the user sets with a command and the
  CLI remembers in `cli.json` (`Init.Preferences`).

    * `/diff` (T1) toggles whether tool rows show their diffs, previews and
      output tails; `/diff on|off` sets it.
    * `/theme` (T2) toggles dark and light; `/theme dark|light` sets it. The
      terminal's owner repaints at once (`{:terminal_preferences, …}`).
      `SWARM_THEME` still wins at the next launch, and the confirmation says so.
    * `/mouse` (T9) toggles wheel reports; `/mouse on|off` sets them. Off
      gives the terminal its own click-and-drag selection back.

  Pure: every change returns the effects that save it and, for the theme and
  the mouse, tell the terminal's owner.
  """

  alias SwarmCodeCLI.UI.SafeText

  @on ~w(on show shown yes true 1)
  @off ~w(off hide hidden no false 0)

  @doc "Applies `{:show_diffs | :theme_mode | :mouse, value}` (`:toggle` flips it)."
  def set(state, :show_diffs, :toggle), do: set(state, :show_diffs, not state.show_diffs)

  def set(state, :show_diffs, on?) when is_boolean(on?) do
    words =
      if on?,
        do: "Diffs shown · /diff hides them",
        else: "Diffs hidden · /diff shows them"

    changed(%{state | show_diffs: on?}, words, [{:save_preferences, %{show_diffs: on?}}])
  end

  def set(state, :theme_mode, :toggle),
    do: set(state, :theme_mode, if(state.theme_mode == :light, do: :dark, else: :light))

  def set(state, :theme_mode, mode) when mode in [:dark, :light] do
    base = if mode == :light, do: "Light theme", else: "Dark theme"

    words =
      case Map.get(state, :theme_env) do
        env when env in [:dark, :light] and env != mode ->
          base <> " · SWARM_THEME=#{env} still wins at the next launch"

        _ ->
          base <> " · /theme switches back"
      end

    changed(%{state | theme_mode: mode}, words, [
      {:terminal_preferences, %{theme: mode}},
      {:save_preferences, %{theme: mode}}
    ])
  end

  def set(state, :mouse, :toggle), do: set(state, :mouse, not state.mouse?)

  def set(state, :mouse, on?) when is_boolean(on?) do
    words =
      if on?,
        do: "Wheel scrolling on · Shift- or Option-drag selects text",
        else: "Wheel scrolling off · the terminal selects text again"

    changed(%{state | mouse?: on?}, words, [
      {:terminal_preferences, %{mouse?: on?}},
      {:save_preferences, %{mouse?: on?}}
    ])
  end

  @doc """
  The slash command `/diff`, `/theme` or `/mouse` with its argument (the
  draft's text): `{:ok, field, value}` to apply, or `{:error, words}` to say
  what the command takes.
  """
  def parse(:diff, text), do: switch(argument(text, "/diff"), :show_diffs, "/diff on or off")
  def parse(:mouse, text), do: switch(argument(text, "/mouse"), :mouse, "/mouse on or off")

  def parse(:theme, text) do
    case argument(text, "/theme") do
      "" -> {:ok, :theme_mode, :toggle}
      "dark" -> {:ok, :theme_mode, :dark}
      "light" -> {:ok, :theme_mode, :light}
      _ -> {:error, "The theme is dark or light: /theme light."}
    end
  end

  @doc """
  The preferences the session read from `cli.json` after start. The launcher
  normally resolved them already, so this only changes what differs; a theme
  set by `SWARM_THEME` is left alone.
  """
  def loaded(state, loaded) do
    state =
      case Map.fetch(loaded, :show_diffs) do
        {:ok, value} -> %{state | show_diffs: value}
        :error -> state
      end

    {state, theme} =
      case Map.get(loaded, :theme) do
        mode when mode in [:dark, :light] and mode != state.theme_mode ->
          if Map.get(state, :theme_env) == nil,
            do: {%{state | theme_mode: mode}, [{:terminal_preferences, %{theme: mode}}]},
            else: {state, []}

        _ ->
          {state, []}
      end

    {state, mouse} =
      case Map.fetch(loaded, :mouse?) do
        {:ok, on?} when on? != state.mouse? ->
          {%{state | mouse?: on?}, [{:terminal_preferences, %{mouse?: on?}}]}

        _ ->
          {state, []}
      end

    {state, theme ++ mouse}
  end

  defp switch("", field, _usage), do: {:ok, field, :toggle}
  defp switch(value, field, _usage) when value in @on, do: {:ok, field, true}
  defp switch(value, field, _usage) when value in @off, do: {:ok, field, false}
  defp switch(_value, _field, usage), do: {:error, "Try #{usage}."}

  defp argument(text, command) do
    text
    |> String.trim()
    |> String.replace_prefix(command, "")
    |> String.trim()
    |> String.downcase()
  end

  defp changed(state, words, effects) do
    {:ok, safe} = SafeText.external(words, SafeText.Limits.content())
    {%{state | notice: {:command_feedback, SafeText.value(safe)}}, effects}
  end
end
