defmodule SwarmCode.Domain.Scheduled.Task do
  @moduledoc """
  A prompt the app runs on its own: once, on a simple recurrence, or on a cron
  expression. `next_run_at` is always stored in UTC; the human-facing fields
  (`time_of_day`, `weekdays`, `day_of_month`, `cron`) are read in `timezone`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds ~w(chat swarm workflow)
  @modes ~w(build plan)
  @schedule_kinds ~w(once daily weekly monthly cron)
  @colors ~w(orange violet teal green pink yellow)

  schema "scheduled_tasks" do
    field(:name, :string)
    field(:prompt, :string)
    field(:kind, :string, default: "chat")
    field(:mode, :string, default: "build")
    field(:schedule_kind, :string, default: "daily")
    field(:run_at, :utc_datetime)
    field(:time_of_day, :string, default: "09:00")
    field(:weekdays, {:array, :integer}, default: [])
    field(:day_of_month, :integer)
    field(:cron, :string)
    field(:timezone, :string)
    field(:color, :string, default: "orange")
    field(:enabled, :boolean, default: true)
    field(:catch_up, :boolean, default: true)
    field(:provider_id, :binary_id)
    field(:model, :string)
    field(:effort, :string)
    field(:workflow_name, :string)
    field(:workflow_args, :map, default: %{})
    field(:last_run_at, :utc_datetime)
    field(:next_run_at, :utc_datetime)

    belongs_to(:project, SwarmCode.Domain.Projects.Project)
    has_many(:runs, SwarmCode.Domain.Scheduled.Run, foreign_key: :task_id)

    timestamps(type: :utc_datetime_usec)
  end

  def kinds, do: @kinds
  def modes, do: @modes
  def schedule_kinds, do: @schedule_kinds
  def colors, do: @colors

  @fields ~w(name prompt kind project_id mode schedule_kind run_at time_of_day weekdays
             day_of_month cron timezone color enabled catch_up last_run_at next_run_at
             provider_id model effort workflow_name workflow_args)a

  def changeset(task, attrs) do
    task
    |> cast(attrs, @fields)
    |> update_change(:name, &trim/1)
    |> update_change(:prompt, &trim/1)
    |> update_change(:weekdays, &clean_weekdays/1)
    |> put_default(:timezone, SwarmCode.Domain.Scheduler.Next.local_zone())
    |> validate_required([:name, :project_id, :kind, :schedule_kind, :timezone])
    |> validate_workflow()
    |> validate_length(:name, max: 120)
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:mode, @modes)
    |> validate_inclusion(:schedule_kind, @schedule_kinds)
    |> validate_inclusion(:color, @colors)
    |> validate_zone()
    |> validate_schedule()
  end

  defp trim(nil), do: nil
  defp trim(s) when is_binary(s), do: String.trim(s)

  defp clean_weekdays(nil), do: []

  defp clean_weekdays(list) when is_list(list) do
    list
    |> Enum.map(&to_weekday/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp clean_weekdays(_), do: []

  defp to_weekday(n) when is_integer(n) and n in 1..7, do: n

  defp to_weekday(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} when n in 1..7 -> n
      _ -> nil
    end
  end

  defp to_weekday(_), do: nil

  defp put_default(changeset, field, value) do
    case get_field(changeset, field) do
      nil -> put_change(changeset, field, value)
      "" -> put_change(changeset, field, value)
      _ -> changeset
    end
  end

  defp validate_zone(changeset) do
    zone = get_field(changeset, :timezone)

    if is_binary(zone) and match?({:ok, _}, DateTime.shift_zone(DateTime.utc_now(), zone)) do
      changeset
    else
      add_error(changeset, :timezone, "is not a known time zone")
    end
  end

  defp validate_schedule(changeset) do
    case get_field(changeset, :schedule_kind) do
      "once" -> validate_required(changeset, [:run_at])
      "daily" -> validate_time_of_day(changeset)
      "weekly" -> changeset |> validate_time_of_day() |> validate_weekdays()
      "monthly" -> changeset |> validate_time_of_day() |> validate_day_of_month()
      "cron" -> validate_cron(changeset)
      _ -> changeset
    end
  end

  defp validate_time_of_day(changeset) do
    changeset
    |> validate_required([:time_of_day])
    |> validate_format(:time_of_day, ~r/^([01]\d|2[0-3]):[0-5]\d$/,
      message: "must look like 09:00"
    )
  end

  defp validate_weekdays(changeset) do
    case get_field(changeset, :weekdays) do
      [_ | _] -> changeset
      _ -> add_error(changeset, :weekdays, "pick at least one day")
    end
  end

  defp validate_day_of_month(changeset) do
    changeset
    |> validate_required([:day_of_month])
    |> validate_inclusion(:day_of_month, 1..31, message: "must be between 1 and 31")
  end

  defp validate_cron(changeset) do
    changeset = validate_required(changeset, [:cron])

    case get_field(changeset, :cron) do
      nil ->
        changeset

      expr ->
        case SwarmCode.Domain.Scheduler.Cron.parse(expr) do
          {:ok, _} -> changeset
          {:error, reason} -> add_error(changeset, :cron, reason)
        end
    end
  end

  # A workflow task carries the definition name instead of a prompt.
  defp validate_workflow(changeset) do
    if get_field(changeset, :kind) == "workflow" do
      changeset
      |> validate_required([:workflow_name])
      |> put_default(:prompt, "/" <> to_string(get_field(changeset, :workflow_name)))
    else
      validate_required(changeset, [:prompt])
    end
  end
end
