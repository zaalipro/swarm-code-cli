defmodule SwarmCode.Domain.Research.Step do
  @moduledoc "One round of a research: what the lead planned and what came back (spec 24 §2.2)."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending running done failed)

  def statuses, do: @statuses

  schema "research_steps" do
    field(:research_id, :integer)
    field(:index, :integer)
    field(:title, :string)
    field(:headline, :string)
    field(:tasks, {:array, :map}, default: [])
    field(:notes, {:array, :map}, default: [])
    field(:status, :string, default: "pending")
    field(:started_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @fields ~w(research_id index title headline tasks notes status started_at finished_at)a

  def changeset(step, attrs) do
    step
    |> cast(attrs, @fields)
    |> validate_required([:research_id, :index])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:research_id, :index])
  end
end
