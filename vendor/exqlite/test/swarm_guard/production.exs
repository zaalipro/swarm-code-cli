scratch = System.fetch_env!("SWARM_FEASIBILITY_ROOT")
Code.prepend_paths(Path.wildcard(Path.join(scratch, "lib/*/ebin")))
ExUnit.start()

defmodule SwarmGuardProductionProof do
  use ExUnit.Case

  test "production NIF has no fixture exports and facade refuses" do
    assert {:module, Exqlite.Sqlite3NIF} = Code.ensure_loaded(Exqlite.Sqlite3NIF)
    refute function_exported?(Exqlite.Sqlite3NIF, :guard_admit, 1)
    refute function_exported?(Exqlite.Sqlite3NIF, :guard_open, 1)
    refute function_exported?(Exqlite.Sqlite3NIF, :guard_counts, 0)
    assert {:error, :native_guard_unavailable} = Exqlite.SwarmGuard.feasibility_admit(:untrusted)
    assert {:error, :native_guard_unavailable} = Exqlite.SwarmGuard.feasibility_open(make_ref())
    {:ok, db} = Exqlite.Sqlite3.open(":memory:")
    assert :ok = Exqlite.Sqlite3.execute(db, "CREATE TABLE ordinary(value)")
    assert :ok = Exqlite.Sqlite3.close(db)
  end
end
