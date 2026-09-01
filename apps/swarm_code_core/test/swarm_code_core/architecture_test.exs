defmodule SwarmCodeCore.ArchitectureTest do
  use ExUnit.Case, async: true

  @forbidden ~w(phoenix phoenix_live_view bandit desktop desktop_deployment wx)

  test "umbrella has only the three approved applications" do
    root = Path.expand("../../../..", __DIR__)

    assert root
           |> Path.join("apps/*/mix.exs")
           |> Path.wildcard()
           |> Enum.map(&(&1 |> Path.dirname() |> Path.basename()))
           |> Enum.sort() == ~w(swarm_code_cli swarm_code_core swarm_code_daemon)
  end

  test "locked dependency graph excludes web and desktop runtimes" do
    lock = Path.expand("../../../../mix.lock", __DIR__) |> File.read!()
    Enum.each(@forbidden, fn name -> refute lock =~ ~s("#{name}":) end)
  end

  test "runtime config never reads DATABASE_PATH" do
    runtime = Path.expand("../../../../config/runtime.exs", __DIR__) |> File.read!()
    refute runtime =~ "DATABASE_PATH"
  end
end
