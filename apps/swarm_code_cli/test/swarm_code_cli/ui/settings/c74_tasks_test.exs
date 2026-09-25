defmodule SwarmCodeCLI.UI.Settings.C74TasksTest do
  @moduledoc """
  cli74 U1-14: settings tasks — the words a row shows for each state, the
  repaint clock only while something moves, `c` stopping the page's
  running task, closing the layer stopping only the cancellable tasks it
  started (a write keeps running and is there on the next open), and the
  needs-you chip.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers, only: [ready: 0]

  alias SwarmCodeCLI.UI.{Reducer, SessionRuntime}
  alias SwarmCodeCLI.UI.DataSource.Request
  alias SwarmCodeCLI.UI.Settings.Tasks

  defp act(state, action), do: Reducer.update(state, action)
  defp act!(state, action), do: elem(act(state, action), 0)

  defp commands(effects),
    do: for({:command, %Request{kind: {:settings_command, params}}} <- effects, do: params)

  defp with_tasks(state, tasks) do
    layer = state.settings
    %{state | settings: %{layer | tasks: Map.merge(layer.tasks, tasks)}}
  end

  test "each state in words; the time moves in whole seconds" do
    running = %{
      "state" => :running,
      "elapsed_ms" => 2_000,
      "received_at_ms" => 1_000,
      "progress" => %{"done" => 3, "total" => 10}
    }

    assert [{"◷ running · 5 s · 3/10", :info}] = Tasks.words(running, 4_000)

    assert [{"◷ running · 1 min 2 s · still running", :info}] =
             Tasks.words(%{"state" => :running, "elapsed_ms" => 62_000}, 0)

    assert [{"✓ done", :success}, {" · 12 models", :text_muted}] =
             Tasks.words(%{"state" => :done, "message" => "12 models"}, 0)

    assert [{"✗ failed", :error} | _] = Tasks.words(%{"state" => :failed}, 0)

    assert [{"✗ no answer in 45 s", :error}] =
             Tasks.words(%{"state" => :timeout, "elapsed_ms" => 45_000}, 0)

    assert [{"cancelled", :text_muted}] = Tasks.words(%{"state" => :cancelled}, 0)
  end

  test "the repaint clock runs only while a task runs, a write is saving or a toast fades" do
    state = act!(ready(), {:settings_open, {:section, :storage}})
    refute SessionRuntime.time_dependent?(%{state | now: state.now + 60_000})

    busy = with_tasks(state, %{"t1" => %{"state" => :running, "action" => "storage.measure"}})
    assert SessionRuntime.time_dependent?(busy)

    done = with_tasks(state, %{"t1" => %{"state" => :done, "action" => "storage.measure"}})
    refute SessionRuntime.time_dependent?(%{done | now: done.now + 60_000})
  end

  test "c stops the page's one running task" do
    state = act!(ready(), {:settings_open, {:section, :storage}})

    state =
      with_tasks(state, %{
        "t1" => %{"state" => :running, "action" => "storage.measure", "mine" => true}
      })

    {_state, effects} = act(state, {:settings, {:verb, :cancel_task}})
    assert [%{"action" => "task.cancel", "target" => %{"task_id" => "t1"}}] = commands(effects)
  end

  test "closing stops only the cancellable tasks this layer started; a write runs on and is there on reopen" do
    state = act!(ready(), {:settings_open, {:section, :storage}})

    state =
      with_tasks(state, %{
        "check" => %{"state" => :running, "action" => "storage.measure", "mine" => true},
        "write" => %{"state" => :running, "action" => "storage.run", "mine" => true},
        "theirs" => %{"state" => :running, "action" => "provider.test"}
      })

    {closed, effects} = act(state, {:settings_open, nil})
    assert closed.settings == nil
    assert [%{"action" => "task.cancel", "target" => %{"task_id" => "check"}}] = commands(effects)

    reopened = act!(closed, {:settings_open, nil})
    assert Map.has_key?(reopened.settings.tasks, "write")
  end

  test "what waits on you shows as a chip in the header" do
    state = act!(ready(), {:settings_open, nil})
    ask = %{id: "i1", state: :pending, at: 1}
    state = %{state | read_model: %{state.read_model | interactions: %{"i1" => ask}}}
    {[region], nil} = SwarmCodeCLI.UI.Projector.Settings.project(state, nil)
    [header | _] = region.blocks
    text = Enum.map_join(header.spans, "", &SwarmCodeCLI.UI.SafeText.value(&1.text))
    assert text =~ "! 1 needs you Ctrl-N"
  end
end
