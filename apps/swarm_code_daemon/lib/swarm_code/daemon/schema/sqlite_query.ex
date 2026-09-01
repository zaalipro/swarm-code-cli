defmodule SwarmCode.Daemon.Schema.SqliteQuery do
  @moduledoc false

  alias Exqlite.Sqlite3

  @default_max_rows 512

  @spec rows(Sqlite3.db(), String.t(), [Sqlite3.bind_value()]) :: [Sqlite3.row()]
  def rows(conn, sql, parameters) when is_binary(sql) and is_list(parameters) do
    rows(conn, sql, parameters, max_rows: @default_max_rows)
  end

  @spec rows(Sqlite3.db(), String.t(), [Sqlite3.bind_value()], keyword()) :: [Sqlite3.row()]
  def rows(conn, sql, parameters, opts)
      when is_binary(sql) and is_list(parameters) and is_list(opts) do
    conn
    |> reduce(sql, parameters, [], fn row, rows -> [row | rows] end, opts)
    |> Enum.reverse()
  end

  @spec reduce(
          term(),
          String.t(),
          list(),
          accumulator,
          (list(), accumulator -> accumulator),
          keyword()
        ) :: accumulator
        when accumulator: term()
  def reduce(conn, sql, parameters, accumulator, reducer, opts)
      when is_binary(sql) and is_list(parameters) and is_function(reducer, 2) and is_list(opts) do
    sqlite = Keyword.get(opts, :sqlite, Sqlite3)
    max_rows = Keyword.fetch!(opts, :max_rows)

    unless is_integer(max_rows) and max_rows >= 0 do
      raise ArgumentError, "max_rows must be a non-negative integer"
    end

    statement = prepare!(sqlite, conn, sql)

    try do
      bind!(sqlite, statement, parameters)
      reduce_rows(sqlite, conn, statement, accumulator, reducer, max_rows, 0)
    after
      release!(sqlite, conn, statement)
    end
  end

  defp prepare!(sqlite, conn, sql) do
    case sqlite.prepare(conn, sql) do
      {:ok, statement} -> statement
      {:error, reason} -> raise RuntimeError, "SQLite prepare failed: #{inspect(reason)}"
    end
  end

  defp bind!(sqlite, statement, parameters) do
    case sqlite.bind(statement, parameters) do
      :ok -> :ok
      {:error, reason} -> raise RuntimeError, "SQLite bind failed: #{inspect(reason)}"
    end
  end

  defp reduce_rows(sqlite, conn, statement, accumulator, reducer, max_rows, row_count) do
    case sqlite.step(conn, statement) do
      {:row, row} when row_count < max_rows ->
        reduce_rows(
          sqlite,
          conn,
          statement,
          reducer.(row, accumulator),
          reducer,
          max_rows,
          row_count + 1
        )

      {:row, _row} ->
        raise RuntimeError, "SQLite row limit exceeded"

      :done ->
        accumulator

      :busy ->
        raise RuntimeError, "SQLite query was busy"

      {:error, reason} ->
        raise RuntimeError, "SQLite step failed: #{inspect(reason)}"
    end
  end

  defp release!(sqlite, conn, statement) do
    case sqlite.release(conn, statement) do
      :ok -> :ok
      {:error, reason} -> raise RuntimeError, "SQLite release failed: #{inspect(reason)}"
    end
  end
end
