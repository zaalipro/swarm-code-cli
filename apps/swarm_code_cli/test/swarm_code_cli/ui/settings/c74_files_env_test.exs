defmodule SwarmCodeCLI.UI.Settings.C74FilesEnvTest do
  @moduledoc "cli74 U3-12: the Files & environment page (§2.21, §2.25, AT13)."
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.C74U3Helpers

  alias SwarmCodeCLI.UI.Settings.{Attention, Nav, Sections}
  alias SwarmCodeCLI.UI.Settings.Sections.FilesEnv

  @cli_path "~/.config/swarmcode/cli.json"

  defp ctx_with(cli, launch \\ %{}) do
    {state, _fake} = opened(:files_env)
    ctx = Nav.ctx(state)

    %{
      ctx
      | data: %{ctx.data | cli: cli},
        launch_facts: Map.merge(%{cli_path: @cli_path}, launch)
    }
  end

  defp find(rows, id), do: Enum.find(rows, &(&1.id == id))
  defp line_words(row), do: Enum.map_join(row.lines, " / ", &words/1)

  test "a private cli.json: its mode, size and the keys this CLI keeps but does not use" do
    ctx = ctx_with(%{mode: 0o600, size: 812, status: :ok, unknown: ["future_key"], invalid: []})
    row = ctx |> then(&Sections.rows(:files_env, &1)) |> find("key:files.cli_json")
    assert words(row) == @cli_path <> "  0600 ✓"
    assert line_words(row) =~ "812 B of 64 KB"
    assert line_words(row) =~ "kept, not used here: future_key"
    assert Sections.attention(:files_env, ctx) == []
  end

  test "a cli.json others can read: the words, Make it private, and AT13" do
    ctx = ctx_with(%{mode: 0o644, size: 90, status: :ok})
    rows = Sections.rows(:files_env, ctx)
    assert words(find(rows, "key:files.cli_json")) =~ "✗ 0644: others can read it"
    fix = find(rows, "act:make_private")
    assert [{:cli_write, %{}}] = Sections.act(:files_env, ctx, fix, :open_row)

    assert [%Attention{id: "AT13", severity: :warning, title: title}] =
             Sections.attention(:files_env, ctx)

    assert title =~ "0644"
  end

  test "a broken cli.json says the defaults are used" do
    ctx = ctx_with(%{mode: 0o600, size: 10, status: :not_json})
    row = ctx |> then(&Sections.rows(:files_env, &1)) |> find("key:files.cli_json")
    assert line_words(row) =~ "✗ cli.json is not valid JSON · the defaults are used · e edit it"
    assert [%Attention{severity: :error}] = Sections.attention(:files_env, ctx)
  end

  test "an unsaved session keeps no cli.json" do
    {state, _fake} = opened(:files_env)
    assert words(key_row(state, "files.cli_json")) =~ "no cli.json"
  end

  test "the environment: values, secrets say set, Enter goes to the setting, developer apart" do
    ctx =
      ctx_with(nil, %{
        env_overrides: %{
          "terminal.theme" => %{var: "SWARM_THEME", value: "light"},
          "providers.key" => %{var: "LLMOTIONS_API_KEY", value: "sk-secret"}
        }
      })

    facts =
      Map.put(ctx.data.facts, :env, [
        %{name: "SWARM_SETTINGS_ONLY", set: true, value: "1", secret: false, feeds: nil}
      ])

    ctx = %{ctx | data: %{ctx.data | facts: facts}}
    rows = Sections.rows(:files_env, ctx)

    theme = find(rows, "env:SWARM_THEME")
    assert words(theme) == "light"
    assert [{:section, :appearance}] = Sections.act(:files_env, ctx, theme, :open_row)

    secret = find(rows, "env:LLMOTIONS_API_KEY")
    assert words(secret) == "set"
    refute Enum.any?(rows, &(all_words(&1) =~ "sk-secret"))

    ids = Enum.map(rows, & &1.id)

    assert Enum.find_index(ids, &(&1 == "head:developer")) <
             Enum.find_index(ids, &(&1 == "env:SWARM_SETTINGS_ONLY"))
  end

  test "folders copy and open; versions copy; Check everything runs the doctor" do
    {state, _fake} = opened(:files_env)
    ctx = Nav.ctx(state)
    config = key_row(state, "files.config_dir")

    assert [{:open_folder, "~/.config/swarmcode"}] =
             Sections.act(:files_env, ctx, config, :open_related)

    assert [{:copy, "~/.config/swarmcode"}, _] = Sections.act(:files_env, ctx, config, :copy)
    assert words(key_row(state, "files.database")) =~ "1.7 GB"

    versions = key_row(state, "files.versions")
    assert [{:copy, text}, _] = Sections.act(:files_env, ctx, versions, :copy)
    assert text =~ "OTP 28"

    doctor = key_row(state, "files.doctor")
    assert [{:task, "doctor", nil, %{}}] = Sections.act(:files_env, ctx, doctor, :open_row)
  end

  test "bytes" do
    assert FilesEnv.bytes(812) == "812 B"
    assert FilesEnv.bytes(42_189) == "41.2 KB"
    assert FilesEnv.bytes(nil) == ""
  end
end
