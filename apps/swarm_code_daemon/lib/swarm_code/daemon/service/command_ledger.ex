defmodule SwarmCode.Daemon.Service.CommandLedger do
  @moduledoc """
  CLI-only durable mutation identity ledger. It is created in the admitted Repo
  connection with `IF NOT EXISTS`; it is intentionally outside the canonical web
  migration manifest. A processing row is never replayed after a restart.
  """
  alias SwarmCode.Domain.Repo
  alias Ecto.Adapters.SQL

  def ensure! do
    {:ok, :ok} =
      Repo.transaction(fn ->
        alias SwarmCode.Daemon.Schema.CliMetadata

        case SQL.query!(Repo, CliMetadata.query(), []).rows |> CliMetadata.validate_rows!() do
          :absent ->
            SQL.query!(Repo, CliMetadata.table_sql(), [])
            SQL.query!(Repo, CliMetadata.index_sql(), [])
            SQL.query!(Repo, CliMetadata.attachments_table_sql(), [])
            SQL.query!(Repo, CliMetadata.attachments_index_sql(), [])
            :ok

          :legacy ->
            SQL.query!(Repo, CliMetadata.attachments_table_sql(), [])
            SQL.query!(Repo, CliMetadata.attachments_index_sql(), [])
            :ok

          :present ->
            :ok
        end
      end)

    :ok
  end

  @doc "Persist an attachment staged for the next message in this conversation."
  def stage_attachment(project_id, conversation_id, attachment_id)
      when is_binary(project_id) and is_binary(conversation_id) and is_binary(attachment_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

    SQL.query(
      Repo,
      "INSERT OR IGNORE INTO cli_attachment_staging (project_id, conversation_id, attachment_id, inserted_at) VALUES (?, ?, ?, ?)",
      [project_id, conversation_id, attachment_id, now]
    )

    :ok
  end

  @doc "Load staged attachment ids for a conversation after a backend restart."
  def staged_attachments(project_id, conversation_id)
      when is_binary(project_id) and is_binary(conversation_id) do
    case SQL.query(
           Repo,
           "SELECT attachment_id FROM cli_attachment_staging WHERE project_id = ? AND conversation_id = ? ORDER BY inserted_at, attachment_id LIMIT 4",
           [project_id, conversation_id]
         ) do
      {:ok, %{rows: rows}} -> Enum.map(rows, &List.first/1)
      _ -> []
    end
  end

  @doc "Consume staged attachment ids after a message starts."
  def consume_attachments(project_id, conversation_id, attachment_ids)
      when is_binary(project_id) and is_binary(conversation_id) and is_list(attachment_ids) do
    ids = attachment_ids |> Enum.filter(&is_binary/1) |> Enum.uniq()

    if ids != [] do
      placeholders = Enum.map_join(ids, ",", fn _ -> "?" end)

      SQL.query(
        Repo,
        "DELETE FROM cli_attachment_staging WHERE project_id = ? AND conversation_id = ? AND attachment_id IN (" <>
          placeholders <> ")",
        [project_id, conversation_id | ids]
      )
    end

    :ok
  end

  @doc "Admit a mutation exactly once; a processing row is unresolved and never replayed."
  def admit(project_id, request_id, scope, fingerprint) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

    result =
      SQL.query(
        Repo,
        """
          INSERT INTO cli_command_ledger
            (project_id, request_id, scope_kind, scope_id, scope_generation, fingerprint, status, inserted_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, 'processing', ?, ?)
        """,
        [
          project_id,
          request_id,
          Atom.to_string(scope.kind),
          scope.id,
          scope.generation,
          fingerprint,
          now,
          now
        ]
      )

    case result do
      {:ok, %{num_rows: 1}} -> :new
      {:error, _} -> existing(project_id, request_id, fingerprint)
    end
  end

  def complete(project_id, request_id, response) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
    encoded = Jason.encode!(pack(response))
    if byte_size(encoded) > 131_072, do: raise("command outcome exceeds ledger bound")

    {:ok, %{num_rows: 1}} =
      SQL.query(
        Repo,
        "UPDATE cli_command_ledger SET status = 'completed', response_json = ?, updated_at = ? WHERE project_id = ? AND request_id = ? AND status = 'processing'",
        [encoded, now, project_id, request_id]
      )

    :ok
  end

  defp pack({:ok, body}), do: %{"tag" => "ok", "body" => body}
  defp pack({:error, body}), do: %{"tag" => "error", "body" => body}
  defp unpack(%{"tag" => "ok", "body" => body}), do: {:ok, body}
  defp unpack(%{"tag" => "error", "body" => body}), do: {:error, body}

  defp existing(project_id, request_id, fingerprint) do
    case SQL.query(
           Repo,
           "SELECT fingerprint, status, CASE WHEN length(cast(response_json as blob)) <= 131072 THEN response_json END FROM cli_command_ledger WHERE project_id = ? AND request_id = ?",
           [project_id, request_id]
         ) do
      {:ok, %{rows: [[^fingerprint, "completed", json]]}} when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, %{"tag" => tag, "body" => body} = packed}
          when tag in ["ok", "error"] and is_map(body) ->
            {:replay, unpack(packed)}

          _ ->
            {:unresolved, :unknown_outcome}
        end

      {:ok, %{rows: [[^fingerprint, "completed", _]]}} ->
        {:unresolved, :unknown_outcome}

      {:ok, %{rows: [[^fingerprint, "processing", _]]}} ->
        {:unresolved, :unknown_outcome}

      {:ok, %{rows: [[_other, _, _]]}} ->
        {:conflict, :request_conflict}

      _ ->
        {:unresolved, :unknown_outcome}
    end
  end
end
