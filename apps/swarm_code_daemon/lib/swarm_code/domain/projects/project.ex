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
    # spec 67 T31 (G44): read-only **on insert**. A folder the user has just
    # pointed SwarmCode at is not yet a folder it may write to or take
    # instructions from; `Projects.trust/1` is the consent, and every row that
    # existed before that task was backfilled as trusted.
    field(:approval_mode, :string, default: "read_only")
    # When the user trusted this project. nil = never; `ProjectContext` gives an
    # untrusted project's AGENTS.md to nobody.
    field(:trusted_at, :utc_datetime_usec)
    field(:last_opened_at, :utc_datetime_usec)
    # Spec 21 §2: the single hidden project that holds the conversations started
    # without one. Set by `Projects.scratch!/0`, never castable from a form.
    field(:scratch, :boolean, default: false)
    # spec 66 T5: command families approved for good in this project, e.g.
    # ["mix test"]. `Always allow` used to be one bit for the whole `:execute`
    # class, for one run — approving `mix test` also approved `rm -rf`.
    field(:auto_approve_prefixes, {:array, :string}, default: [])

    has_many(:conversations, SwarmCode.Domain.Conversations.Conversation)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(project, attrs) do
    project
    |> cast(attrs, [
      :name,
      :root_path,
      :approval_mode,
      :last_opened_at,
      :auto_approve_prefixes
    ])
    |> validate_required([:name, :root_path])
    |> update_change(:root_path, &Path.expand/1)
    |> validate_change(:root_path, fn :root_path, p ->
      if File.dir?(p), do: [], else: [root_path: "path must be an existing directory"]
    end)
    |> validate_inclusion(:approval_mode, ["read_only", "auto", "full_access"])
    |> unique_constraint(:root_path, message: "a project with this path already exists")
  end
end
