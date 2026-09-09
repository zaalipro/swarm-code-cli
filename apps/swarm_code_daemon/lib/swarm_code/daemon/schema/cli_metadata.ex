defmodule SwarmCode.Daemon.Schema.CliMetadata do
  @moduledoc "Exact optional CLI metadata extension; canonical web schema remains unchanged."
  alias SwarmCode.Daemon.Schema.SqliteQuery

  @table "cli_command_ledger"
  @index "cli_command_ledger_updated_idx"
  @attachments_table "cli_attachment_staging"
  @attachments_index "cli_attachment_staging_lookup_idx"
  @table_sql "CREATE TABLE cli_command_ledger (project_id TEXT NOT NULL, request_id TEXT NOT NULL, scope_kind TEXT NOT NULL, scope_id TEXT, scope_generation INTEGER NOT NULL, fingerprint TEXT NOT NULL, status TEXT NOT NULL, response_json TEXT, inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL, PRIMARY KEY (project_id, request_id))"
  @index_sql "CREATE INDEX cli_command_ledger_updated_idx ON cli_command_ledger(project_id, updated_at)"
  @attachments_table_sql "CREATE TABLE cli_attachment_staging (project_id TEXT NOT NULL, conversation_id TEXT NOT NULL, attachment_id TEXT NOT NULL, inserted_at TEXT NOT NULL, PRIMARY KEY (project_id, conversation_id, attachment_id))"
  @attachments_index_sql "CREATE INDEX cli_attachment_staging_lookup_idx ON cli_attachment_staging(project_id, conversation_id, inserted_at)"
  @query "SELECT type, name, tbl_name, CASE WHEN length(cast(sql as blob)) <= 4096 THEN sql END FROM sqlite_schema WHERE tbl_name IN ('cli_command_ledger', 'cli_attachment_staging') OR name IN ('cli_command_ledger_updated_idx', 'cli_attachment_staging_lookup_idx') ORDER BY type, name LIMIT 10"

  def table_sql, do: @table_sql
  def index_sql, do: @index_sql
  def attachments_table_sql, do: @attachments_table_sql
  def attachments_index_sql, do: @attachments_index_sql
  def query, do: @query
  def names, do: [@table, @index, @attachments_table, @attachments_index]

  def validate_connection!(connection) do
    connection |> SqliteQuery.rows(@query, [], max_rows: 8) |> validate_rows!()
  end

  def validate_rows!([]), do: :absent

  def validate_rows!(rows) do
    expected = [
      ["index", @attachments_index, @attachments_table, @attachments_index_sql],
      ["index", @index, @table, @index_sql],
      ["index", "sqlite_autoindex_cli_attachment_staging_1", @attachments_table, nil],
      ["index", "sqlite_autoindex_cli_command_ledger_1", @table, nil],
      ["table", @attachments_table, @attachments_table, @attachments_table_sql],
      ["table", @table, @table, @table_sql]
    ]

    normalized = Enum.map(rows, &normalize_row/1)

    cond do
      normalized == Enum.map(expected, &normalize_row/1) ->
        :present

      normalized ==
          Enum.map(
            [
              ["index", @index, @table, @index_sql],
              ["index", "sqlite_autoindex_cli_command_ledger_1", @table, nil],
              ["table", @table, @table, @table_sql]
            ],
            &normalize_row/1
          ) ->
        :legacy

      true ->
        raise("CLI metadata schema mismatch")
    end
  end

  defp normalize_row([type, name, table, sql]), do: [type, name, table, normalize(sql)]
  defp normalize(nil), do: nil
  defp normalize(sql), do: sql |> String.replace(~r/\s+/, " ") |> String.trim()
end
