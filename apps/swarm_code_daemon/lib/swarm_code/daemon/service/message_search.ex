defmodule SwarmCode.Daemon.Service.MessageSearch do
  @moduledoc """
  cli020 C8/C20: project-scoped reads over the synced `messages_fts` index.

  `Conversations.search/2` (synced, desktop) filters by project after its
  LIMIT, so another project's hits could fill every slot and this project's
  looked absent. These queries put the project filter in SQL, before the
  limit. The FTS query is built exactly as the desktop builds it
  (`Conversations.sanitize_fts/1`, private there): every word becomes the
  quoted phrase of its word runs, the last one a prefix.
  """
  alias SwarmCode.Domain.Repo

  @doc "One row per conversation of `project_id`, best match first (≤ `limit`)."
  @spec conversations(String.t(), String.t(), pos_integer()) :: [map()]
  def conversations(project_id, query, limit) when is_binary(project_id) do
    case fts_query(query) do
      "" ->
        []

      safe ->
        winners = """
        SELECT m.conversation_id, c.title, c.updated_at, messages_fts.rowid,
               MIN(messages_fts.rank) AS r
        FROM messages_fts
        JOIN messages m ON m.rowid = messages_fts.rowid
        JOIN conversations c ON c.id = m.conversation_id
        WHERE messages_fts MATCH ?1
          AND c.project_id = ?2
          AND c.research_id IS NULL
          AND m.superseded_at IS NULL
        GROUP BY m.conversation_id
        ORDER BY r
        LIMIT ?3
        """

        case Repo.query(winners, [safe, project_id, limit]) do
          {:ok, %{rows: [_ | _] = rows}} ->
            snippets = snippets(safe, Enum.map(rows, &Enum.at(&1, 3)))

            Enum.map(rows, fn [id, title, updated_at, rowid, _rank] ->
              %{
                conversation_id: id,
                title: title || "Untitled",
                snippet: Map.get(snippets, rowid) || "",
                updated_at: updated_at
              }
            end)

          _ ->
            []
        end
    end
  end

  defp snippets(safe, rowids) do
    placeholders = Enum.map_join(2..(length(rowids) + 1)//1, ", ", &"?#{&1}")

    sql = """
    SELECT messages_fts.rowid, snippet(messages_fts, 0, '', '', '...', 20)
    FROM messages_fts
    WHERE messages_fts MATCH ?1 AND messages_fts.rowid IN (#{placeholders})
    """

    case Repo.query(sql, [safe | rowids]) do
      {:ok, %{rows: rows}} -> Map.new(rows, fn [rowid, snippet] -> {rowid, snippet} end)
      _ -> %{}
    end
  end

  @doc "The FTS5 query the desktop builds from typed words (\"\" for none)."
  @spec fts_query(term()) :: String.t()
  def fts_query(query) do
    phrases =
      query
      |> to_string()
      |> String.split()
      |> Enum.map(fn word -> word |> String.replace(~r/[^\w]+/u, " ") |> String.trim() end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&("\"" <> &1 <> "\""))

    case phrases do
      [] -> ""
      phrases -> Enum.join(phrases, " ") <> "*"
    end
  end
end
