defmodule SwarmCodeCLI.Demo.PlainDemoTest do
  use ExUnit.Case, async: false
  alias SwarmCodeCLI.Demo.{Plain, FiniteScript}

  test "renderer-free finite demo follows committed steps and exact golden output" do
    {:ok, output} = StringIO.open("")
    {:ok, error} = StringIO.open("")
    assert :ok = Plain.run(:complete, output: output, error: error, timeout: 5_000)

    assert elem(StringIO.contents(output), 1) ==
             File.read!(Path.expand("../../fixtures/plain/three_run_output.txt", __DIR__))

    assert StringIO.contents(error) == {"", ""}
    assert Plain.last_audit().children_after == 0
    assert Plain.last_audit().children_started == 5

    assert Plain.last_audit().invariants == [
             :answer_isolated,
             :retry_isolated,
             :agent_stop_isolated,
             :detach_preserved
           ]

    assert Enum.any?(FiniteScript.steps(:complete), &match?({:command, :retry, _}, &1))
    assert Enum.any?(FiniteScript.steps(:complete), &match?({:command, :stop_agent, _}, &1))
  end

  test "deadline and output failure tear down every owned child" do
    {:ok, output} = StringIO.open("")
    assert {:error, :timeout} = Plain.run(:complete, output: output, error: output, timeout: 1)
    assert Plain.last_audit().children_after == 0
    {:ok, _} = StringIO.close(output)

    assert {:error, :session_failed} =
             Plain.run(:complete, output: output, error: output, timeout: 5_000)

    assert Plain.last_audit().children_after == 0
  end

  test "unknown scripts and options are rejected without spawning a tree" do
    assert {:error, :script_failed} = Plain.run(:unknown, [])

    assert {:error, :script_failed} =
             Plain.run(:complete,
               output: :standard_io,
               error: :standard_error,
               timeout: 100,
               path: "/tmp/no"
             )
  end
end
