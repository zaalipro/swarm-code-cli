defmodule SwarmCode.Domain.Projects.Project do
  @moduledoc """
  A project directory the swarm works in.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "projects" do
    field(:name, :string)
    field(:root_path, :string)
    field(:approval_mode, :string, default: "auto")
    field(:last_opened_at, :utc_datetime_usec)
    # Spec 21 §2: the single hidden project that holds the conversations started
    # without one. Set by `Projects.scratch!/0`, never castable from a form.
    field(:scratch, :boolean, default: false)

    has_many(:conversations, SwarmCode.Domain.Conversations.Conversation)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :root_path, :approval_mode, :last_opened_at])
    |> validate_required([:name, :root_path])
    |> update_change(:root_path, &Path.expand/1)
    |> validate_change(:root_path, fn :root_path, p ->
      if File.dir?(p), do: [], else: [root_path: "path must be an existing directory"]
    end)
    |> validate_inclusion(:approval_mode, ["read_only", "auto", "full_access"])
    |> unique_constraint(:root_path, message: "a project with this path already exists")
  end
end
