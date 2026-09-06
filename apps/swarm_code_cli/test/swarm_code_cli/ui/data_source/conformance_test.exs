defmodule SwarmCodeCLI.UI.DataSource.ConformanceTest do
  use ExUnit.Case, async: true
  alias SwarmCode.Protocol.Scope
  alias SwarmCodeCLI.UI.DataSource.{DataBridge, Delivery}

  test "bridge validates epoch and exact typed delivery without effects" do
    d = %Delivery{
      kind: :closed,
      watch_ref: "watch",
      request_id: nil,
      scope: %Scope{kind: :global, id: nil, generation: 0},
      generation: 0,
      revision: nil,
      sequence: nil,
      body: nil
    }

    assert {:ok, {:data, ^d}} = DataBridge.normalize({:swarm_code_ui_data, "epoch", d}, "epoch")

    assert {:ignore, :stale_epoch} =
             DataBridge.normalize({:swarm_code_ui_data, "old", d}, "epoch")

    assert {:ignore, :stale_epoch} = DataBridge.normalize({:swarm_code_ui_data, "epoch", d}, nil)

    assert {:error, :invalid_delivery} =
             DataBridge.normalize({:swarm_code_ui_data, "epoch", %{d | generation: 2}}, "epoch")

    assert {:error, :invalid_delivery} = DataBridge.normalize(:unexpected, "epoch")
  end
end
