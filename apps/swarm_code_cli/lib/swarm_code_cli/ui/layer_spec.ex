defmodule SwarmCodeCLI.UI.LayerSpec do
  @moduledoc "Closed specifications for the fixed layers introduced by the neutral contract."

  alias SwarmCodeCLI.UI.Intent

  @type inspector_tab :: :overview | :agents | :timeline | :changes
  @type t ::
          :help
          | {:run_inspector, binary(), inspector_tab()}
          | {:question | :approval, binary()}
          | {:unsent_changes, :detach | :plain}
          | {:confirm_intent, Intent.t()}
          | {:detail, binary(), binary()}
          | {:switcher | :action_menu | :jump | :region_filter, binary()}

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
  def validate({:detail, run_id, ref_id} = layer),
    do:
      if(Intent.valid_id?(run_id) and Intent.valid_id?(ref_id),
        do: {:ok, layer},
        else: {:error, :invalid_layer_spec}
      )

  def validate(:help), do: {:ok, :help}

  def validate({:run_inspector, run_id, tab} = layer)
      when tab in [:overview, :agents, :timeline, :changes] do
    if Intent.valid_id?(run_id), do: {:ok, layer}, else: {:error, :invalid_layer_spec}
  end

  def validate({kind, id} = layer)
      when kind in [:question, :approval, :switcher, :action_menu, :jump, :region_filter],
      do: if(Intent.valid_id?(id), do: {:ok, layer}, else: {:error, :invalid_layer_spec})

  def validate({:confirm_intent, {:run_control, :stop, _} = intent} = layer),
    do: if(Intent.valid?(intent), do: {:ok, layer}, else: {:error, :invalid_layer_spec})

  def validate({:confirm_intent, {:stop_agent, _, _, _} = intent} = layer),
    do: if(Intent.valid?(intent), do: {:ok, layer}, else: {:error, :invalid_layer_spec})

  def validate({:unsent_changes, path} = layer) when path in [:detach, :plain], do: {:ok, layer}

  def validate(_layer), do: {:error, :invalid_layer_spec}
end
