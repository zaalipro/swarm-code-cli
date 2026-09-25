defmodule SwarmCode.Daemon.Service.Settings.Result do
  @moduledoc """
  A settings command's answer before it is encoded (pass 74, spec §3.3.1,
  §3.4.2). `results` holds one row per change (≤ 256 for values actions, ≤ 64
  otherwise); `record` the fresh record after a record write (secrets as
  `{set, hint}`); `task` the started task; `confirm` only with
  `:needs_confirmation`.
  """

  defstruct status: :accepted,
            results: [],
            record: nil,
            message: nil,
            task: nil,
            confirm: nil,
            field_errors: []

  @type status :: :accepted | :unchanged | :conflict | :rejected | :needs_confirmation
  @type row :: %{
          target: String.t(),
          status: :accepted | :unchanged | :conflict | :rejected | :skipped,
          value: term(),
          current: term(),
          message: String.t() | nil
        }
  @type t :: %__MODULE__{
          status: status(),
          results: [row()],
          record: map() | nil,
          message: String.t() | nil,
          task: %{task_id: String.t(), action: String.t()} | nil,
          confirm: nil | %{kind: String.t(), items: [String.t()]},
          field_errors: [%{target: String.t(), message: String.t()}]
        }

  @order [:accepted, :unchanged, :needs_confirmation, :conflict, :rejected]

  @doc "The worst status of a list of result rows (skipped rows do not count)."
  @spec worst([row()]) :: status()
  def worst(rows) do
    rows
    |> Enum.map(& &1.status)
    |> Enum.reject(&(&1 == :skipped))
    |> Enum.max_by(&Enum.find_index(@order, fn s -> s == &1 end), fn -> :unchanged end)
    |> case do
      :unchanged ->
        if Enum.all?(rows, &(&1.status == :unchanged)), do: :unchanged, else: :accepted

      status ->
        status
    end
  end

  @doc "A result row."
  @spec row(String.t(), atom(), keyword()) :: row()
  def row(target, status, opts \\ []) do
    %{
      target: target,
      status: status,
      value: Keyword.get(opts, :value),
      current: Keyword.get(opts, :current),
      message: Keyword.get(opts, :message)
    }
  end
end
