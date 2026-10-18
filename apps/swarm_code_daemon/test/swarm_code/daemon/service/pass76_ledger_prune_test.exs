defmodule SwarmCode.Daemon.Service.Pass76LedgerPruneTest do
  @moduledoc """
  pass76 cli-signals-ledger: the persisted backend prunes the command ledger
  on a timer of its own while the session lives, not only when it starts.
  Each pass is a task under the job supervisor (one at a time), and stopping
  the backend leaves neither the timer nor a pass behind.
  """
  use ExUnit.Case, async: false
  import SwarmCode.Test.C020Backend
  alias Ecto.Adapters.SQL
  alias SwarmCode.Daemon.Service.CommandLedger
  alias SwarmCode.Domain.{Conversations, Repo}

  setup_all do
    setup_world("ledger-prune")
  end

  setup c do
    {:ok, conv} = Conversations.create(c.project.id)
    :ok = CommandLedger.ensure!()
    %{conversation: conv}
  end

  # A completed row last touched eight days ago: older than the cutoff.
  defp old_row!(c, id) do
    :new = CommandLedger.admit(c.project.id, id, scope(c.conversation), "f")
    :ok = CommandLedger.complete(c.project.id, id, {:ok, %{"value" => %{}}})
    old = DateTime.utc_now() |> DateTime.add(-8 * 86_400) |> DateTime.to_iso8601()

    SQL.query!(Repo, "UPDATE cli_command_ledger SET updated_at = ? WHERE request_id = ?", [
      old,
      id
    ])
  end

  defp rows(id) do
    %{rows: [[n]]} =
      SQL.query!(Repo, "SELECT count(*) FROM cli_command_ledger WHERE request_id = ?", [id])

    n
  end

  # Waits until the backend's timer has fired `n` more times; each firing
  # arms a new one, so the ref changes.
  defp ticks(backend, n), do: ticks(backend, :sys.get_state(backend).ledger_timer, n)
  defp ticks(_backend, _last, 0), do: :ok

  defp ticks(backend, last, n) do
    case :sys.get_state(backend).ledger_timer do
      ^last ->
        receive do
        after
          5 -> ticks(backend, last, n)
        end

      timer ->
        ticks(backend, timer, n - 1)
    end
  end

  describe "while the session runs" do
    setup c do
      backend = start_backend(c, c.conversation, ledger_prune_ms: 20)
      # The start-up pass is over: every later removal is the timer's.
      assert eventually(fn -> :sys.get_state(backend).ledger_prune == nil end)
      %{backend: backend}
    end

    test "rows that grow old are pruned, pass after pass", c do
      first = id("p76-first")
      old_row!(c, first)
      assert eventually(fn -> rows(first) == 0 end)

      second = id("p76-second")
      old_row!(c, second)
      assert eventually(fn -> rows(second) == 0 end)
    end

    test "a row of this session is never pruned", c do
      mine = id("p76-mine")
      :new = CommandLedger.admit(c.project.id, mine, scope(c.conversation), "f")
      old = id("p76-old")
      old_row!(c, old)

      assert eventually(fn -> rows(old) == 0 end)
      ticks(c.backend, 3)
      assert rows(mine) == 1
    end

    test "a pass that is still running holds the next one back", c do
      pass = hold_pass(c.backend)
      held = id("p76-held")
      old_row!(c, held)

      ticks(c.backend, 3)
      assert rows(held) == 1

      ref = Process.monitor(pass)
      send(pass, :finish)
      assert_receive {:DOWN, ^ref, :process, ^pass, _}
      assert eventually(fn -> rows(held) == 0 end)
    end
  end

  test "stopping the backend cancels its timer", c do
    backend = start_backend(c, c.conversation, ledger_prune_ms: 600_000)
    %{ledger_timer: timer} = :sys.get_state(backend)
    assert is_integer(Process.read_timer(timer))

    ref = Process.monitor(backend)
    GenServer.stop(backend)
    assert_receive {:DOWN, ^ref, :process, _, _}
    assert Process.read_timer(timer) == false
  end

  # Puts a task of the backend's own where a running pass would be, once no
  # real pass is: the backend sees a pass in flight until it is told to end.
  defp hold_pass(backend) do
    test = self()

    :sys.replace_state(backend, fn
      %{ledger_prune: nil} = state ->
        task =
          Task.Supervisor.async_nolink(state.task_supervisor, fn ->
            receive do
              :finish -> 0
            end
          end)

        send(test, {:held, task.pid})
        %{state | ledger_prune: task}

      state ->
        send(test, :busy)
        state
    end)

    receive do
      {:held, pid} ->
        pid

      :busy ->
        receive do
        after
          5 -> hold_pass(backend)
        end
    end
  end
end
