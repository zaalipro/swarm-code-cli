defmodule SwarmCodeCLI.UI.Home.OrbitLiveTest do
  @moduledoc """
  orbit U10: Home under load and as the world changes (spec 3.2). A `home_stale`
  push is an invalidation: while Home is open it costs at most one request in flight
  and one more behind it; while Home is closed it costs nothing. The mark follows what
  the overview says, cell by cell.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.OrbitHelpers

  alias SwarmCodeCLI.Cli020EHelpers, as: H
  alias SwarmCodeCLI.UI.Home.Mark
  alias SwarmCodeCLI.UI.Theme

  @truecolor [color_mode: :truecolor, glyph_tier: :rich]

  defp opened(options \\ []) do
    {state, _} = start(options)
    {state, effects} = step(state, :boot)
    {state, overview_request(effects)}
  end

  defp overview_request(effects) do
    assert [request] = queries(effects, :home_overview)
    request
  end

  # An answer with `edit` applied to the wire map, installed and settled.
  defp answered(options \\ [], edit \\ & &1) do
    {state, request} = opened(options)
    {state, _} = answer_overview(state, request, edit)
    state
  end

  defp foreground(state, role), do: Theme.style(role, state.capabilities).foreground.value

  # The cell of the mark's element, on the 120 x 36 screen (the mark starts at row 2, column 4).
  defp style_of(state, predicate) do
    {r, c, _, _} = Enum.find(Mark.elements({32, 16}), predicate)
    H.cell_style(H.plan(state), 4 + c, 2 + r)
  end

  defp bottom_of_bar(state, index) do
    cells = for {r, c, _, {:bar, ^index, _}} <- Mark.elements({32, 16}), do: {r, c}
    {r, c} = Enum.max_by(cells, &elem(&1, 0))
    H.cell_style(H.plan(state), 4 + c, 2 + r)
  end

  describe "pushes" do
    test "a flood of 20 while a query is in flight costs exactly two requests in all" do
      {state, first} = opened()

      {state, sent} =
        Enum.reduce(1..20, {state, [first]}, fn revision, {acc, sent} ->
          {next, effects} = stale(acc, revision)
          {next, sent ++ queries(effects, :home_overview)}
        end)

      assert [^first] = sent

      {state, effects} = answer_overview(state, first, &Map.put(&1, "revision", 20))
      assert [second] = queries(effects, :home_overview)
      {state, effects} = answer_overview(state, second, &Map.put(&1, "revision", 20))
      assert effects == []
      assert state.home.overview_request == nil
    end

    test "while Home is closed five pushes cost nothing, and opening costs one" do
      state = answered()
      {state, _} = step(state, {:home, :escape})

      {state, sent} =
        Enum.reduce(1..5, {state, []}, fn revision, {acc, sent} ->
          {next, effects} = stale(acc, revision)
          {next, sent ++ effects}
        end)

      assert queries(sent, :home_overview) == []
      {state, effects} = step(state, :open_home)
      assert [_] = queries(effects, :home_overview)
      assert state.home.overview_request != nil
    end

    test "an answer older than the newest push is applied and asked for once more, never in a loop" do
      {state, first} = opened()
      {state, _} = stale(state, 7)

      {state, effects} = answer_overview(state, first, &Map.put(&1, "revision", 3))
      assert state.home.overview.revision == 3
      assert [second] = queries(effects, :home_overview)

      {state, effects} = answer_overview(state, second, &Map.put(&1, "revision", 3))
      assert queries(effects, :home_overview) == []
      assert state.home.overview.revision == 3
      assert state.home.overview_request == nil

      # a newer push is asked for again
      {_, effects} = stale(state, 8)
      assert [_] = queries(effects, :home_overview)
    end
  end

  describe "the mark follows the overview" do
    test "a live run lights its bar in its kind's role; when it ends the slot is empty again" do
      running = answered(capabilities: @truecolor)
      swarm = foreground(running, :run_swarm)
      assert bottom_of_bar(running, 0).foreground == swarm

      {idle, request} = opened(capabilities: @truecolor)

      {idle, _} = answer_overview(idle, request, &Map.put(&1, "live_runs", []))

      assert bottom_of_bar(idle, 0).foreground == foreground(idle, :disabled)
    end

    test "a run that appears with the next overview lights the slot it left empty" do
      {state, first} = opened(capabilities: @truecolor)
      {state, _} = answer_overview(state, first, &Map.put(&1, "live_runs", []))
      assert bottom_of_bar(state, 0).foreground == foreground(state, :disabled)

      {state, effects} = stale(state, 9)
      next = overview_request(effects)
      {state, _} = answer_overview(state, next, &Map.put(&1, "revision", 9))
      assert bottom_of_bar(state, 0).foreground == foreground(state, :run_swarm)
    end

    test "the dot is a warning while something waits and a ghost when nothing does" do
      waiting = answered(capabilities: @truecolor)
      dot = &match?({_, _, _, :dot}, &1)
      assert style_of(waiting, dot).foreground == foreground(waiting, :warning)

      quiet = answered([capabilities: @truecolor], &Map.put(&1, "waiting_total", 0))
      assert style_of(quiet, dot).foreground == foreground(quiet, :text_ghost)
    end
  end
end
