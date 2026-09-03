defmodule SwarmCodeCLI.UI.Destination do
  @moduledoc "Closed local navigation destinations."

  alias SwarmCodeCLI.UI.Intent

  @type t :: {:conversation, binary()} | {:run, binary()} | :activity

  @spec conversation(binary()) :: t()
  def conversation(id) do
    if Intent.valid_id?(id),
      do: {:conversation, id},
      else: raise(ArgumentError, "invalid conversation destination")
  end

  @spec run(binary()) :: t()
  def run(id) do
    if Intent.valid_id?(id), do: {:run, id}, else: raise(ArgumentError, "invalid run destination")
  end

  @spec activity() :: t()
  def activity, do: :activity

  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_destination}
  def validate({:conversation, id} = destination) do
    if Intent.valid_id?(id), do: {:ok, destination}, else: {:error, :invalid_destination}
  end

  def validate({:run, id} = destination) do
    if Intent.valid_id?(id), do: {:ok, destination}, else: {:error, :invalid_destination}
  end

  def validate(:activity), do: {:ok, :activity}
  def validate(_destination), do: {:error, :invalid_destination}
end
