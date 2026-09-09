defmodule SwarmCode.Domain.Paths do
  @moduledoc "Domain file roots supplied by the daemon's admitted startup owner."
  def config_dir, do: Application.fetch_env!(:swarm_code_daemon, :domain_config_dir)
end
