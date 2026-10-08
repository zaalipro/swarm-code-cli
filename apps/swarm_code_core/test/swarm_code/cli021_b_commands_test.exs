defmodule SwarmCode.Cli021BCommandsTest do
  @moduledoc "cli021 B2: the worker slot's commands are /worker_effort and /worker_model."
  use ExUnit.Case, async: true

  alias SwarmCode.Commands

  test "the catalogue lists the worker names and not the old ones" do
    names = Enum.map(Commands.catalogue(), & &1.name)
    assert "worker_effort" in names and "worker_model" in names
    refute "swarm_effort" in names or "swarm_model" in names
    assert Commands.catalogue("/swarm_e") == []
    assert Enum.map(Commands.catalogue("/worker"), & &1.name) == ["worker_effort", "worker_model"]
  end

  test "the old names still parse, as the worker commands" do
    assert {:ok, %{action: :set_effort, target: :swarm, effort: :high, name: "worker_effort"}} =
             Commands.parse("/SWARM_EFFORT high")

    assert {:ok, %{action: :set_model, target: :swarm, model: "p|m", name: "worker_model"}} =
             Commands.parse("/swarm_model p|m")

    assert {:ok, %{action: :show_effort, target: :swarm}} = Commands.parse("/swarm_effort")
    assert {:error, %{type: :invalid_effort}} = Commands.parse("/swarm_effort extreme")
    assert {:error, %{type: :missing_argument}} = Commands.parse("/swarm_model")
  end

  test "model effort lists still limit the alias" do
    assert {:error, %{type: :invalid_effort}} =
             Commands.parse("/swarm_effort max", swarm_efforts: [:low])
  end

  test "a workflow or custom command that really has the old name keeps it" do
    assert {:ok, %{kind: :workflow, action: :launch_workflow, name: "swarm_model"}} =
             Commands.parse("/swarm_model go", workflows: [%{name: "swarm_model"}])
  end

  test "the aliases are public for the client's palette" do
    assert Commands.aliases() == %{
             "swarm_effort" => "worker_effort",
             "swarm_model" => "worker_model"
           }
  end
end
