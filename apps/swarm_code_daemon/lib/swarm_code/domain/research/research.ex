defmodule SwarmCode.Domain.Research.Research do
  @moduledoc """
  One deep research (spec 24 §2.2). The primary key is an ordinary integer
  because it is the `#2` the user types in `/deep_research 2`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias SwarmCode.Domain.Research.Levels

  @foreign_key_type :binary_id

  @statuses ~w(queued running done failed stopped)
  @question_max 4000

  def statuses, do: @statuses

  schema "researches" do
    field(:question, :string)
    field(:level, :string, default: "medium")
    field(:status, :string, default: "queued")
    field(:title, :string)
    field(:interpretation, :string)
    field(:summary, :string)
    field(:step, :integer, default: 0)
    field(:steps_total, :integer, default: 1)
    field(:fanout, :integer, default: 3)
    field(:dir, :string)
    field(:result_path, :string)
    field(:report_path, :string)
    field(:sources, {:array, :map}, default: [])
    field(:tokens_in, :integer, default: 0)
    field(:tokens_out, :integer, default: 0)
    field(:cost_usd, :float)
    field(:error, :string)
    field(:run_id, :binary_id)
    field(:conversation_id, :binary_id)
    field(:project_id, :binary_id)
    field(:started_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)
    # Spec 40 §1.0: a model of this research's own, over every Settings tier.
    field(:provider_id, :binary_id)
    field(:model, :string)
    field(:effort, :string)
    # Spec 41 §1.0: pinned to the top of the sidebar and the index.
    field(:pinned_at, :utc_datetime_usec)
    # Spec 48 §2: what `report_path` currently *is* — "rendered" (the instant
    # `HtmlRender` one), "designing" (the designed pass is running in the
    # background), "designed", or "failed" (a design ran and produced nothing;
    # the rendered report stands). NULL is a row from before pass 42.
    field(:design_state, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @fields ~w(question level status title interpretation summary step steps_total fanout dir
             result_path report_path sources tokens_in tokens_out cost_usd error run_id
             conversation_id project_id started_at finished_at provider_id model effort
             pinned_at design_state)a

  def changeset(research, attrs) do
    research
    |> cast(attrs, @fields)
    |> update_change(:question, &trim/1)
    |> validate_required([:question])
    |> validate_length(:question, max: @question_max)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:effort, ["low", "medium", "high", "max"])
    |> validate_inclusion(:design_state, ~w(rendered designing designed failed))
    |> validate_change(:level, fn :level, level ->
      if Levels.valid?(level), do: [], else: [level: "is not a research level"]
    end)
    |> put_shape()
  end

  # `steps_total` and `fanout` are frozen from the level at insert: changing the
  # default level later must never reshape a research that is already running.
  # `get_field`, not `get_change` — casting the level a row already has (the
  # default "medium") is not a change, and that left every medium research
  # shaped like a one-round low one.
  defp put_shape(%{data: %{id: nil}} = changeset) do
    level = get_field(changeset, :level)

    changeset
    |> put_change(:steps_total, Levels.steps(level))
    |> put_change(:fanout, Levels.fanout(level))
  end

  defp put_shape(changeset), do: changeset

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value
end
