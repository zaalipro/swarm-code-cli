defmodule Exqlite.SwarmGuard do
  @moduledoc """
  Test/development-only exact-main-descriptor feasibility for private, clean
  rollback fixtures. This API is not canonical admission and does not support
  WAL, hot journals, Ready, durable writes, or guarded connection pools.
  Production calls return `{:error, :native_guard_unavailable}`.
  """
  @enabled if(Code.ensure_loaded?(Mix) and :ets.whereis(Mix.State) != :undefined,
              do: Mix.env() in [:dev, :test],
              else: System.get_env("SWARM_GUARD_TEST") == "1")

  if @enabled do
    alias Exqlite.Sqlite3NIF
    defdelegate feasibility_admit(path), to: Sqlite3NIF, as: :guard_admit
    defdelegate feasibility_open(resource), to: Sqlite3NIF, as: :guard_open
    defdelegate resource_identity(resource), to: Sqlite3NIF, as: :guard_resource_identity
    defdelegate connection_identity(connection), to: Sqlite3NIF, as: :guard_connection_identity
    defdelegate close(resource), to: Sqlite3NIF, as: :guard_resource_close
  else
    def feasibility_admit(_), do: {:error, :native_guard_unavailable}
    def feasibility_open(_), do: {:error, :native_guard_unavailable}
    def resource_identity(_), do: {:error, :native_guard_unavailable}
    def connection_identity(_), do: {:error, :native_guard_unavailable}
    def close(_), do: {:error, :native_guard_unavailable}
  end
end
