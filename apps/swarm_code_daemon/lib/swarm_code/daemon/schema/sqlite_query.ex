defmodule SwarmCode.Daemon.Schema.SqliteQuery do
  @moduledoc false

  alias Exqlite.Sqlite3

  @spec rows(Sqlite3.db(), String.t(), [Sqlite3.bind_value()]) :: [Sqlite3.row()]
  def rows(conn, sql, parameters) when is_binary(sql) and is_list(parameters) do
    statement = prepare!(conn, sql)

    try do
      bind!(statement, parameters)
      collect_rows(conn, statement, [])
    after
      release!(conn, statement)
    end
  end

  defp prepare!(conn, sql) do
    case Sqlite3.prepare(conn, sql) do
      {:ok, statement} -> statement
      {:error, reason} -> raise RuntimeError, "SQLite prepare failed: #{inspect(reason)}"
    end
  end

  defp bind!(statement, parameters) do
    case Sqlite3.bind(statement, parameters) do
      :ok -> :ok
      {:error, reason} -> raise RuntimeError, "SQLite bind failed: #{inspect(reason)}"
    end
  end

  defp collect_rows(conn, statement, rows) do
    case Sqlite3.step(conn, statement) do
      {:row, row} -> collect_rows(conn, statement, [row | rows])
      :done -> Enum.reverse(rows)
      :busy -> raise RuntimeError, "SQLite query was busy"
      {:error, reason} -> raise RuntimeError, "SQLite step failed: #{inspect(reason)}"
    end
  end

  defp release!(conn, statement) do
    case Sqlite3.release(conn, statement) do
      :ok -> :ok
      {:error, reason} -> raise RuntimeError, "SQLite release failed: #{inspect(reason)}"
    end
  end
end
