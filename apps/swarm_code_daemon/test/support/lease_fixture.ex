defmodule SwarmCode.Daemon.Test.LeaseFixture do
  @moduledoc false
  alias SwarmCode.Daemon.Platform.PathSet

  def build_root, do: Path.expand("../../../../_build", __DIR__)

  def paths(data, runtime \\ nil) do
    runtime = runtime || Path.join(data, "runtime")
    File.mkdir_p!(runtime)
    File.chmod!(runtime, 0o700)

    %PathSet{
      platform: :macos,
      data: data,
      config: data,
      state: data,
      cache: data,
      runtime: runtime,
      database: Path.join(data, "swarm_code.db"),
      lease: Path.join(data, "instance_lease.db"),
      owner_record: Path.join(data, "instance_owner.json"),
      socket: Path.join(runtime, "daemon.sock"),
      socket_metadata: Path.join(runtime, "daemon.json"),
      backups: Path.join(data, "backups")
    }
  end
end
