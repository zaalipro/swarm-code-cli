defmodule SwarmCodeCLI.ZZProbeTest do
  use ExUnit.Case, async: false
  import SwarmCodeCLI.UI.C74U3Helpers
  alias SwarmCode.Settings.Registry
  alias SwarmCodeCLI.UI.Settings.{Search, Nav}

  test "probe" do
    by_section = Enum.group_by(Registry.all(), & &1.section)

    out =
      for {section, entries} <- by_section do
        {state, _} = opened(section)
        rows = rows(state)
        ctx = Nav.ctx(state)
        index = Search.index(ctx)

        for e <- entries do
          n = Enum.count(rows, &(&1.key == e.key))

          hits =
            Search.run(index, e.key).results
            |> Enum.map(&elem(&1, 1))
            |> Enum.filter(&(Map.get(&1, :key) == e.key))
            |> length()

          lab =
            Search.run(index, e.label).results
            |> Enum.map(&elem(&1, 1))
            |> Enum.filter(&(Map.get(&1, :key) == e.key))
            |> length()

          "#{section} #{e.key} type=#{e.type} scope=#{e.scope} rows=#{n} bykey=#{hits} bylabel=#{lab}"
        end
      end

    File.write!("/Users/zaali/.cache/c74/F/probe.txt", Enum.join(List.flatten(out), "\n"))
  end
end
