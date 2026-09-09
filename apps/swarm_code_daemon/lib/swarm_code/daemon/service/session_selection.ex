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
            with {:ok, project} <- project(root),
                 {:ok, conversation} <- conversation(project.id, selection),
                 {:ok, project} <- Projects.touch(project) do
              %{project: project, conversation: conversation}
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

  defp project(root) do
    case Repo.one(from(p in Project, where: p.root_path == ^root, limit: 1)) do
      nil -> Projects.create(%{name: Path.basename(root), root_path: root})
      project -> {:ok, project}
    end
  end

  defp conversation(project_id, :new), do: Conversations.create(project_id)

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
      nil -> Conversations.create(project_id)
      conversation -> {:ok, conversation}
    end
  end

  defp conversation(project_id, id) do
    case Repo.one(
           from(c in Conversation, where: c.id == ^id and c.project_id == ^project_id, limit: 1)
         ) do
      nil -> {:error, :conversation_not_found}
      conversation -> {:ok, conversation}
    end
  end
end
