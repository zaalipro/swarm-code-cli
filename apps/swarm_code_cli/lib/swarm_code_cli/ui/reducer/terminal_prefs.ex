defmodule SwarmCodeCLI.UI.Reducer.TerminalPrefs do
  @moduledoc """
  cli020 lane D (D3, D8, D13): the `terminal.*` cli.json values the client
  itself acts on, copied from `state.prefs` (every cli.json value by json name,
  from the launcher and then from every read and write of the preferences
  queue) into typed `State` fields. A key that is missing or holds a value
  out of range leaves the field as it was (the launch default), so a
  hand-edited cli.json never breaks the session.

  | json name              | State field             | type, default            |
  | ---------------------- | ----------------------- | ------------------------ |
  | `notify`               | `notify`                | auto/bell/osc9/os/off    |
  | `title`                | `title?`                | boolean, true            |
  | `paste_collapse_lines` | `paste_collapse_lines`  | 0..200, 8                |
  | `wheel_lines`          | `wheel_lines`           | 1..10, 3                 |
  | `notice_seconds`       | `notice_ms`             | 2..30 s, 6,000 ms        |
  | `hint_letters`         | `hint_letters`          | 2..26 distinct a-z, none of `UI.Hint.forbidden/0` |
  | `reduced_motion`       | `capabilities.reduced_motion?` | boolean            |
  """

  @notify %{"auto" => :auto, "bell" => :bell, "osc9" => :osc9, "os" => :os, "off" => :off}

  @doc "Applies `state.prefs` to the typed fields when it differs from `previous`'s."
  @spec sync(map(), map() | nil) :: map()
  def sync(%{prefs: prefs} = state, %{prefs: prefs}), do: state
  def sync(state, _previous), do: apply_prefs(state, state.prefs || %{})

  @doc "Applies `prefs` (json name => value) to the typed fields."
  @spec apply_prefs(map(), map()) :: map()
  def apply_prefs(state, prefs) when is_map(prefs) do
    state
    |> put(:notify, notify(Map.get(prefs, "notify")))
    |> put(:title?, boolean(Map.get(prefs, "title")))
    |> put(:paste_collapse_lines, integer(Map.get(prefs, "paste_collapse_lines"), 0, 200))
    |> put(:wheel_lines, integer(Map.get(prefs, "wheel_lines"), 1, 10))
    |> put(:notice_ms, seconds(Map.get(prefs, "notice_seconds")))
    |> put(:hint_letters, letters(Map.get(prefs, "hint_letters")))
    |> reduced_motion(boolean(Map.get(prefs, "reduced_motion")))
  end

  def apply_prefs(state, _prefs), do: state

  defp put(state, _field, :keep), do: state
  defp put(state, field, value), do: Map.put(state, field, value)

  defp reduced_motion(state, :keep), do: state

  defp reduced_motion(%{capabilities: %{reduced_motion?: _} = caps} = state, value),
    do: %{state | capabilities: %{caps | reduced_motion?: value}}

  defp reduced_motion(state, _value), do: state

  defp notify(value) when is_binary(value), do: Map.get(@notify, value, :keep)
  defp notify(value) when is_atom(value) and value in [:auto, :bell, :osc9, :os, :off], do: value
  defp notify(_value), do: :keep

  defp boolean(value) when is_boolean(value), do: value
  defp boolean("on"), do: true
  defp boolean("off"), do: false
  defp boolean(_value), do: :keep

  defp integer(value, min, max) when is_integer(value) and value >= min and value <= max,
    do: value

  defp integer(_value, _min, _max), do: :keep

  defp seconds(value) when is_integer(value) and value >= 2 and value <= 30, do: value * 1_000
  defp seconds(_value), do: :keep

  defp letters(value) when is_binary(value) do
    letters = String.graphemes(value)

    if length(letters) in 2..26 and letters == Enum.uniq(letters) and
         Enum.all?(letters, &(&1 =~ ~r/\A[a-z]\z/)) and
         not Enum.any?(letters, &(&1 in SwarmCodeCLI.UI.Hint.forbidden())),
       do: letters,
       else: :keep
  end

  defp letters(_value), do: :keep
end
