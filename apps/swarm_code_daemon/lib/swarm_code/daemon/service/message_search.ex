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

  @doc """
  cli020 C20 (competitors-19): the prompt history of `project_id` for Ctrl-R:
  at most 50 distinct texts of non-superseded user messages of its
  conversations, newest first, in one query. A query of 3 characters or more
  uses the FTS index (each word a phrase, the last a prefix); a shorter one is
  a prefix of the first 200 bytes; an empty one lists the newest. Each text is
  its first 2 KB; `bytes` is its size and `message_id` the newest message
  with it.
  """
  @spec prompts(String.t(), String.t()) :: [map()]
  def prompts(project_id, query) when is_binary(project_id) and is_binary(query) do
    trimmed = String.trim(query)

    {match, args} =
      cond do
        String.length(trimmed) >= 3 and fts_query(trimmed) != "" ->
          {"m.rowid IN (SELECT rowid FROM messages_fts WHERE messages_fts MATCH ?2)",
           [fts_query(trimmed)]}

        trimmed != "" ->
          {"substr(m.content, 1, 200) LIKE ?2 ESCAPE '\\'", [like_prefix(trimmed)]}

        true ->
          {"?2 = ''", [""]}
      end

    sql = """
    SELECT substr(m.content, 1, 2048), length(cast(m.content as blob)),
           m.conversation_id, m.id, MAX(m.inserted_at) AS at
    FROM messages m
    JOIN conversations c ON c.id = m.conversation_id
    WHERE c.project_id = ?1 AND c.research_id IS NULL
      AND m.role = 'user' AND m.superseded_at IS NULL
      AND m.content != ''
      AND #{match}
    GROUP BY m.content
    ORDER BY at DESC
    LIMIT 50
    """

    case Repo.query(sql, [project_id | args]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [text, bytes, conversation_id, message_id, at] ->
          %{
            text: text,
            bytes: bytes,
            conversation_id: conversation_id,
            message_id: message_id,
            at: unix_ms(at)
          }
        end)

      _ ->
        []
    end
  end

  defp unix_ms(%DateTime{} = at), do: DateTime.to_unix(at, :millisecond)
  defp unix_ms(%NaiveDateTime{} = at), do: unix_ms(DateTime.from_naive!(at, "Etc/UTC"))

  defp unix_ms(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, at, _} ->
        unix_ms(at)

      _ ->
        case NaiveDateTime.from_iso8601(at) do
          {:ok, at} -> unix_ms(at)
          _ -> 0
        end
    end
  end

  defp unix_ms(_), do: 0

  defp like_prefix(text),
    do: String.replace(text, ~r/[\\%_]/, fn char -> "\\" <> char end) <> "%"

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
