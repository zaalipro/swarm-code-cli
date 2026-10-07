defmodule SwarmCodeCLI.Cli020.E10ReportOnceTest do
  # cli020 E10 (ux-live-6): a finished swarm's report is drawn once. The
  # daemon sends three copies of the Lead's last words: the Lead agent's
  # node (its result), its last model step, and the run's `swarm` report
  # message (`run_server.ex` writes role "swarm", the backend maps it to an
  # assistant item). The transcript draws them once.
  use ExUnit.Case, async: true

  import SwarmCodeCLI.Cli020EHelpers

  alias SwarmCodeCLI.UI.DataSource.DTO
  alias SwarmCodeCLI.UI.Pass73Helpers, as: H

  @report "Worker report: the router pipes :browser twice; PageController error path untested."

  defp swarm(report_message_text) do
    items = [
      item("u", role: :user, text: "/swarm Audit the router and list test gaps", node_id: "s"),
      item("lead", agent_id: "lead", text: @report),
      item("step-1", kind: :thinking, agent_id: "lead", node_id: "step-1", text: ""),
      item("step-2", kind: :thinking, agent_id: "lead", node_id: "step-2", text: @report),
      item("report", agent_id: "lead", text: report_message_text)
    ]

    run = %{H.run("s", :done, kind: :swarm, title: "Audit the router") | created_sequence: 1}

    H.ready([run],
      columns: 120,
      rows: 40,
      snapshot: %{transcript: %DTO.TranscriptWindow{items: items}}
    )
  end

  defp count(text, needle), do: length(String.split(text, needle)) - 1

  test "equal texts: the report is drawn once" do
    text = swarm(@report) |> screen_text()
    assert count(text, "Worker report: the router pipes") == 1, text
  end

  test "a report with other words is still drawn" do
    text = swarm("Swarm stopped by user.") |> screen_text()
    assert count(text, "Worker report: the router pipes") == 1, text
    assert text =~ "Swarm stopped by user."
  end
end
