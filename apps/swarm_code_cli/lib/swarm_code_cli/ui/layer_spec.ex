defmodule SwarmCodeCLI.UI.LayerSpec do
  @moduledoc "Closed specifications for the fixed layers introduced by the neutral contract."

  alias SwarmCodeCLI.UI.Intent

  @type inspector_tab :: :overview | :agents | :timeline | :changes
  @type t :: :help | {:run_inspector, binary(), inspector_tab()}

  @spec help() :: t()
  def help, do: :help

  @spec run_inspector(binary(), inspector_tab()) :: t()
  def run_inspector(run_id, tab) do
    layer = {:run_inspector, run_id, tab}

    case validate(layer) do
      {:ok, valid} -> valid
      {:error, :invalid_layer_spec} -> raise ArgumentError, "invalid run inspector layer"
    end
  end

  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_layer_spec}
  def validate(:help), do: {:ok, :help}

  def validate({:run_inspector, run_id, tab} = layer)
      when tab in [:overview, :agents, :timeline, :changes] do
    if Intent.valid_id?(run_id), do: {:ok, layer}, else: {:error, :invalid_layer_spec}
  end

  def validate(_layer), do: {:error, :invalid_layer_spec}
end
