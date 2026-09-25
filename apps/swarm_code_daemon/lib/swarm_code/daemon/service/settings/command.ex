defmodule SwarmCode.Daemon.Service.Settings.Command do
  @moduledoc """
  One `settings.command` (pass 74, spec §3.3.1). `secrets` carries pasted
  values (`[%{slot, value}]`) once per write attempt; `Inspect` prints only
  how many there are, so a crash report never holds one (§3.11).
  """

  defstruct action: nil,
            target: nil,
            attributes: %{},
            expected: nil,
            secrets: [],
            dry_run: false,
            request_id: nil

  @type t :: %__MODULE__{
          action: String.t(),
          target: map() | nil,
          attributes: map(),
          expected: map() | nil,
          secrets: [%{slot: String.t(), value: String.t()}],
          dry_run: boolean(),
          request_id: String.t() | nil
        }

  @doc "A command from the decoded wire params of a `settings.command`."
  @spec from_params(map(), String.t() | nil) :: t()
  def from_params(params, request_id) when is_map(params) do
    %__MODULE__{
      action: params["action"],
      target: params["target"],
      attributes: params["attributes"] || %{},
      expected: params["expected"],
      secrets:
        Enum.map(params["secrets"] || [], fn %{"slot" => slot, "value" => value} ->
          %{slot: slot, value: value}
        end),
      dry_run: params["dry_run"] == true,
      request_id: request_id
    }
  end

  @doc "The value of a secret slot, or :error."
  @spec secret(t(), String.t()) :: {:ok, String.t()} | :error
  def secret(%__MODULE__{secrets: secrets}, slot) do
    case Enum.find(secrets, &(&1.slot == slot)) do
      %{value: value} -> {:ok, value}
      nil -> :error
    end
  end

  @doc "Every secret value (for redaction lists)."
  @spec secret_values(t()) :: [String.t()]
  def secret_values(%__MODULE__{secrets: secrets}), do: Enum.map(secrets, & &1.value)

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(command, opts) do
      shown = %{
        action: command.action,
        target: command.target,
        attributes: command.attributes,
        expected: command.expected,
        dry_run: command.dry_run,
        request_id: command.request_id,
        secrets: "[#{length(command.secrets)} redacted]"
      }

      concat(["#SwarmCode.Daemon.Service.Settings.Command<", to_doc(shown, opts), ">"])
    end
  end
end
