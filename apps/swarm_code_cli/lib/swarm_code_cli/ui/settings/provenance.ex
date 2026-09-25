defmodule SwarmCodeCLI.UI.Settings.Provenance do
  @moduledoc """
  Where a setting's value comes from (spec §3.8.3). The daemon resolves the
  layers of its own settings (a `SettingValue` per key); the client composes
  the value of a terminal (`:cli`) entry itself from cli.json, the launch's
  environment and flags, the desktop's mode (`terminal.theme` follows
  `desktop.mode`) and the registry default.

  A SettingValue here is a map with the DTO's fields (`key, value, layers,
  winner, writable, base, choices, state, note`); a layer is `%{layer, value,
  set, ignored, raw, source, note}`. An env or flag override the launch could
  not use (`SWARM_KEYMAP=emacs`) is an ignored layer and never the winner.
  """

  alias SwarmCode.Settings.{Entry, TextValue, Validate}

  @words %{
    flag: "flag",
    env: "env",
    session: "this conversation",
    project: "project",
    cli: "cli.json",
    global: "global",
    project_file: "config.json",
    default: "default"
  }

  @doc "The word a layer is named by on a row's tag and in the detail."
  @spec word(atom()) :: String.t()
  def word(layer), do: Map.get(@words, layer, to_string(layer))

  @doc """
  The SettingValue of a `:cli` entry: `cli_values` (json name => value) from
  cli.json, `invalid` the json names present with a bad value, `launch_facts`
  the launch's env and flag overrides, `values` the daemon's SettingValues
  (for `follows`).
  """
  @spec cli_value(Entry.t(), map(), [String.t()], map(), map()) :: map()
  def cli_value(%Entry{storage: {:cli, name}} = entry, cli_values, invalid, launch_facts, values) do
    layers =
      entry.layers
      |> Enum.map(&layer(&1, entry, name, cli_values, launch_facts, values))
      |> Enum.reject(&is_nil/1)

    winner = Enum.find(layers, &(&1.set and not &1.ignored))

    state =
      cond do
        name in invalid -> :invalid
        true -> :ok
      end

    %{
      key: entry.key,
      value: if(winner, do: winner.value, else: entry.default),
      layers: layers,
      winner: if(winner, do: winner.layer, else: :default),
      writable: [:cli],
      base: Map.get(cli_values, name, :absent),
      choices: nil,
      state: state,
      note: nil
    }
  end

  defp layer(:flag, entry, _name, _cli, facts, _values),
    do: override(:flag, entry, facts |> get(:flag_overrides) |> named(entry.key), :flag)

  defp layer(:env, entry, _name, _cli, facts, _values),
    do: override(:env, entry, facts |> get(:env_overrides) |> named(entry.key), :var)

  defp layer(:cli, _entry, name, cli, _facts, _values) do
    case Map.fetch(cli, name) do
      {:ok, value} ->
        %{
          layer: :cli,
          value: value,
          set: true,
          ignored: false,
          raw: nil,
          source: ~s(cli.json "#{name}"),
          note: nil
        }

      :error ->
        %{
          layer: :cli,
          value: nil,
          set: false,
          ignored: false,
          raw: nil,
          source: ~s(cli.json "#{name}"),
          note: nil
        }
    end
  end

  # `terminal.theme` follows the desktop's mode when cli.json names none.
  defp layer(:global, %Entry{follows: follows}, _name, _cli, _facts, values)
       when is_binary(follows) do
    case Map.get(values || %{}, follows) do
      nil ->
        nil

      setting ->
        value = Map.get(setting, :value)

        %{
          layer: :global,
          value: value,
          set: not is_nil(value),
          ignored: false,
          raw: nil,
          source: follows,
          note: nil
        }
    end
  end

  defp layer(:default, entry, _name, _cli, _facts, _values),
    do: %{
      layer: :default,
      value: entry.default,
      set: true,
      ignored: false,
      raw: nil,
      source: nil,
      note: nil
    }

  defp layer(_layer, _entry, _name, _cli, _facts, _values), do: nil

  defp override(_layer, _entry, nil, _source_key), do: nil

  defp override(layer, entry, override, source_key) when is_map(override) do
    raw = to_string(get(override, :value) || "")
    source = get(override, source_key) || get(override, :source)

    {value, ignored} =
      cond do
        get(override, :ignored) == true -> {nil, true}
        true -> parsed(entry, raw)
      end

    %{
      layer: layer,
      value: value,
      set: true,
      ignored: ignored,
      raw: raw,
      source: source && to_string(source),
      note: get(override, :note)
    }
  end

  defp override(_layer, _entry, _override, _source_key), do: nil

  defp parsed(entry, raw) do
    with {:ok, value} <- TextValue.parse(entry, raw),
         :ok <- Validate.check(entry, value) do
      {value, false}
    else
      _ -> {nil, true}
    end
  end

  defp get(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp get(_map, _key), do: nil

  defp named(map, key) when is_map(map), do: Map.get(map, key)
  defp named(_map, _key), do: nil

  @doc "The winning layer's map of a SettingValue (nil when none is set)."
  @spec winner(map()) :: map() | nil
  def winner(setting) do
    winner = Map.get(setting, :winner)
    Enum.find(Map.get(setting, :layers, []), &(Map.get(&1, :layer) == winner))
  end

  @doc "The layers that override the home layer while they are set (env, flag), not ignored."
  @spec overrides(map(), Entry.t()) :: [map()]
  def overrides(setting, %Entry{home: home}) do
    setting
    |> Map.get(:layers, [])
    |> Enum.take_while(&(Map.get(&1, :layer) != home))
    |> Enum.filter(&(Map.get(&1, :set) and not Map.get(&1, :ignored, false)))
  end
end
