defmodule Exqlite.DatabaseBinding do
  @moduledoc """
  Native owner-bound pin of the admitted application database.

  Acquires the fixed `application.db` beneath a locked directory/lease graph and
  compares `{device, inode, uid}` with the schema admission identity. The resource
  retains its lease. Copies do not transfer ownership; owner death or resource GC
  revokes the graph. Close this resource before explicitly closing its lease.

  The owner authorizes a target process with a one-use ticket. Opening that
  ticket uses the retained descriptors and fixed sidecar namespace. SQLite and
  statement handles retain the binding and lease until their attested close.
  """
  alias Exqlite.Sqlite3NIF
  @opaque t :: reference()
  @opaque ticket :: reference()
  @type identity :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @spec acquire(Exqlite.GuardedLease.t(), identity()) :: {:ok, t()} | {:error, atom()}
  defdelegate assert_connection(db), to: Sqlite3NIF, as: :database_binding_assert_connection
  defdelegate acquire(lease, identity, basename), to: Sqlite3NIF, as: :database_binding_acquire
  defdelegate authorize(binding, pid), to: Sqlite3NIF, as: :database_binding_authorize
  defdelegate open(ticket), to: Sqlite3NIF, as: :database_binding_open
  defdelegate connections(binding), to: Sqlite3NIF, as: :database_binding_connections
  defdelegate acquire(lease, identity), to: Sqlite3NIF, as: :database_binding_acquire
  @spec create(Exqlite.GuardedLease.t(), binary()) :: {:ok, t(), identity()} | {:error, atom()}
  defdelegate create(lease, basename), to: Sqlite3NIF, as: :database_binding_create
  defdelegate assert_held(binding), to: Sqlite3NIF, as: :database_binding_assert
  defdelegate close(binding), to: Sqlite3NIF, as: :database_binding_close
  defdelegate status(binding), to: Sqlite3NIF, as: :database_binding_status
end
