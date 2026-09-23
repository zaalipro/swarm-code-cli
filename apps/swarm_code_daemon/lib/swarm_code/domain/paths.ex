defmodule SwarmCode.Domain.Paths do
  @moduledoc """
  The global SwarmCode directory: global memory, skills, commands, user
  workflows, attachments and scratch projects.

  Resolved when it is used, never when the release is built (pass70 B5, arch
  F8, rel F12), so it follows the running user's home:

  1. `config :swarm_code_daemon, :domain_config_dir` (tests set it),
  2. `SWARM_CODE_CONFIG_DIR` (an absolute path),
  3. the platform directory: the desktop's own
     `~/Library/Application Support/SwarmCode` on macOS, so the CLI and the
     app share one global dir; `$XDG_CONFIG_HOME/swarm-code` (default
     `~/.config/swarm-code`) on Linux.
  """

  @spec config_dir() :: Path.t()
  def config_dir do
    Application.get_env(:swarm_code_daemon, :domain_config_dir) ||
      absolute(System.get_env("SWARM_CODE_CONFIG_DIR")) ||
      platform_dir(:os.type())
  end

  @doc false
  @spec platform_dir({atom(), atom()}) :: Path.t()
  def platform_dir({:unix, :darwin}),
    do: Path.join([System.user_home!(), "Library", "Application Support", "SwarmCode"])

  def platform_dir(_os) do
    base =
      absolute(System.get_env("XDG_CONFIG_HOME")) || Path.join(System.user_home!(), ".config")

    Path.join(base, "swarm-code")
  end

  defp absolute(value) when is_binary(value) and value != "" do
    if Path.type(value) == :absolute, do: Path.expand(value)
  end

  defp absolute(_), do: nil
end
