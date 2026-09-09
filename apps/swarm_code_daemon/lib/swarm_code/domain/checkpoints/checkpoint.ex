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

  @fields ~w(conversation_id run_id node_id path previous_content restorable inserted_at)a

  def changeset(checkpoint, attrs) do
    checkpoint
    |> cast(attrs, @fields)
    |> validate_required([:conversation_id, :path])
  end
end
