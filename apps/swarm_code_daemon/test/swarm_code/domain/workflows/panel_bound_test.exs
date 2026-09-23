defmodule SwarmCode.Domain.Workflows.PanelBoundTest do
  use ExUnit.Case, async: false
  use GenServer

  alias SwarmCode.Domain.Workflows.API

  setup do
    on_exit(fn -> Process.delete(:swarm_code_workflow) end)
    :ok
  end

  test "bounds concurrency and preserves order with nil for a failed slot" do
    {:ok, runner} = GenServer.start_link(__MODULE__, {self(), 128, 4})
    {:ok, counter} = Agent.start_link(fn -> %{live: 0, max: 0} end)
    API.put_context(context(runner))

    results =
      API.panel(0..127, fn i ->
        Agent.update(counter, fn state ->
          live = state.live + 1
          %{live: live, max: max(state.max, live)}
        end)

        try do
          # a slot that comes back with nothing (an agent failure is not an exit)
          if i == 51, do: nil, else: i
        after
          Agent.update(counter, &%{&1 | live: &1.live - 1})
        end
      end)

    assert Enum.at(results, 51) == nil
    assert Enum.with_index(results) |> Enum.all?(fn {value, i} -> i == 51 or value == i end)
    assert Agent.get(counter, & &1.max) <= 4
  end

  # Spec 51 §5.12: a raise in a slot is no longer a nil — it fails the run
  # with its line, through the same throw the runner already catches.
  test "an exception in a slot fails the run instead of reading as nil" do
    {:ok, runner} = GenServer.start_link(__MODULE__, {self(), 8, 2})
    API.put_context(context(runner))

    assert {:workflow, {:failed, message}} =
             catch_throw(
               API.panel([1, 2], fn i -> if i == 2, do: raise("slot failed"), else: i end)
             )

    assert message =~ "slot failed"
    assert message =~ "RuntimeError"
  end

  test "takes only remaining budget plus one from an infinite enumerable" do
    {:ok, runner} = GenServer.start_link(__MODULE__, {self(), 4, 2})
    {:ok, seen} = Agent.start_link(fn -> 0 end)
    API.put_context(context(runner))

    stream = Stream.repeatedly(fn -> Agent.get_and_update(seen, &{&1, &1 + 1}) end)

    assert catch_throw(API.panel(stream, & &1)) ==
             {:workflow,
              {:pause, "budget", "Panel of 5 agents needs more than the remaining 4 of 4 slots"}}

    assert Agent.get(seen, & &1) == 5
  end

  test "runner termination shuts down every registered slot" do
    parent = self()
    {:ok, runner} = GenServer.start_link(__MODULE__, {parent, 8, 2})

    caller =
      Task.async(fn ->
        API.put_context(context(runner))

        API.panel(1..2, fn _ ->
          send(parent, {:slot_waiting, self()})
          receive do: (:release -> :ok)
        end)
      end)

    pids = for _ <- 1..2, do: receive(do: ({:slot_waiting, pid} -> pid))
    refs = Enum.map(pids, &Process.monitor/1)
    GenServer.stop(runner)

    Enum.each(refs, fn ref -> assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 1_000 end)
    Task.shutdown(caller, :brutal_kill)
  end

  defp context(runner) do
    %{runner: runner, panel: nil, calls: 0, agent_called?: false}
  end

  @impl true
  def init({owner, remaining, max_live}) do
    {:ok, %{owner: owner, remaining: remaining, max_live: max_live, tasks: MapSet.new()}}
  end

  @impl true
  def handle_call(:budget, _from, state) do
    {:reply, %{total: state.remaining, spent: 0, remaining: state.remaining}, state}
  end

  def handle_call({:panel_admit, count}, _from, state) do
    if count > state.remaining do
      message =
        "Panel of #{count} agents needs more than the remaining #{state.remaining} of " <>
          "#{state.remaining} slots"

      {:reply, {:pause, "budget", message}, state}
    else
      {:reply, {:ok, 1, min(state.max_live, state.remaining)}, state}
    end
  end

  def handle_call({:panel_task, pid}, _from, state) do
    send(state.owner, {:panel_task, pid})
    {:reply, :ok, %{state | tasks: MapSet.put(state.tasks, pid)}}
  end

  @impl true
  def handle_cast({:panel_task_done, pid}, state) do
    {:noreply, %{state | tasks: MapSet.delete(state.tasks, pid)}}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.tasks, fn pid ->
      Task.Supervisor.terminate_child(SwarmCode.Domain.TaskSupervisor, pid)
    end)

    :ok
  end
end
