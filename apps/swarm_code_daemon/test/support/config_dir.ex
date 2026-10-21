defmodule SwarmCode.Test.ConfigDir do
  @moduledoc """
  Pass 77 C-ARCH-7: points `SwarmCode.Domain.Paths.config_dir/0` at a private
  directory for the calling test process only.

  `put/1` sets the process key `Paths.config_dir/0` reads first. It registers
  nothing global, so a test whose every read happens in its own process (the
  unit under test is called directly, not through a GenServer, a Task or a
  backend) can run `async: true`. A test that reads the directory from another
  process still needs `with_app_env/1`, which is global and so `async: false`.
  """

  @key :swarm_code_config_dir

  @doc "Makes `dir` this process's config directory; returns `dir`."
  @spec put(Path.t()) :: Path.t()
  def put(dir) when is_binary(dir) do
    Process.put(@key, dir)
    dir
  end

  @doc """
  The global form: `config :swarm_code_daemon, :domain_config_dir` for every
  process, restored on exit. Only for `async: false` tests.
  """
  @spec with_app_env(Path.t()) :: Path.t()
  def with_app_env(dir) when is_binary(dir) do
    prior = Application.fetch_env(:swarm_code_daemon, :domain_config_dir)
    Application.put_env(:swarm_code_daemon, :domain_config_dir, dir)

    ExUnit.Callbacks.on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(:swarm_code_daemon, :domain_config_dir, value)
        :error -> Application.delete_env(:swarm_code_daemon, :domain_config_dir)
      end
    end)

    dir
  end
end
