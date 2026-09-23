defmodule SwarmCode.Domain.TestGlobalDir do
  @moduledoc """
  Points the domain's global directory (`Paths.config_dir/0`: global MEMORY.md,
  commands, skills, workflows, attachments) at a private temporary directory for
  the calling test and restores it on exit. The synced upstream tests that write
  or delete global files call it first: the test configuration must never reach
  a person's real SwarmCode directory.
  """

  @spec isolate!() :: Path.t()
  def isolate! do
    dir =
      Path.join(
        System.tmp_dir!(),
        "swarm-code-global-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    prior = Application.fetch_env(:swarm_code_daemon, :domain_config_dir)
    Application.put_env(:swarm_code_daemon, :domain_config_dir, dir)

    ExUnit.Callbacks.on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(:swarm_code_daemon, :domain_config_dir, value)
        :error -> Application.delete_env(:swarm_code_daemon, :domain_config_dir)
      end

      File.rm_rf(dir)
    end)

    dir
  end
end
