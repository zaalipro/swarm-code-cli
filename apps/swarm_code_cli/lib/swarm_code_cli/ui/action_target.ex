defmodule SwarmCodeCLI.UI.ActionTarget do
  @moduledoc "The exact semantic values stored behind opaque renderer action IDs."

  alias SwarmCodeCLI.UI.{Action, Intent}

  @type t :: {:local, Action.t()} | {:intent, Intent.t()}

  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_action_target}
  def validate({:local, action} = target) do
    if match?({:ok, _action}, Action.validate(action)),
      do: {:ok, target},
      else: {:error, :invalid_action_target}
  end

  def validate({:intent, intent} = target) do
    if Intent.valid?(intent), do: {:ok, target}, else: {:error, :invalid_action_target}
  end

  def validate(_target), do: {:error, :invalid_action_target}

  @spec validate!(term()) :: t()
  def validate!(target) do
    case validate(target) do
      {:ok, valid} -> valid
      {:error, :invalid_action_target} -> raise ArgumentError, "invalid action target"
    end
  end
end
