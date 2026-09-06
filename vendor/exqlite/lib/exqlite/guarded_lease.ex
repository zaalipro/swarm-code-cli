defmodule Exqlite.GuardedLease do
  @moduledoc """
  One owner-bound SQLite lease beneath an already locked native DirectoryScope.

  The fixed lease basename is `instance_lease.db`. No arbitrary path, SQL,
  application database, Repo or Ready constructor is exposed. Close the lease
  before explicitly closing the scope; owner death revokes the graph and native
  cleanup closes SQLite before releasing its directory locks.
  """
  alias Exqlite.Sqlite3NIF
  @opaque t :: reference()

  defdelegate acquire(scope), to: Sqlite3NIF, as: :lease_acquire
  defdelegate assert_held(lease), to: Sqlite3NIF, as: :lease_assert_held
  defdelegate identity(lease), to: Sqlite3NIF, as: :lease_identity
  defdelegate close(lease), to: Sqlite3NIF, as: :lease_close
  defdelegate status(lease), to: Sqlite3NIF, as: :lease_status
end
