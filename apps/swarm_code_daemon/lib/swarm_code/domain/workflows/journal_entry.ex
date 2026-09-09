defmodule SwarmCode.Domain.Workflows.JournalEntry do
  @moduledoc """
  One committed host call of a workflow run (spec 09 §3.1). `seq` is the
  program-order number of the call, `slot` is 0 for single calls, the slot index
  inside a panel and `-1` for the panel's admission marker.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "workflow_journal" do
    field(:run_id, :binary_id)
    field(:seq, :integer)
    field(:slot, :integer)
    field(:fingerprint, :integer)
    field(:kind, :string)
    field(:result, :string)
    field(:inserted_at, :utc_datetime_usec)
  end

  @fields ~w(run_id seq slot fingerprint kind result inserted_at)a

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, @fields)
    |> validate_required([:run_id, :seq, :slot, :fingerprint, :kind, :inserted_at])
  end
end
