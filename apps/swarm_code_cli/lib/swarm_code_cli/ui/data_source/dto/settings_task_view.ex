defmodule SwarmCodeCLI.UI.DataSource.DTO.SettingsTaskView do
  @moduledoc """
  pass74 §3.3.6: the `task` view — one settings task (`task_id`, `action`, `target`,
  `state`, `elapsed_ms`, `message`) and one page of its result: `summary`, `rows`
  (≤ 200; field maps of the action's task-row kind when it has one), `next_cursor`
  and `total`. The result fields are empty while the task runs.
  """
  alias SwarmCode.Settings.{RecordKind, WireBounds}
  alias SwarmCodeCLI.UI.DataSource.DTO.SettingsDecode

  @states %{
    "running" => :running,
    "done" => :done,
    "failed" => :failed,
    "timeout" => :timeout,
    "cancelled" => :cancelled
  }

  defstruct task_id: nil,
            action: nil,
            target: nil,
            state: :running,
            elapsed_ms: 0,
            message: nil,
            summary: nil,
            rows: [],
            next_cursor: nil,
            total: nil

  @type state :: :running | :done | :failed | :timeout | :cancelled
  @type t :: %__MODULE__{
          task_id: String.t(),
          action: String.t(),
          target: map() | nil,
          state: state(),
          elapsed_ms: non_neg_integer(),
          message: String.t() | nil,
          summary: map() | nil,
          rows: [map()],
          next_cursor: String.t() | nil,
          total: non_neg_integer() | nil
        }

  @doc "The task states, wire string → atom."
  @spec states() :: %{String.t() => state()}
  def states, do: @states

  @spec decode(term()) :: {:ok, t()} | {:error, term()}
  def decode(wire), do: SettingsDecode.run(fn -> decode!(wire) end)

  @doc false
  def decode!(wire) do
    action = action!(SettingsDecode.fetch!(wire, "action"))
    result = SettingsDecode.fetch!(wire, "result")

    {summary, rows, cursor, total} =
      case result do
        nil ->
          {nil, [], nil, nil}

        result ->
          {SettingsDecode.opt_json_map!(
             SettingsDecode.fetch!(result, "summary"),
             65_536,
             :summary
           ), rows!(action, SettingsDecode.fetch!(result, "rows")),
           SettingsDecode.opt_text!(SettingsDecode.fetch!(result, "next_cursor"), 256, :cursor),
           SettingsDecode.opt_count!(SettingsDecode.fetch!(result, "total"), :total)}
      end

    %__MODULE__{
      task_id: SettingsDecode.text!(SettingsDecode.fetch!(wire, "task_id"), 128, :task_id),
      action: action,
      target: SettingsDecode.opt_json_map!(SettingsDecode.fetch!(wire, "target"), 1_024, :target),
      state: SettingsDecode.enum!(SettingsDecode.fetch!(wire, "state"), @states, :task_state),
      elapsed_ms: SettingsDecode.count!(SettingsDecode.fetch!(wire, "elapsed_ms"), :elapsed_ms),
      message: SettingsDecode.opt_text!(SettingsDecode.fetch!(wire, "message"), 2_048, :message),
      summary: summary,
      rows: rows,
      next_cursor: cursor,
      total: total
    }
  end

  @doc false
  def action!(action) do
    if action in WireBounds.actions(),
      do: action,
      else: SettingsDecode.reject!({:action, :unknown})
  end

  defp rows!(action, rows) do
    rows = SettingsDecode.list!(rows, 200, :task_rows)

    with name when is_binary(name) <- RecordKind.task_row_kind(action),
         {:ok, kind} <- RecordKind.fetch(name) do
      Enum.map(rows, &SettingsDecode.fields!(kind, &1))
    else
      _ -> Enum.map(rows, &SettingsDecode.json!(&1, 65_536, :task_rows))
    end
  end

  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_dto}
  def validate(%__MODULE__{task_id: id, action: action, rows: rows} = view)
      when is_binary(id) and is_binary(action) and is_list(rows) and length(rows) <= 200,
      do: {:ok, view}

  def validate(_view), do: {:error, :invalid_dto}
end
