defmodule SwarmCodeCLI.Release.VersionTest do
  # cli020 A8 (owner decision 1): one release, 0.2.0, in all three apps (the
  # umbrella `mix.exs` carries the same), and the synced MCP and LSP clients
  # introduce themselves as the desktop does.
  use ExUnit.Case, async: true

  test "every app of the release is version 0.2.0" do
    for app <- [:swarm_code_core, :swarm_code_daemon, :swarm_code_cli] do
      assert Application.spec(app, :vsn) == ~c"0.2.0", "#{app}"
    end
  end

  test "the synced MCP and LSP clients say ncode 0.2.0" do
    root = Path.expand("../../../../..", __DIR__)
    domain = Path.join(root, "apps/swarm_code_daemon/lib/swarm_code/domain")

    assert File.read!(Path.join(domain, "mcp/client.ex")) =~
             ~s(%{"name" => "ncode", "version" => "0.2.0"})

    assert File.read!(Path.join(domain, "lsp/client.ex")) =~
             ~s(%{"name" => "ncode", "version" => "0.2.0"})
  end
end
