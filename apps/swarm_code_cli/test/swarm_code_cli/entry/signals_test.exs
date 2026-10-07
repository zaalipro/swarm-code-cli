defmodule SwarmCodeCLI.Release.SignalsTest do
  @moduledoc """
  cli020 B9 (bugs-5): SIGTERM and SIGHUP reach the session owner as
  `{:shutdown_signal, sig}`; the owner runs its normal close (here: a
  one-shot stops its live run) and the process exits 143 or 129.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.Test.OneShotHarness
  alias SwarmCodeCLI.Release.Signals
  alias SwarmCodeCLI.Test.OneShotHarness, as: H
  alias SwarmCodeCLI.UI.DataSource.Request

  setup do
    source = start_supervised!({H.Source, self()})
    {:ok, output} = StringIO.open("")
    {:ok, error} = StringIO.open("")
    %{source: source, output: output, error: error}
  end

  test "the handler tells the owner, and the exit codes are the shell's" do
    assert :ok = Signals.notify(self(), :sigterm)
    assert_receive {:shutdown_signal, :sigterm}
    assert :ok = Signals.notify(self(), :sighup)
    assert_receive {:shutdown_signal, :sighup}
    assert Signals.exit_code(:sigterm) == 143
    assert Signals.exit_code(:sighup) == 129
  end

  test "a one-shot that gets SIGTERM stops its live run and ends with 143", context do
    session = start(context) |> accept() |> run_update(:running)
    # The owner is the process running OneShot.run/1 (the session's caller).
    Signals.notify(session.task.pid, :sigterm)

    assert_receive {:source, {:request, :command, %Request{kind: {:run_control, :stop, run}}}},
                   5_000

    assert run == H.run_id()
    assert code(session) == 143
    assert text(context.error) =~ "ncode: stopped by SIGTERM"
  end
end
