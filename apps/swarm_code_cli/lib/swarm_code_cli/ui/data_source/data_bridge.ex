defmodule SwarmCodeCLI.UI.DataSource.DataBridge do
  @moduledoc "Pure validation of the owner-facing envelope for an immutable source epoch."
  alias SwarmCodeCLI.UI.DataSource.Delivery
  alias SwarmCodeCLI.UI.Intent

  def normalize({:swarm_code_ui_data, epoch, delivery}, expected) do
    cond do
      not Intent.valid_id?(epoch) ->
        {:error, :invalid_delivery}

      epoch != expected ->
        {:ignore, :stale_epoch}

      true ->
        case Delivery.validate(delivery) do
          {:ok, valid} -> {:ok, {:data, valid}}
          _ -> {:error, :invalid_delivery}
        end
    end
  end

  def normalize(_, _), do: {:error, :invalid_delivery}
end
