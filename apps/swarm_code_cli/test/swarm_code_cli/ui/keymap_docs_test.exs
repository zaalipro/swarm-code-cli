defmodule SwarmCodeCLI.UI.KeymapDocsTest do
  @moduledoc "docs/keybindings.md is generated from the table and must never drift from it."
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.Keymap.{Bindings, Docs}
  alias SwarmCodeCLI.UI.Projector.KeyLabel

  @path Path.expand("../../../../../docs/keybindings.md", __DIR__)

  test "the checked-in reference is exactly what the table renders" do
    assert File.exists?(@path), "#{@path} is missing; run `mix swarm_code.keymap --write`"

    assert File.read!(@path) == Docs.render(),
           "#{@path} is stale; run `mix swarm_code.keymap --write` from apps/swarm_code_cli"
  end

  test "every context has a section and every binding in it a row" do
    rendered = Docs.render()

    for context <- Bindings.contexts() do
      assert String.contains?(rendered, "\n## " <> Docs.title(context) <> "\n")

      for binding <- Bindings.for_context(context) do
        keys =
          binding
          |> Bindings.keys_in_context(context)
          |> KeyLabel.labels()
          |> Enum.map_join(" / ", &("`" <> &1 <> "`"))

        assert String.contains?(rendered, "| " <> keys <> " | " <> binding.help <> " |"),
               "#{binding.id} has no row for #{context}"
      end
    end
  end

  test "the mix task's path is the umbrella's docs directory" do
    assert Path.basename(Mix.Tasks.SwarmCode.Keymap.path()) == "keybindings.md"
  end
end
