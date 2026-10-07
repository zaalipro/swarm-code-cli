defmodule SwarmCodeCLI.UI.Cli020.D3AttentionTest do
  @moduledoc """
  cli020 D3 (tui-code-5, decision 4a): the bell when an approval or question
  appears or a run this session started finishes, only while the terminal
  reported focus lost and at most once per 2 s; and the window title.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers

  alias SwarmCodeCLI.UI.{Reducer, SafeText}
  alias SwarmCodeCLI.UI.DataSource.DTO

  defp approval(id) do
    %DTO.PendingInteraction{
      id: id,
      kind: :approval,
      run_id: "r",
      node_id: "op-" <> id,
      conversation_id: "c",
      expected_revision: 5,
      created_at: 1,
      allowed_actions: [:approve, :deny],
      approval: %DTO.Approval{tool: "run_command", permission: :execute, arguments_preview: "ls"}
    }
  end

  defp opts(extra \\ []),
    do: [
      init:
        [
          launch_facts: %{project_root: "/tmp/work/demo"},
          capabilities: %SwarmCodeCLI.UI.Capabilities{
            size: %SwarmCodeCLI.UI.Size{columns: 150, rows: 40},
            full_screen?: true
          }
        ] ++ extra
    ]

  defp focus(state, focus),
    do: elem(Reducer.update(state, {:terminal_focus, focus, state.terminal_generation}), 0)

  defp at(state, now), do: %{state | now: now}

  defp bells(effects), do: for({:bell, kind} <- effects, do: kind)
  defp words(effects), do: for({:notify_os, text} <- effects, do: SafeText.value(text))
  defp titles(effects), do: for({:terminal_title, text} <- effects, do: SafeText.value(text))

  defp with_approvals(state, ids, revision) do
    watch_ready(
      state,
      [run("r", :waiting_approval)],
      %{interactions: Enum.map(ids, &approval/1)},
      revision
    )
  end

  test "focus lost and a new approval: one needs-you bell with its words" do
    state = ready([run("r", :running)], opts()) |> focus(:lost)
    {_state, effects} = with_approvals(state, ["a1"], 1)
    assert bells(effects) == [:needs_you]
    assert words(effects) == ["ncode: demo needs you (approval)"]
  end

  test "focused: no bell" do
    state = ready([run("r", :running)], opts())
    {_state, effects} = with_approvals(state, ["a1"], 1)
    assert bells(effects) == []
  end

  test "a burst of approvals bells once per 2 s" do
    state = ready([run("r", :running)], opts()) |> focus(:lost)
    {state, first} = with_approvals(at(state, 10_000), ["a1"], 1)
    {state, second} = with_approvals(at(state, 10_500), ["a1", "a2"], 2)
    assert map_size(state.read_model.interactions) == 2
    {_state, third} = with_approvals(at(state, 12_100), ["a1", "a2", "a3"], 3)
    assert bells(first) == [:needs_you]
    assert bells(second) == []
    assert bells(third) == [:needs_you]
  end

  test "a run this session started finishing while unfocused bells turn_done" do
    state = ready([run("r", :running)], opts()) |> focus(:lost)

    state = %{
      state
      | deliveries: [
          %{id: "d", conversation_id: "c", run_id: "r", text: "hi", status: :started, at: 0}
        ]
    }

    {state, effects} = run_update(state, run("r", :done))
    assert bells(effects) == [:turn_done]
    assert words(effects) == ["ncode: demo finished"]
    assert state.title_done?
  end

  test "a run another client started does not bell" do
    state = ready([run("r", :running)], opts()) |> focus(:lost)
    {_state, effects} = run_update(state, run("r", :failed))
    assert bells(effects) == []
  end

  test "the title follows the conversation: idle, working, needs you, done, idle" do
    state = booting(opts()) |> shell_ready()
    # The first transition after boot sends the idle title.
    assert state.terminal_title == "ncode · demo"
    {state, effects} = watch_ready(state, [])
    assert titles(effects) == []

    {state, effects} = watch_ready(state, [run("r", :running)], %{}, 1)
    assert titles(effects) == ["ncode · demo · working"]

    {state, effects} = with_approvals(state, ["a1"], 2)
    assert titles(effects) == ["ncode · demo · needs you"]

    state = focus(state, :lost)

    state = %{
      state
      | deliveries: [
          %{id: "d", conversation_id: "c", run_id: "r", text: "hi", status: :started, at: 0}
        ]
    }

    {state, effects} = watch_ready(state, [run("r", :done)], %{interactions: []}, 3)
    assert titles(effects) == ["ncode · demo · done"]

    {state, _} = Reducer.update(state, {:terminal_focus, :gained, state.terminal_generation})
    assert state.terminal_title == "ncode · demo"
  end

  test "a terminal that is not full screen gets neither" do
    state = booting(init: [launch_facts: %{project_root: "/x/demo"}]) |> shell_ready()
    assert state.terminal_title == nil
    state = focus(state, :lost)
    {_state, effects} = with_approvals(state, ["a1"], 1)
    assert bells(effects) == [] and titles(effects) == []
  end

  test "terminal.title off sends no title, terminal.notify off no bell" do
    state = booting(opts(title?: false, notify: :off)) |> shell_ready()
    {state, effects} = watch_ready(state, [run("r", :running)])
    assert titles(effects) == []
    state = focus(state, :lost)
    {_state, effects} = with_approvals(state, ["a1"], 1)
    assert bells(effects) == []
  end
end
