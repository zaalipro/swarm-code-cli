defmodule SwarmCode.Daemon.Schema.SqliteQueryTest do
  use ExUnit.Case, async: true

  alias SwarmCode.Daemon.Schema.SqliteQuery

  test "the reducing query releases its statement on success" do
    conn = fake_connection([{:row, [1]}, {:row, [2]}, :done])

    assert 3 ==
             SqliteQuery.reduce(
               conn,
               "SELECT value",
               [],
               0,
               fn [value], total ->
                 total + value
               end,
               max_rows: 2,
               sqlite: SqliteQueryFake
             )

    assert_statement_released()
  end

  test "the reducing query releases its statement when the row limit rejects" do
    conn = fake_connection([{:row, [1]}, {:row, [2]}])

    assert_raise RuntimeError, "SQLite row limit exceeded", fn ->
      SqliteQuery.reduce(conn, "SELECT value", [], [], fn row, rows -> [row | rows] end,
        max_rows: 1,
        sqlite: SqliteQueryFake
      )
    end

    assert_statement_released()
  end

  test "the reducing query releases its statement when the reducer raises" do
    conn = fake_connection([{:row, [1]}])

    assert_raise RuntimeError, "injected reducer failure", fn ->
      SqliteQuery.reduce(
        conn,
        "SELECT value",
        [],
        :initial,
        fn _row, _acc -> raise "injected reducer failure" end,
        max_rows: 1,
        sqlite: SqliteQueryFake
      )
    end

    assert_statement_released()
  end

  test "the reducing query releases its statement when binding fails" do
    conn = fake_connection([], bind_response: {:error, :injected_bind_failure})

    assert_raise RuntimeError, "SQLite bind failed: :injected_bind_failure", fn ->
      SqliteQuery.reduce(conn, "SELECT value", [], [], fn row, rows -> [row | rows] end,
        max_rows: 1,
        sqlite: SqliteQueryFake
      )
    end

    assert_statement_released()
  end

  test "the reducing query releases its statement when stepping fails" do
    conn = fake_connection([{:error, :injected_step_failure}])

    assert_raise RuntimeError, "SQLite step failed: :injected_step_failure", fn ->
      SqliteQuery.reduce(conn, "SELECT value", [], [], fn row, rows -> [row | rows] end,
        max_rows: 1,
        sqlite: SqliteQueryFake
      )
    end

    assert_statement_released()
  end

  defp fake_connection(responses, opts \\ []) do
    opts = Keyword.merge([owner: self(), responses: responses], opts)
    start_supervised!({SqliteQueryFake, opts})
  end

  defp assert_statement_released do
    assert_receive {:prepared, statement}
    assert_receive {:released, ^statement}
  end
end
