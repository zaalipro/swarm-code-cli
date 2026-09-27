defmodule SwarmCodeCLI.UI.DataSource.C75AgentSummaryDTOTest do
  @moduledoc "Pass 75: AgentSummary's five optional keys decode, default and keep their bounds."
  use ExUnit.Case, async: true
  import SwarmCodeCLI.TestSupport.HiveWire
  alias SwarmCodeCLI.UI.DataSource.DTO

  test "an old daemon's body decodes with the five keys nil" do
    assert {:ok, agent} = DTO.AgentSummary.decode(agent_summary())

    assert %{turn: nil, max_turns: nil, summary: nil, summary_rev: nil, last_words: nil} =
             agent
  end

  test "a pass-75 body carries turns, the summary and the last words" do
    map =
      Map.merge(agent_summary(), %{
        "turn" => 21,
        "max_turns" => 30,
        "summary" => "checking app data",
        "summary_rev" => 5,
        "last_words" => "Deps are all ok."
      })

    assert {:ok, agent} = DTO.AgentSummary.decode(map)

    assert %{
             turn: 21,
             max_turns: 30,
             summary: "checking app data",
             summary_rev: 5,
             last_words: "Deps are all ok."
           } = agent
  end

  test "a summary over 80 bytes is rejected" do
    map = Map.put(agent_summary(), "summary", String.duplicate("a", 81))
    assert {:error, _} = DTO.AgentSummary.decode(map)
  end

  test "a negative max_turns is rejected" do
    map = Map.put(agent_summary(), "max_turns", -1)
    assert {:error, _} = DTO.AgentSummary.decode(map)
  end
end
