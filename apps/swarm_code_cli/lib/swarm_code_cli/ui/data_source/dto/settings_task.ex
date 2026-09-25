defmodule SwarmCodeCLI.UI.DataSource.DTO.SettingsTask do
  @moduledoc """
  pass74 §3.4.4: the `settings_task` delta — one settings task's state:
  `task_id`, `action`, `target`, `state`, `elapsed_ms`, `progress` (nil or
  `%{done, total, bytes, step}`), `summary` (nil or a map ≤ 16 384 bytes encoded)
  and `message`. Never the result (D33): that is `settings.query view=task`.
  """
  alias SwarmCodeCLI.UI.DataSource.DTO.{SettingsDecode, SettingsTaskView}

  defstruct task_id: nil,
            action: nil,
            target: nil,
            state: :running,
            elapsed_ms: 0,
            progress: nil,
            summary: nil,
            message: nil

  @type t :: %__MODULE__{
          task_id: String.t(),
          action: String.t(),
          target: map() | nil,
          state: SettingsTaskView.state(),
          elapsed_ms: non_neg_integer(),
          progress:
            %{
              done: non_neg_integer() | nil,
              total: non_neg_integer() | nil,
              bytes: non_neg_integer() | nil,
              step: String.t() | nil
            }
            | nil,
          summary: map() | nil,
          message: String.t() | nil
        }

  @spec decode(term()) :: {:ok, t()} | {:error, term()}
  def decode(wire), do: SettingsDecode.run(fn -> decode!(wire) end)

  @doc false
  def decode!(wire) do
    summary = SettingsDecode.opt_json_map!(SettingsDecode.fetch!(wire, "summary"), 16_384, :sum)

    %__MODULE__{
      task_id: SettingsDecode.text!(SettingsDecode.fetch!(wire, "task_id"), 128, :task_id),
      action: SettingsTaskView.action!(SettingsDecode.fetch!(wire, "action")),
      target: SettingsDecode.opt_json_map!(SettingsDecode.fetch!(wire, "target"), 1_024, :target),
      state:
        SettingsDecode.enum!(
          SettingsDecode.fetch!(wire, "state"),
          SettingsTaskView.states(),
          :task_state
        ),
      elapsed_ms: SettingsDecode.count!(SettingsDecode.fetch!(wire, "elapsed_ms"), :elapsed_ms),
      progress: progress!(SettingsDecode.fetch!(wire, "progress")),
      summary: summary && SettingsDecode.encoded_within!(summary, 16_384, :summary),
      message: SettingsDecode.opt_text!(SettingsDecode.fetch!(wire, "message"), 2_048, :message)
    }
  end

  defp progress!(nil), do: nil

  defp progress!(wire) do
    SettingsDecode.map!(wire, 8, :progress)

    %{
      done: SettingsDecode.opt_count!(Map.get(wire, "done"), :progress),
      total: SettingsDecode.opt_count!(Map.get(wire, "total"), :progress),
      bytes: SettingsDecode.opt_count!(Map.get(wire, "bytes"), :progress),
      step: SettingsDecode.opt_text!(Map.get(wire, "step"), 200, :progress)
    }
  end

  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_dto}
  def validate(%__MODULE__{task_id: id, action: action, state: state} = task)
      when is_binary(id) and is_binary(action) do
    if state in Map.values(SettingsTaskView.states()),
      do: {:ok, task},
      else: {:error, :invalid_dto}
  end

  def validate(_task), do: {:error, :invalid_dto}
end
