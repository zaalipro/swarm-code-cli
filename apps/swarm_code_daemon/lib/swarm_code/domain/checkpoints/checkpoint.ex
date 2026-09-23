defmodule SwarmCode.Domain.Checkpoints.Checkpoint do
  @moduledoc "The content of a file just before an agent overwrote it."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "checkpoints" do
    field(:conversation_id, :binary_id)
    field(:run_id, :binary_id)
    field(:node_id, :binary_id)
    field(:path, :string)
    field(:previous_content, :string)
    field(:restorable, :boolean, default: true)
    field(:inserted_at, :utc_datetime_usec)
  end

  # spec 68 T3: ownership IDs removed from cast/3; set via put_change in
  # Checkpoints.insert/3 from trusted runtime context.
  @fields ~w(path previous_content restorable inserted_at)a

  def changeset(checkpoint, attrs) do
    checkpoint
    |> cast(attrs, @fields)
  end

  @doc false
  def validate(changeset) do
    validate_required(changeset, [:conversation_id, :path])
  end
end
