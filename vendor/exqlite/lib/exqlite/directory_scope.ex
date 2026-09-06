defmodule Exqlite.DirectoryScope do
  @moduledoc """
  Native owner-bound directory capabilities and ordered nonblocking directory locks.

  This low-level primitive does not resolve canonical application paths, create
  private directories, or authorize SQLite access. The creating process owns the
  scope; its death revokes all copied directory/scope terms and schedules native
  cleanup. Keep the scope in the foundation owner, not a transient client.
  """
  alias Exqlite.Sqlite3NIF

  @opaque t :: reference()
  @opaque directory :: reference()

  defdelegate new(), to: Sqlite3NIF, as: :directory_scope_new
  defdelegate open_root(scope, physical_path), to: Sqlite3NIF, as: :directory_open_root
  defdelegate open_child(directory, basename), to: Sqlite3NIF, as: :directory_open_child
  defdelegate identity(directory), to: Sqlite3NIF, as: :directory_identity
  defdelegate lock(scope, runtime, data), to: Sqlite3NIF, as: :directory_lock
  defdelegate assert_locked(scope), to: Sqlite3NIF, as: :directory_assert_locked
  defdelegate close(scope), to: Sqlite3NIF, as: :directory_scope_close
  defdelegate status(scope), to: Sqlite3NIF, as: :directory_scope_status
end
