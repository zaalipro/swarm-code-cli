defmodule SwarmCode.Domain.Projects do
  @moduledoc """
  Project folders.
  """
  import Ecto.Query, warn: false, except: [update: 2]

  alias SwarmCode.Domain.Conversations.Conversation
  alias SwarmCode.Domain.Engine
  alias SwarmCode.Domain.Projects.Project
  alias SwarmCode.Domain.Repo

  # Spec 21 §2.2: the scratch project is never a row of the Projects tree — its
  # conversations live in the sidebar's own `Conversations` section.
  def list do
    from(p in Project,
      where: p.scratch == false,
      order_by: [desc_nulls_last: p.last_opened_at, asc: p.name]
    )
    |> Repo.all()
  end

  @scratch_name "No project"

  @doc "The label the UI shows for a project-less conversation (spec 21 §2.8)."
  def scratch_name, do: @scratch_name

  @doc """
  The hidden project the conversations without a project belong to (spec 21
  §2.3): named `No project`, rooted at `<config dir>/scratch`. Found or created,
  and safe to call from any process.
  """
  def scratch! do
    case scratch() do
      %Project{} = project ->
        project

      nil ->
        root =
          SwarmCode.Domain.Projects.Workspace.ensure_dir!(
            Path.join(SwarmCode.Domain.Paths.config_dir(), "scratch")
          )

        %Project{}
        |> Project.changeset(%{name: @scratch_name, root_path: root})
        |> Ecto.Changeset.put_change(:scratch, true)
        |> Repo.insert()
        |> case do
          {:ok, project} -> project
          # Another window won the race, or the path is already a real project.
          {:error, _changeset} -> Repo.one!(from(p in Project, where: p.scratch == true))
        end
    end
  end

  @doc "The scratch project, or nil when nothing has needed one yet."
  def scratch, do: Repo.one(from(p in Project, where: p.scratch == true, limit: 1))

  @doc "Whether a project (or nil) is the scratch one — i.e. means “no project”."
  def scratch?(%Project{scratch: scratch}), do: scratch == true
  def scratch?(_other), do: false

  @doc "The name to show for a project: `No project` for the scratch one."
  def label(%Project{} = project),
    do: if(scratch?(project), do: @scratch_name, else: project.name)

  def label(_other), do: @scratch_name

  # Spec 36 §B6: ids reach this from client events, so a non-UUID is a miss and
  # not an `Ecto.Query.CastError` that takes the LiveView down.
  def get(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(Project, uuid)
      :error -> nil
    end
  end

  def get!(id), do: Repo.get!(Project, id)

  @doc """
  `get/1` through `SwarmCode.Domain.Cache` (spec 54 §1.3, 54a A2).

  For the engine's hot path only — `Operation.current_mode/1` runs it once per
  tool op (14 308 queries in 54a's fast scenario). `broadcast/0` drops the key,
  so an approval mode changed mid-run still applies to the next op.
  """
  def get_cached(id), do: SwarmCode.Domain.Cache.fetch({:project, id}, fn -> get(id) end)

  def change(%Project{} = project, attrs \\ %{}), do: Project.changeset(project, attrs)

  def create(attrs) do
    case %Project{} |> Project.changeset(attrs) |> Repo.insert() do
      {:ok, project} ->
        broadcast()
        {:ok, project}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def update(%Project{} = project, attrs) do
    case project |> Project.changeset(attrs) |> Repo.update() do
      {:ok, project} ->
        broadcast()
        {:ok, project}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def touch(%Project{} = project), do: update(project, %{last_opened_at: DateTime.utc_now()})

  def delete(%Project{} = project) do
    ids = Repo.all(from(c in Conversation, where: c.project_id == ^project.id, select: c.id))
    Enum.each(ids, &Engine.stop_all/1)
    result = Repo.delete(project)
    broadcast()
    result
  end

  def broadcast do
    # Spec 54 §1.3: invalidated by the broadcast the writers already send.
    SwarmCode.Domain.Cache.invalidate(:project)
    SwarmCode.Domain.PubSub.broadcast(SwarmCode.Domain.PubSub, "projects", {:projects_changed})
  end

  def subscribe, do: SwarmCode.Domain.PubSub.subscribe(SwarmCode.Domain.PubSub, "projects")
end
