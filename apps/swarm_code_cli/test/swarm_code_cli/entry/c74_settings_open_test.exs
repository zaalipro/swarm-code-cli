defmodule SwarmCodeCLI.Release.C74SettingsOpenTest do
  @moduledoc """
  pass74 S1-13: the query `swarmcode settings` hands the reducer. Outside
  settings mode there is none; inside it is trimmed, and a query the reducer
  would refuse (over 200 bytes, a control character) opens the Overview.
  """
  use ExUnit.Case, async: false

  alias SwarmCodeCLI.Release.PersistedSession

  setup do
    saved = Map.new(~w(SWARM_SETTINGS_OPEN SWARM_SETTINGS_ONLY), &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)
  end

  defp open(only, query) do
    if only,
      do: System.put_env("SWARM_SETTINGS_ONLY", only),
      else: System.delete_env("SWARM_SETTINGS_ONLY")

    if query,
      do: System.put_env("SWARM_SETTINGS_OPEN", query),
      else: System.delete_env("SWARM_SETTINGS_OPEN")

    PersistedSession.settings_open()
  end

  test "no query outside settings mode; the Overview when none is given" do
    assert open(nil, "providers") == nil
    assert open("0", "providers") == nil
    assert open("1", nil) == ""
    assert open("1", "") == ""
  end

  test "a query is trimmed; one the reducer would refuse opens the Overview" do
    assert open("1", "  models effort ") == "models effort"
    assert open("1", String.duplicate("é", 100)) == String.duplicate("é", 100)
    assert open("1", String.duplicate("é", 100) <> "x") == ""
    assert open("1", "tav\eily") == ""
    assert open("1", "tav\u0085ily") == ""
  end
end
