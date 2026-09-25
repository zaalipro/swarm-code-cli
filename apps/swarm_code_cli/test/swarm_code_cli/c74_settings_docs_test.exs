defmodule SwarmCodeCLI.C74SettingsDocsTest do
  @moduledoc "pass74 S1-15: docs/settings.md is generated from the registry and must never drift from it."
  use ExUnit.Case, async: true

  alias Mix.Tasks.SwarmCode.Settings, as: Task
  alias SwarmCode.Settings.{Entry, Registry, Sections}

  @path Path.expand("../../../../docs/settings.md", __DIR__)

  test "the checked-in reference is exactly what the registry renders" do
    assert File.exists?(@path), "#{@path} is missing; run `mix swarm_code.settings --write`"

    assert File.read!(@path) == Task.render(),
           "#{@path} is stale; run `mix swarm_code.settings --write` from apps/swarm_code_cli"
  end

  test "every scalar key has a row, under its section's title" do
    rendered = Task.render()

    for entry <- Registry.all(), Entry.scalar?(entry) do
      assert rendered =~ "| `#{entry.key}` |", "#{entry.key} has no row"
    end

    for section <- Sections.all(),
        Enum.any?(Registry.for_section(section.id), &Entry.scalar?/1) do
      assert rendered =~ "\n## #{section.title}\n"
    end
  end

  test "the mix task's path is the umbrella's docs directory" do
    assert Path.basename(Task.path()) == "settings.md"
  end
end
