defmodule SwarmCodeCLI.Release.VersionTest do
  # cli020 A8 (owner decision 1), cli021: one release, 0.2.1, in all three apps
  # (the umbrella `mix.exs` carries the same), and the synced MCP and LSP
  # clients introduce themselves with the CLI's own version: since desktop
  # pass 74 says 0.2.2 there, the CLI keeps its number as a recorded
  # provenance patch on `domain/mcp/client.ex` and `domain/lsp/client.ex`
  # (cli021 K7). The contract names
  # `test/swarm_code_cli/release/version_test.exs`, but that directory is one of
  # `locked_branch_test`'s conditional campaign paths, so the test lives here.
  use ExUnit.Case, async: true

  @version "0.2.1"

  test "every app of the release is version 0.2.1" do
    for app <- [:swarm_code_core, :swarm_code_daemon, :swarm_code_cli] do
      assert Application.spec(app, :vsn) == String.to_charlist(@version), "#{app}"
    end

    root = Path.expand("../../../..", __DIR__)
    assert File.read!(Path.join(root, "mix.exs")) =~ ~s(version: "#{@version}")
  end

  test "the synced MCP and LSP clients say ncode 0.2.1" do
    root = Path.expand("../../../..", __DIR__)
    domain = Path.join(root, "apps/swarm_code_daemon/lib/swarm_code/domain")

    assert File.read!(Path.join(domain, "mcp/client.ex")) =~
             ~s(%{"name" => "ncode", "version" => "#{@version}"})

    assert File.read!(Path.join(domain, "lsp/client.ex")) =~
             ~s(%{"name" => "ncode", "version" => "#{@version}"})
  end
end
