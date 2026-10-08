defmodule SwarmCode.Cli022XCommandsTest do
  @moduledoc """
  cli022 F2: `/effort default` and `/worker_effort default` clear the
  conversation's effort (nil follows the global default), whatever levels the
  model offers.
  """
  use ExUnit.Case, async: true

  alias SwarmCode.Commands

  test "default parses as a set_effort with a nil effort, for both slots" do
    assert {:ok, %{action: :set_effort, target: :chat, effort: nil, name: "effort"}} =
             Commands.parse("/effort default")

    assert {:ok, %{action: :set_effort, target: :swarm, effort: nil, name: "worker_effort"}} =
             Commands.parse("/worker_effort DEFAULT")

    assert {:ok, %{action: :set_effort, target: :swarm, effort: nil}} =
             Commands.parse("/swarm_effort default")
  end

  test "default needs no listed level and does not depend on the model's levels" do
    assert {:ok, %{action: :set_effort, effort: nil}} =
             Commands.parse("/effort default", efforts: [:low])

    assert {:ok, %{action: :set_effort, effort: nil}} =
             Commands.parse("/worker_effort default", swarm_efforts: [])
  end

  test "the usage lists default and bad words still fail" do
    assert Enum.find(Commands.catalogue(), &(&1.name == "effort")).args =~ "default"
    assert Enum.find(Commands.catalogue(), &(&1.name == "worker_effort")).args =~ "default"
    assert {:error, %{type: :invalid_effort}} = Commands.parse("/effort defaults")
  end
end
