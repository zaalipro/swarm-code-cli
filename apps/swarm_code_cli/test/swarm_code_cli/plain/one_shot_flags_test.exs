defmodule SwarmCodeCLI.Plain.OneShotFlagsTest do
  @moduledoc """
  cli020 B23 (competitors-4): `--output-format stream-json`, `--max-turns N`
  and `--max-budget-usd X` on a one-shot run.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.Test.OneShotHarness
  alias SwarmCodeCLI.Test.OneShotHarness, as: H
  alias SwarmCodeCLI.UI.DataSource.Request

  setup do
    source = start_supervised!({H.Source, self()})
    {:ok, output} = StringIO.open("")
    {:ok, error} = StringIO.open("")
    %{source: source, output: output, error: error}
  end

  defp stop_request do
    assert_receive {:source, {:request, :command, %Request{kind: kind}}}, 5_000
    kind
  end

  test "stream-json: one JSON object per line, the last the summary", context do
    session =
      start(context, format: :stream_json)
      |> accept()
      |> run_update(:running)
      |> upsert(message("hello"))
      |> run_update(:done)

    complete(session, [run(:done)], [message("hello")])
    assert code(session) == 0

    lines = context.output |> text() |> String.split("\n", trim: true)
    decoded = Enum.map(lines, &Jason.decode!/1)
    assert length(decoded) >= 2

    assert %{"type" => "summary", "text" => "hello", "exit_code" => 0, "state" => "done"} =
             List.last(decoded)

    records = Enum.drop(decoded, -1)
    assert Enum.all?(records, &match?(%{"stream" => _, "text" => _}, &1))
    assert Enum.any?(records, &(&1["text"] =~ "hello"))
  end

  test "--max-turns 1 stops a run whose lead starts a second turn", context do
    session =
      start(context, max_turns: 1)
      |> accept()
      |> run_update(:running)
      |> agent_update(1)

    refute_receive {:source, {:request, :command, _}}, 100
    session = agent_update(session, 2)
    assert {:run_control, :stop, run} = stop_request()
    assert run == run_id()

    session = run_update(session, :stopped)
    complete(session, [run(:stopped)], [])
    assert code(session) == 1
    assert text(context.error) =~ "ncode: stopped after 1 turns."
  end

  test "--max-budget-usd stops a run past the budget", context do
    session =
      start(context, max_budget_usd: 0.01)
      |> accept()
      |> run_update(:running, cost_usd: 0.005)

    refute_receive {:source, {:request, :command, _}}, 100
    session = run_update(session, :running, cost_usd: 0.02)
    assert {:run_control, :stop, _} = stop_request()
    session = run_update(session, :stopped, cost_usd: 0.02)
    complete(session, [run(:stopped, cost_usd: 0.02)], [])
    assert code(session) == 1
    assert text(context.error) =~ "ncode: stopped at --max-budget-usd 0.01 (the run cost $0.02)."
  end

  test "an unknown cost is never stopped by the budget, and says so once", context do
    session =
      start(context, max_budget_usd: 0.01)
      |> accept()
      |> run_update(:running)
      |> run_update(:done)

    complete(session, [run(:done)], [])
    assert code(session) == 0
    err = text(context.error)
    assert err =~ "ncode: the provider reports no cost; --max-budget-usd is not enforced."
    assert length(String.split(err, "reports no cost")) == 2
  end
end
