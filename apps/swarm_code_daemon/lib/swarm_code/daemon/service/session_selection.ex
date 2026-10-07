defmodule SwarmCode.Daemon.Service.SessionSelection do
  @moduledoc "Selects a saved project conversation through the already admitted Repo."
  import Ecto.Query
  alias SwarmCode.Domain.{Conversations, Projects, Repo}
  alias SwarmCode.Domain.Conversations.Conversation
  alias SwarmCode.Domain.Projects.Project
  alias SwarmCode.Tools.Path, as: ProjectPath

  @doc "Resume the latest ordinary conversation, create a new one, or select its exact ID."
  def open(root, options \\ []) do
    with {:ok, selection} <- selection(options),
         {:ok, root} <- project_root(root) do
      Repo.retry(:session_selection, fn ->
        Repo.transaction(
          fn ->
            with {:ok, project, project_created?} <- project(root),
                 {:ok, conversation, conversation_created?} <-
                   conversation(project.id, selection),
                 {:ok, project} <- Projects.touch(project) do
              # cli020 B11: what this call created, for `discard/1`.
              %{
                project: project,
                conversation: conversation,
                created: %{project: project_created?, conversation: conversation_created?}
              }
            else
              {:error, reason} when is_atom(reason) -> Repo.rollback(reason)
              _ -> Repo.rollback(:session_unavailable)
            end
          end,
          mode: :immediate
        )
      end)
    end
  rescue
    _ -> {:error, :session_unavailable}
  end

  defp selection(options) when is_list(options) do
    if Keyword.keyword?(options) and Keyword.keys(options) in [[], [:conversation]] do
      case Keyword.get(options, :conversation, :latest) do
        mode when mode in [:latest, :new] ->
          {:ok, mode}

        id when is_binary(id) ->
          case Ecto.UUID.cast(id) do
            {:ok, id} -> {:ok, id}
            _ -> {:error, :conversation_not_found}
          end

        _ ->
          {:error, :invalid_selection}
      end
    else
      {:error, :invalid_selection}
    end
  end

  defp selection(_), do: {:error, :invalid_selection}

  defp project_root(root) when is_binary(root) do
    with {:ok, path} <- ProjectPath.real_path(root), true <- File.dir?(path) do
      {:ok, path}
    else
      _ -> {:error, :invalid_project}
    end
  end

  defp project_root(_), do: {:error, :invalid_project}

  @doc """
  cli020 B19 (competitors-12): the conversation of the project at `root`
  that `value` names for `--resume`: an exact title, else (6 to 36 id
  characters) a unique id prefix. `{:error, :none}` when nothing matches,
  `{:error, {:ambiguous, count, [{id, title}]}}` (the five newest) when
  several do. Read-only.
  """
  @spec resolve(Path.t(), String.t()) ::
          {:ok, String.t()}
          | {:error, :none | {:ambiguous, pos_integer(), [{String.t(), String.t()}]}}
  def resolve(root, value) when is_binary(root) and is_binary(value) do
    real =
      case ProjectPath.real_path(root) do
        {:ok, real} -> real
        _ -> root
      end

    by_title = matches(real, "c.title = ?2", value)

    found =
      if elem(by_title, 0) == 0 and Regex.match?(~r/\A[0-9a-fA-F-]{6,36}\z/, value),
        do: matches(real, "c.id LIKE ?2 || '%'", String.downcase(value)),
        else: by_title

    case found do
      {1, [{id, _title}]} -> {:ok, id}
      {0, _} -> {:error, :none}
      {n, rows} -> {:error, {:ambiguous, n, rows}}
    end
  end

  defp matches(root, where, value) do
    from =
      "FROM conversations c JOIN projects p ON p.id = c.project_id WHERE p.root_path = ?1 AND "

    %{rows: [[count]]} = Repo.query!("SELECT COUNT(*) " <> from <> where, [root, value])

    %{rows: rows} =
      Repo.query!(
        "SELECT c.id, c.title " <> from <> where <> " ORDER BY c.updated_at DESC LIMIT 5",
        [root, value]
      )

    {count, Enum.map(rows, fn [id, title] -> {id, title} end)}
  end

  @doc """
  cli020 B11 (bugs-11): undoes what `open/2` created when the start fails
  after it (no provider, an unknown `--model`, a first-run error): the
  conversation it created, and the project it created when no conversation
  is left in it. Rows that existed before the call are never touched.
  """
  @spec discard(map()) :: :ok
  def discard(%{created: %{conversation: true}, conversation: conversation} = session) do
    Repo.retry(:session_discard, fn ->
      Repo.transaction(
        fn ->
          Repo.delete_all(from(c in Conversation, where: c.id == ^conversation.id))
          discard_project(session)
        end,
        mode: :immediate
      )
    end)

    :ok
  rescue
    _ -> :ok
  end

  def discard(%{created: %{project: true}} = session) do
    Repo.retry(:session_discard, fn ->
      Repo.transaction(fn -> discard_project(session) end, mode: :immediate)
    end)

    :ok
  rescue
    _ -> :ok
  end

  def discard(_session), do: :ok

  defp discard_project(%{created: %{project: true}, project: project}) do
    others =
      Repo.one(from(c in Conversation, where: c.project_id == ^project.id, select: count(c.id)))

    if others == 0, do: Repo.delete_all(from(p in Project, where: p.id == ^project.id))
  end

  defp discard_project(_session), do: nil

  defp project(root) do
    case Repo.one(from(p in Project, where: p.root_path == ^root, limit: 1)) do
      nil -> created(Projects.create(%{name: Path.basename(root), root_path: root}))
      project -> {:ok, project, false}
    end
  end

  defp created({:ok, row}), do: {:ok, row, true}
  defp created(other), do: other

  defp conversation(project_id, :new), do: created(Conversations.create(project_id))

  defp conversation(project_id, :latest) do
    case Repo.one(
           from(c in Conversation,
             where:
               c.project_id == ^project_id and is_nil(c.research_id) and
                 is_nil(c.scheduled_task_id),
             order_by: [desc: c.updated_at, desc: c.id],
             limit: 1
           )
         ) do
      nil -> created(Conversations.create(project_id))
      conversation -> {:ok, conversation, false}
    end
  end

  defp conversation(project_id, id) do
    case Repo.one(
           from(c in Conversation, where: c.id == ^id and c.project_id == ^project_id, limit: 1)
         ) do
      nil -> {:error, :conversation_not_found}
      conversation -> {:ok, conversation, false}
    end
  end
end
