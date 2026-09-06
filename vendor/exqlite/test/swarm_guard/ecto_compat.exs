scratch = System.fetch_env!("SWARM_FEASIBILITY_ROOT")
Code.prepend_paths(Path.wildcard(Path.join(scratch, "lib/*/ebin")))
{:ok, _} = Application.ensure_all_started(:ecto_sqlite3)
ExUnit.start()

defmodule ScratchCompatRepo do
  use Ecto.Repo, otp_app: :scratch_guard_compat, adapter: Ecto.Adapters.SQLite3
end

defmodule ScratchEctoProof do
  use ExUnit.Case, async: false

  test "ordinary Ecto adapter starts and persists through the scratch Exqlite NIF" do
    root = Path.join(System.fetch_env!("SWARM_FEASIBILITY_ROOT"), "ecto-fixtures-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    path = Path.join(root, "ordinary.db")
    config = [database: path, pool_size: 1, journal_mode: :delete, cache_size: -2000]
    {:ok, pid} = ScratchCompatRepo.start_link(config)
    assert Path.expand(:code.priv_dir(:exqlite) |> to_string()) ==
             Path.join(System.fetch_env!("SWARM_FEASIBILITY_ROOT"), "lib/exqlite/priv")
    %{rows: [["3.53.3"]]} = Ecto.Adapters.SQL.query!(ScratchCompatRepo, "SELECT sqlite_version()", [])
    Ecto.Adapters.SQL.query!(ScratchCompatRepo, "CREATE TABLE item(id INTEGER PRIMARY KEY, value TEXT)", [])
    Ecto.Adapters.SQL.query!(ScratchCompatRepo, "INSERT INTO item(value) VALUES (?)", ["before"])
    assert {:ok, :updated} = ScratchCompatRepo.transaction(fn ->
      Ecto.Adapters.SQL.query!(ScratchCompatRepo, "UPDATE item SET value=? WHERE id=?", ["after", 1])
      :updated
    end)
    assert %{rows: [["after"]]} = Ecto.Adapters.SQL.query!(ScratchCompatRepo, "SELECT value FROM item WHERE id=?", [1])
    Supervisor.stop(pid)
    {:ok, again} = ScratchCompatRepo.start_link(config)
    assert %{rows: [["after"]]} = Ecto.Adapters.SQL.query!(ScratchCompatRepo, "SELECT value FROM item WHERE id=?", [1])
    Supervisor.stop(again)
    IO.puts("PASS ordinary Ecto adapter start, SQL parameters, committed update, stop/restart persistence")
    File.rm!(path)
    assert [] = File.ls!(root)
    File.rmdir!(root)
    IO.puts("PASS own ordinary Ecto fixture directory removed")
  end
end
