defmodule SwarmCode.Domain.Workflows.Run do
  @moduledoc """
  The workflow half of a run row (`runs` with `kind: "workflow"`): the frozen
  script and args, the budget, the current phase, the pause/gate state and the
  result (spec 09 §1.1).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:run_id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "workflow_runs" do
    field(:conversation_id, :binary_id)
    field(:definition_name, :string)
    field(:scope, :string)
    field(:display_name, :string)
    field(:source, :string)
    field(:args, :map, default: %{})
    field(:budget, :integer)
    field(:max_live, :integer)
    field(:agents_admitted, :integer, default: 0)
    field(:phases, {:array, :string}, default: [])
    field(:phase_details, :map, default: %{})
    field(:phase, :string)
    field(:pause_kind, :string)
    field(:pause_message, :string)
    field(:gate_question, :string)
    field(:gate_options, {:array, :string}, default: [])
    field(:result, :string)
    field(:logs, {:array, :map}, default: [])
    field(:created_by, :string, default: "user")
    field(:auto_continue, :boolean, default: false)
    field(:launch_message_id, :binary_id)

    timestamps(type: :utc_datetime_usec)
  end

  @fields ~w(run_id conversation_id definition_name scope display_name source args budget
             max_live agents_admitted phases phase_details phase pause_kind pause_message
             gate_question gate_options result logs created_by auto_continue
             launch_message_id)a

  def changeset(run, attrs) do
    run
    |> cast(attrs, @fields)
    |> validate_required([:run_id, :display_name, :source, :budget, :max_live])
    |> validate_number(:budget, greater_than_or_equal_to: 1, less_than_or_equal_to: 1024)
    |> validate_number(:max_live, greater_than_or_equal_to: 1, less_than_or_equal_to: 64)
  end
end
