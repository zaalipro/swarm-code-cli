defmodule SwarmCode.Daemon.Service.Pass73Qa2PanelFactsTest do
  @moduledoc """
  pass73 G2 (CLI QA #2 Q2-07): the needs-you band named a workflow-run
  approval by its raw tool, "workflow run", while the card said "run the
  workflow /format-and-test". The band's literal request is the workflow's
  command now, or "a one-off workflow".
  """
  use ExUnit.Case, async: true
  alias SwarmCode.Daemon.Service.PanelFacts, as: Facts

  defp approval(node, preview) do
    %{
      "kind" => "approval",
      "node_id" => node,
      "created_at" => 1,
      "approval" => %{
        "tool" => "workflow_run",
        "command" => nil,
        "arguments_preview" => preview,
        "reason" => "",
        "agent_id" => nil,
        "requested_at" => 1
      }
    }
  end

  test "a workflow-run request reads as the workflow's command" do
    band =
      Facts.needs_you(
        [
          approval("op1", ~s({"name":"format-and-test","args":{},"continue":true})),
          approval("op2", ~s({"source":"phase :a","budget":2}))
        ],
        %{},
        %{},
        []
      )

    assert [
             %{"text" => "/format-and-test", "tool" => "workflow_run"},
             %{"text" => "a one-off workflow"}
           ] = band
  end
end
