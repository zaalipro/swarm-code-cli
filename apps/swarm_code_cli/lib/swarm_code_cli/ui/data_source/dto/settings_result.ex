defmodule SwarmCodeCLI.UI.DataSource.DTO.SettingsResult do
  @moduledoc """
  pass74 §3.4.2: the answer to a `settings.command` — the overall `status`, one
  `results` row per change (`%{target, status, value, current, message}`), the
  fresh `record` after a record write (secrets as `{set, hint}`), the started
  `task` (`%{task_id, action}`), a one-sentence `message`, `confirm` (`%{kind,
  items}` with `:needs_confirmation`), `field_errors` (`%{target, message}`) and the
  settings `revision`. Never file content, never a task result (D33).

  `corrective_action` is the client's own: `:refresh` when this result was built
  from an `outcome` reply (`from_outcome/2`) — whether the write happened is
  unknown and the layer re-queries what it shows.
  """
  alias SwarmCodeCLI.UI.DataSource.AdmissionError
  alias SwarmCodeCLI.UI.DataSource.DTO.{SettingsDecode, SettingsRecord, SettingsTaskView}

  @statuses %{
    "accepted" => :accepted,
    "unchanged" => :unchanged,
    "conflict" => :conflict,
    "rejected" => :rejected,
    "needs_confirmation" => :needs_confirmation,
    "not_found" => :not_found,
    "busy" => :busy,
    "unavailable" => :unavailable,
    "unsupported" => :unsupported
  }
  @row_statuses Map.put(@statuses, "skipped", :skipped)
  @unknown "Couldn't tell whether that was saved; reloading."

  defstruct request_id: nil,
            status: :accepted,
            results: [],
            record: nil,
            task: nil,
            message: nil,
            confirm: nil,
            field_errors: [],
            revision: 0,
            corrective_action: nil

  @type status ::
          :accepted
          | :unchanged
          | :conflict
          | :rejected
          | :needs_confirmation
          | :not_found
          | :busy
          | :unavailable
          | :unsupported
  @type row :: %{
          target: String.t(),
          status: status() | :skipped,
          value: term(),
          current: term(),
          message: String.t() | nil
        }
  @type t :: %__MODULE__{
          request_id: String.t() | nil,
          status: status(),
          results: [row()],
          record: SettingsRecord.t() | nil,
          task: %{task_id: String.t(), action: String.t()} | nil,
          message: String.t() | nil,
          confirm: %{kind: String.t(), items: list()} | nil,
          field_errors: [%{target: String.t(), message: String.t()}],
          revision: non_neg_integer(),
          corrective_action: :refresh | nil
        }

  @doc "The result statuses, wire string → atom."
  @spec statuses() :: %{String.t() => status()}
  def statuses, do: @statuses

  @doc "The words of a result whose outcome is unknown (§3.4.2)."
  @spec unknown_words() :: String.t()
  def unknown_words, do: @unknown

  @doc """
  The words of a settings request the data source could not complete: the
  canonical `AdmissionError` text of its code (never the wire's own message).
  """
  @spec failure_words(AdmissionError.t() | term()) :: String.t()
  def failure_words(%AdmissionError{code: code}) do
    %AdmissionError{message: message} = AdmissionError.new(code)
    message
  rescue
    _ -> "Couldn't read settings right now."
  end

  def failure_words(_error), do: "Couldn't read settings right now."

  @doc """
  §3.4.2 (B3b): an `outcome` reply to a settings command (a ledger replay or
  conflict, `not_allowed`, a Connection deadline) — `:unavailable` (`:rejected` when
  the outcome was rejected) with `corrective_action: :refresh`.
  """
  @spec from_outcome(term(), String.t() | nil) :: t()
  def from_outcome(outcome, request_id) do
    status =
      case outcome do
        %{"status" => "rejected"} -> :rejected
        %{status: :rejected} -> :rejected
        _ -> :unavailable
      end

    %__MODULE__{
      request_id: request_id,
      status: status,
      message: @unknown,
      corrective_action: :refresh
    }
  end

  @spec decode(term()) :: {:ok, t()} | {:error, term()}
  def decode(wire), do: SettingsDecode.run(fn -> decode!(wire) end)

  @doc false
  def decode!(wire) do
    SettingsDecode.map!(wire, 16, :result)
    status = SettingsDecode.enum!(SettingsDecode.fetch!(wire, "status"), @statuses, :status)

    %__MODULE__{
      request_id: SettingsDecode.opt_id!(SettingsDecode.fetch!(wire, "request_id"), :request_id),
      status: status,
      results:
        wire
        |> SettingsDecode.fetch!("results")
        |> SettingsDecode.list!(256, :results)
        |> Enum.map(&row!/1),
      record: record!(SettingsDecode.fetch!(wire, "record")),
      task: task!(SettingsDecode.fetch!(wire, "task")),
      message: SettingsDecode.opt_text!(SettingsDecode.fetch!(wire, "message"), 2_048, :message),
      confirm: confirm!(SettingsDecode.fetch!(wire, "confirm"), status),
      field_errors:
        wire
        |> SettingsDecode.fetch!("field_errors")
        |> SettingsDecode.list!(64, :field_errors)
        |> Enum.map(&field_error!/1),
      revision: SettingsDecode.count!(SettingsDecode.fetch!(wire, "revision"), :revision)
    }
  end

  defp row!(wire) do
    %{
      target: SettingsDecode.text!(SettingsDecode.fetch!(wire, "target"), 256, :row_target),
      status: SettingsDecode.enum!(SettingsDecode.fetch!(wire, "status"), @row_statuses, :row),
      value: SettingsDecode.json!(SettingsDecode.fetch!(wire, "value"), 65_536, :row_value),
      current: SettingsDecode.json!(SettingsDecode.fetch!(wire, "current"), 65_536, :current),
      message: SettingsDecode.opt_text!(SettingsDecode.fetch!(wire, "message"), 2_048, :row)
    }
  end

  defp record!(nil), do: nil
  defp record!(wire), do: SettingsDecode.record!(wire)

  defp task!(nil), do: nil

  defp task!(wire) do
    %{
      task_id: SettingsDecode.text!(SettingsDecode.fetch!(wire, "task_id"), 128, :task_id),
      action: SettingsTaskView.action!(SettingsDecode.fetch!(wire, "action"))
    }
  end

  defp confirm!(nil, _status), do: nil

  defp confirm!(wire, :needs_confirmation) do
    %{
      kind: SettingsDecode.text!(SettingsDecode.fetch!(wire, "kind"), 64, :confirm_kind),
      items:
        wire
        |> SettingsDecode.fetch!("items")
        |> SettingsDecode.list!(32, :confirm_items)
        |> SettingsDecode.json!(4_096, :confirm_items)
    }
  end

  defp confirm!(_wire, _status), do: SettingsDecode.reject!({:confirm, :status})

  defp field_error!(wire) do
    %{
      target: SettingsDecode.text!(SettingsDecode.fetch!(wire, "target"), 256, :field_target),
      message: SettingsDecode.text!(SettingsDecode.fetch!(wire, "message"), 2_048, :field_error)
    }
  end

  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_dto}
  def validate(%__MODULE__{status: status, results: results, field_errors: errors} = result)
      when is_list(results) and length(results) <= 256 and is_list(errors) and
             length(errors) <= 64 do
    if status in Map.values(@statuses) and result.corrective_action in [nil, :refresh],
      do: {:ok, result},
      else: {:error, :invalid_dto}
  end

  def validate(_result), do: {:error, :invalid_dto}
end
