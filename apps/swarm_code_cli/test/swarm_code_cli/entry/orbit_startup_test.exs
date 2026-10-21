defmodule SwarmCodeCLI.Release.OrbitStartupTest do
  @moduledoc """
  orbit S6 (spec 3.5): `terminal.startup_conversation` gains `dashboard`, the
  default. `startup_selection/1` and `tui_selection/0` return the conversation
  to open and what opens over it (`nil | :picker | :home`); an explicit
  `latest` keeps today's behaviour. The cli.json read here lives in a temp
  config directory, never the real one.
  """
  use ExUnit.Case, async: false

  alias SwarmCode.Settings.Registry
  alias SwarmCodeCLI.Release.PersistedSession
  alias SwarmCodeCLI.Release.TerminalPreferences, as: TP

  @env ~w(SWARM_CONVERSATION SWARM_SETTINGS_ONLY SWARM_RESUME_PICKER SWARM_SETTINGS_OPEN)

  setup do
    dir = Path.join(System.tmp_dir!(), "orbit-startup-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)

    saved_env = Map.new(@env, &{&1, System.get_env(&1)})
    Enum.each(@env, &System.delete_env/1)
    prior = Application.get_env(:swarm_code_daemon, :domain_config_dir)
    Application.put_env(:swarm_code_daemon, :domain_config_dir, dir)

    on_exit(fn ->
      File.rm_rf!(dir)

      if prior,
        do: Application.put_env(:swarm_code_daemon, :domain_config_dir, prior),
        else: Application.delete_env(:swarm_code_daemon, :domain_config_dir)

      Enum.each(saved_env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    %{dir: dir, path: Path.join(dir, "cli.json")}
  end

  defp cli!(path, values) do
    File.write!(path, Jason.encode!(values))
    File.chmod!(path, 0o600)
    path
  end

  defp cli(values), do: %{values: values, status: :ok}

  describe "startup_selection/1 (cli.json)" do
    test "an absent file, an empty file, `dashboard` and nil open Home over the latest", c do
      assert PersistedSession.startup_selection(c.path) == {:latest, :home}
      assert PersistedSession.startup_selection(nil) == {:latest, :home}
      assert PersistedSession.startup_selection(cli!(c.path, %{})) == {:latest, :home}

      assert PersistedSession.startup_selection(
               cli!(c.path, %{"startup_conversation" => "dashboard"})
             ) == {:latest, :home}
    end

    test "an explicit `latest` is honoured: no Home (decision e)", c do
      assert PersistedSession.startup_selection(
               cli!(c.path, %{"startup_conversation" => "latest"})
             ) == {:latest, nil}
    end

    test "`new` starts a new conversation and `ask` opens the resume picker", c do
      assert PersistedSession.startup_selection(cli!(c.path, %{"startup_conversation" => "new"})) ==
               {:new, nil}

      assert PersistedSession.startup_selection(cli!(c.path, %{"startup_conversation" => "ask"})) ==
               {:latest, :picker}
    end

    test "an invalid value is dropped by the file reader and Home opens", c do
      path = cli!(c.path, %{"startup_conversation" => "bogus"})
      assert SwarmCode.Settings.CliFile.read_all(path).values["startup_conversation"] == nil
      assert PersistedSession.startup_selection(path) == {:latest, :home}

      assert PersistedSession.startup_selection(cli!(c.path, %{"startup_conversation" => 7})) ==
               {:latest, :home}
    end
  end

  describe "tui_selection/0" do
    test "with nothing set it follows cli.json in the config directory", c do
      assert PersistedSession.tui_selection() == {:latest, :home}

      cli!(c.path, %{"startup_conversation" => "latest"})
      assert PersistedSession.tui_selection() == {:latest, nil}

      cli!(c.path, %{"startup_conversation" => "ask"})
      assert PersistedSession.tui_selection() == {:latest, :picker}

      cli!(c.path, %{"startup_conversation" => "new"})
      assert PersistedSession.tui_selection() == {:new, nil}
    end

    test "SWARM_CONVERSATION wins and opens nothing over the conversation", c do
      cli!(c.path, %{"startup_conversation" => "dashboard"})

      System.put_env("SWARM_CONVERSATION", "latest")
      assert PersistedSession.tui_selection() == {:latest, nil}

      System.put_env("SWARM_CONVERSATION", "new")
      assert PersistedSession.tui_selection() == {:new, nil}

      System.put_env("SWARM_CONVERSATION", "8d0f1c2e-1234-4abc-9def-0123456789ab")
      assert PersistedSession.tui_selection() == {"8d0f1c2e-1234-4abc-9def-0123456789ab", nil}

      # An empty export is no export: the file decides.
      System.put_env("SWARM_CONVERSATION", "")
      assert PersistedSession.tui_selection() == {:latest, :home}
    end

    test "SWARM_RESUME_PICKER=1 (bare --resume) opens the picker, whatever the file says", c do
      cli!(c.path, %{"startup_conversation" => "dashboard"})
      System.put_env("SWARM_RESUME_PICKER", "1")
      System.put_env("SWARM_CONVERSATION", "latest")
      assert PersistedSession.tui_selection() == {:latest, :picker}
    end

    test "a settings-only launch opens the latest and nothing over it", c do
      cli!(c.path, %{"startup_conversation" => "dashboard"})
      System.put_env("SWARM_SETTINGS_ONLY", "1")
      assert PersistedSession.tui_selection() == {:latest, nil}

      System.put_env("SWARM_RESUME_PICKER", "1")
      assert PersistedSession.tui_selection() == {:latest, nil}

      System.put_env("SWARM_CONVERSATION", "new")
      assert PersistedSession.tui_selection() == {:new, nil}
    end
  end

  describe "the launch preferences and the settings entry" do
    test "TerminalPreferences reads `dashboard` as the default and `latest` as itself" do
      assert TP.launch(%{}, cli(%{}), nil).startup_conversation == :dashboard

      assert TP.launch(%{}, cli(%{"startup_conversation" => "dashboard"}), nil).startup_conversation ==
               :dashboard

      assert TP.launch(%{}, cli(%{"startup_conversation" => "latest"}), nil).startup_conversation ==
               :latest

      assert TP.launch(%{}, cli(%{"startup_conversation" => "new"}), nil).startup_conversation ==
               :new

      assert TP.launch(%{}, cli(%{"startup_conversation" => "ask"}), nil).startup_conversation ==
               :ask
    end

    test "flags and SWARM_CONVERSATION keep their effect" do
      launch = TP.launch(%{}, cli(%{}), nil, %{"--new" => ""})
      assert launch.startup_conversation == :new
      assert launch.flag_overrides["terminal.startup_conversation"].flag == "--new"

      launch = TP.launch(%{}, cli(%{}), nil, %{"--continue" => ""})
      assert launch.startup_conversation == :latest

      launch = TP.launch(%{"SWARM_CONVERSATION" => "latest"}, cli(%{}), nil)
      assert launch.startup_conversation == :latest
      assert launch.env_overrides["terminal.startup_conversation"].var == "SWARM_CONVERSATION"

      launch = TP.launch(%{}, cli(%{}), nil, %{"--resume" => "8d0f1c2e"})
      assert launch.startup_conversation == :dashboard
      assert %{ignored: true} = launch.flag_overrides["terminal.startup_conversation"]
    end

    test "the registry entry offers dashboard first and defaults to it" do
      entry = Registry.fetch!("terminal.startup_conversation")
      assert entry.default == "dashboard"
      assert Enum.map(entry.choices, & &1.value) == ~w(dashboard latest new ask)
    end
  end
end
