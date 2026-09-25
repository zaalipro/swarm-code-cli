defmodule SwarmCodeCLI.Release.C74LaunchTest do
  @moduledoc """
  pass74 S1-13 (§3.8.4): the launch's terminal in one map (U3's
  `TerminalPreferences.launch/4` when the build has it, today's rules in the
  same shape otherwise), the launch facts the settings layer shows, and the
  conversation a TUI session opens from cli.json's `startup_conversation`.
  """
  use ExUnit.Case, async: false

  alias SwarmCodeCLI.Release.PersistedSession

  @keys ~w(theme theme_env mouse? keymap color_mode ascii? glyph_tier ambiguous_width
           reduced_motion? accent companion? startup_conversation prefs env_overrides
           flag_overrides)a

  setup do
    dir = Path.join(System.tmp_dir!(), "c74-launch-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    names = ~w(SWARM_CONVERSATION SWARM_SETTINGS_ONLY)
    saved = Map.new(names, &{&1, System.get_env(&1)})

    on_exit(fn ->
      File.rm_rf!(dir)

      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    %{dir: dir}
  end

  defp cli!(dir, values) do
    path = Path.join(dir, "cli.json")
    File.write!(path, Jason.encode!(values))
    File.chmod!(path, 0o600)
    path
  end

  defp launch(env, path), do: PersistedSession.launch(env, path, %{}, nil)

  test "one map with every launch key; the cli values seed the prefs", %{dir: dir} do
    path = cli!(dir, %{"keymap" => "vim", "panel" => "compact"})
    launch = launch(%{"TERM" => "xterm-256color"}, path)

    for key <- @keys, do: assert(Map.has_key?(launch, key), inspect(key))
    assert launch.prefs["keymap"] == "vim"
    assert launch.prefs["panel"] == "compact"
    assert launch.theme in [:dark, :light]
    assert is_boolean(launch.companion?)
  end

  test "NO_COLOR counts only when it is not empty (D21)", %{dir: dir} do
    path = cli!(dir, %{})

    assert launch(%{"NO_COLOR" => "1", "COLORTERM" => "truecolor"}, path).color_mode ==
             :monochrome

    assert launch(%{"NO_COLOR" => "", "COLORTERM" => "truecolor"}, path).color_mode == :truecolor
    assert launch(%{"COLORTERM" => "truecolor"}, nil).color_mode == :truecolor
  end

  test "the environment's theme, keymap and companion still win", %{dir: dir} do
    path = cli!(dir, %{"theme" => "light"})

    launch =
      launch(%{"SWARM_THEME" => "dark", "SWARM_KEYMAP" => "vim", "SWARM_COMPANION" => "0"}, path)

    assert launch.theme == :dark
    assert launch.theme_env == :dark
    assert launch.keymap == :vim
    refute launch.companion?
  end

  test "the launch facts name this launch and hold no secret", %{dir: dir} do
    path = cli!(dir, %{})
    launch = launch(%{"TAVILY_API_KEY" => "tvly-canary-000000000000"}, path)
    facts = PersistedSession.launch_facts(launch, dir, path)

    assert Map.keys(facts) |> Enum.sort() ==
             ~w(cli_path cli_version env_overrides flag_overrides flags home log_path project_root)a

    assert facts.project_root == dir
    assert facts.cli_path == path
    assert is_binary(facts.cli_version) and facts.cli_version != ""
    refute inspect(facts) =~ "tvly-canary"
  end

  test "cli.json's startup_conversation chooses when nothing else did", %{dir: dir} do
    assert PersistedSession.startup_selection(cli!(dir, %{"startup_conversation" => "new"})) ==
             {:new, false}

    assert PersistedSession.startup_selection(cli!(dir, %{"startup_conversation" => "ask"})) ==
             {:latest, true}

    assert PersistedSession.startup_selection(cli!(dir, %{})) == {:latest, false}
    assert PersistedSession.startup_selection(Path.join(dir, "missing.json")) == {:latest, false}
    assert PersistedSession.startup_selection(nil) == {:latest, false}
  end

  test "a flag (SWARM_CONVERSATION) wins; a settings-only session opens the latest" do
    System.put_env("SWARM_CONVERSATION", "new")
    System.delete_env("SWARM_SETTINGS_ONLY")
    assert PersistedSession.tui_selection() == {:new, false}

    System.delete_env("SWARM_CONVERSATION")
    System.put_env("SWARM_SETTINGS_ONLY", "1")
    assert PersistedSession.tui_selection() == {:latest, false}
  end
end
