defmodule SwarmCodeCLI.UI.Cli020.D12LastGoodFrameTest do
  @moduledoc """
  cli020 D12 (tui-code-8): a failed screen update keeps the last good scene
  and says so; only five failures in a row close the session.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias SwarmCodeCLI.Test.Cli020Runtime
  alias SwarmCodeCLI.UI.Projector

  # Fails the calls whose numbers are in `failing` (counted from 1).
  defp projector(failing) do
    counter = :counters.new(1, [])

    fun = fn ui ->
      :counters.add(counter, 1, 1)

      if :counters.get(counter, 1) in failing,
        do: raise("projector stub failure"),
        else: Projector.project(ui)
    end

    {fun, counter}
  end

  defp poke(runtime),
    do: Cli020Runtime.effect(runtime, {:paste_image, Cli020Runtime.conversation()})

  test "two failures then a success keep the session and the last good scene" do
    {fun, counter} = projector([2, 3])
    runtime = Cli020Runtime.start(projector: fun, os_type: {:unix, :linux}, env: %{})
    [{:latest, revision, _good}] = :ets.lookup(:sys.get_state(runtime).slot, :latest)
    poke(runtime)
    state = wait(runtime, fn s -> :counters.get(counter, 1) >= 4 and s.scene_failures == 0 end)
    assert state.phase == :running
    # The slot kept the good scene through the failures, then took a new one.
    assert [{:latest, newer, _}] = :ets.lookup(state.slot, :latest)
    assert newer > revision
    assert :counters.get(counter, 1) >= 4
  end

  test "the failure says so on the status line" do
    {fun, _counter} = projector([2])
    runtime = Cli020Runtime.start(projector: fun, os_type: {:unix, :linux}, env: %{})
    poke(runtime)

    state =
      wait(runtime, fn s ->
        s.ui.notice == {:command_feedback, "A screen update failed; showing the last good one."}
      end)

    assert state.phase == :running
  end

  test "five failures in a row close the session" do
    {fun, _counter} = projector(Enum.to_list(2..100))
    runtime = Cli020Runtime.start(projector: fun, os_type: {:unix, :linux}, env: %{})
    ref = Process.monitor(runtime)
    poke(runtime)
    state = wait(runtime, fn s -> s.phase != :running end)
    assert state.scene_failures == 5
    Process.demonitor(ref, [:flush])
  end

  defp wait(runtime, fun, attempts \\ 200)
  defp wait(runtime, _fun, 0), do: :sys.get_state(runtime)

  defp wait(runtime, fun, n) do
    state = :sys.get_state(runtime)
    if fun.(state), do: state, else: wait(runtime, fun, n - 1)
  end
end
