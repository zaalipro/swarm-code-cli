defmodule SwarmCode.Daemon.Pass76ShutdownBudgetTest do
  @moduledoc """
  pass76 cli-signals-ledger: whoever waits for a quit (the session's close,
  the signal watchdog) derives its patience from `Shutdown`'s own phase
  deadlines, and the quit it waits for leaves a live run `stopped`.
  """
  use ExUnit.Case, async: false
  import SwarmCode.Test.C020Backend
  alias SwarmCode.Daemon.Shutdown
  alias SwarmCode.Domain.{Conversations, Engine}

  setup_all do
    setup_world("shutdown-budget")
  end

  test "the budget is the phases' sum and a margin for the steps with no deadline" do
    # session_end hooks 5 s + 1 s grace + 5 s reap + 4 s guardians' final
    # deadline (pass 77 X-1), journal flush 10 s, cleanups 15 s, four teardown
    # waits of 5 s. A phase that grows moves this and the signal watchdog's
    # deadline with it; read this figure when it does.
    assert Shutdown.max_ms() == 60_000
    assert Shutdown.budget_ms() == 69_000
  end

  test "a quit stops a run that is mid-call: its row ends stopped, not running", c do
    {:ok, conv} = Conversations.create(c.project.id)
    {conv, _provider, _server} = provider!(c, conv, fn _turn -> :hang end)
    on_exit(fn -> Engine.stop_all(conv.id) end)
    backend = start_backend(c, conv)

    assert {:ok, %{"value" => %{"status" => "accepted", "identifiers" => [run]}}} =
             send_text(backend, scope(conv), "Hello there")

    assert eventually(fn -> run in Engine.running_run_ids() end)
    assert Conversations.get_run(run).status == "running"

    assert %{stopped: 1, stopped_runs: [%{id: ^run}]} = Shutdown.run(teardown: false)

    assert Engine.running_run_ids() == []
    assert Conversations.get_run(run).status == "stopped"
  end
end
