defmodule SwarmCode.Daemon.DomainPathsTest do
  # pass70 B5 (arch F8, rel F12): the global dir is resolved at run time.
  use ExUnit.Case, async: false
  alias SwarmCode.Domain.Paths

  setup do
    prior = Application.get_env(:swarm_code_daemon, :domain_config_dir)
    env = System.get_env("SWARM_CODE_CONFIG_DIR")

    on_exit(fn ->
      if prior,
        do: Application.put_env(:swarm_code_daemon, :domain_config_dir, prior),
        else: Application.delete_env(:swarm_code_daemon, :domain_config_dir)

      if env,
        do: System.put_env("SWARM_CODE_CONFIG_DIR", env),
        else: System.delete_env("SWARM_CODE_CONFIG_DIR")
    end)

    Application.delete_env(:swarm_code_daemon, :domain_config_dir)
    System.delete_env("SWARM_CODE_CONFIG_DIR")
    :ok
  end

  test "macOS shares the desktop's global directory" do
    assert Paths.platform_dir({:unix, :darwin}) ==
             Path.join([System.user_home!(), "Library", "Application Support", "SwarmCode"])
  end

  test "Linux follows XDG_CONFIG_HOME, else ~/.config" do
    xdg = System.get_env("XDG_CONFIG_HOME")

    on_exit(fn ->
      if xdg,
        do: System.put_env("XDG_CONFIG_HOME", xdg),
        else: System.delete_env("XDG_CONFIG_HOME")
    end)

    System.put_env("XDG_CONFIG_HOME", "/xdg/config")
    assert Paths.platform_dir({:unix, :linux}) == "/xdg/config/swarm-code"
    System.put_env("XDG_CONFIG_HOME", "relative/ignored")

    assert Paths.platform_dir({:unix, :linux}) ==
             Path.join(System.user_home!(), ".config/swarm-code")
  end

  test "an explicit configuration, then SWARM_CODE_CONFIG_DIR, then the platform" do
    assert Paths.config_dir() == Paths.platform_dir(:os.type())
    System.put_env("SWARM_CODE_CONFIG_DIR", "/explicit/dir")
    assert Paths.config_dir() == "/explicit/dir"
    Application.put_env(:swarm_code_daemon, :domain_config_dir, "/configured")
    assert Paths.config_dir() == "/configured"
  end

  test "nothing of the builder's home is compiled into the configuration" do
    config = Path.expand("../../../../../config/config.exs", __DIR__) |> File.read!()
    refute config =~ ~s(".config/swarm-code")
  end
end
