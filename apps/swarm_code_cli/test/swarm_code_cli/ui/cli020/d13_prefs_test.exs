defmodule SwarmCodeCLI.UI.Cli020.D13PrefsTest do
  @moduledoc """
  cli020 D13 (tui-code-4): the terminal.* settings rows act, at launch
  (`Init.prefs`) and at once when Settings writes cli.json (`state.prefs`).
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers

  alias SwarmCodeCLI.UI.{Capabilities, Hint, Input, Keymap, Reducer, Size, State}
  alias SwarmCodeCLI.UI.Reducer.Hint, as: Hints

  defp launched(prefs), do: ready([], init: [prefs: prefs])

  # Settings wrote cli.json: the layer's snapshot carries every value.
  defp written(state, prefs) do
    {state, _} = Reducer.update(state, {:settings, {:cli_snapshot, 0, %{values: prefs, status: :ok}}})
    state
  end

  test "wheel_lines: a notch scrolls that many lines, at launch and when written" do
    wheel = {:mouse, :wheel_down, nil, 5, 5, []}
    assert {:ok, {:scroll, _, {:line, 3}}} = Keymap.resolve(wheel, ready(), %{})

    assert {:ok, {:scroll, _, {:line, 7}}} =
             Keymap.resolve(wheel, launched(%{"wheel_lines" => 7}), %{})

    state = written(ready(), %{"wheel_lines" => 2})
    assert state.wheel_lines == 2
    assert {:ok, {:scroll, _, {:line, 2}}} = Keymap.resolve(wheel, state, %{})
    assert written(ready(), %{"wheel_lines" => 40}).wheel_lines == 3
  end

  test "notice_seconds: the toast fades after that many seconds" do
    state = %{written(ready(), %{"notice_seconds" => 2}) | now: 10_000}
    state = %{state | notice: {:command_feedback, "x"}, notice_at: 10_000}
    assert State.shown_notice(%{state | now: 11_900}) == {:command_feedback, "x"}
    assert State.shown_notice(%{state | now: 12_000}) == nil
    default = %{state | notice_ms: 6_000}
    assert State.shown_notice(%{default | now: 15_000}) == {:command_feedback, "x"}
  end

  test "hint_letters: the badges use the configured letters" do
    assert Hint.letter_labels(3, ~w(a b c)) == ~w(a b c)
    assert length(Hint.letter_labels(5, ~w(a b c))) == 5
    state = launched(%{"hint_letters" => "zxcvbm"})
    assert state.hint_letters == ~w(z x c v b m)
    entries = [{:agent, "r", "n1", false}, {:agent, "r", "n2", false}]
    assert Map.keys(Hint.labels(entries, state.hint_letters)) |> Enum.sort() == ~w(x z)
    # A list with a forbidden or repeated letter is ignored.
    assert launched(%{"hint_letters" => "zz"}).hint_letters == Hint.letters()
    _ = Hints
  end

  test "reduced_motion: sets the capability and outlives a new terminal" do
    state = written(ready(), %{"reduced_motion" => true})
    assert state.capabilities.reduced_motion?
    size = %Size{columns: 150, rows: 40}

    {state, _} =
      Reducer.update(
        state,
        {:terminal_capabilities, state.terminal_generation + 1,
         %Capabilities{size: size, reduced_motion?: false}}
      )

    assert state.capabilities.reduced_motion?
  end

  test "paste_collapse_lines: 0 never collapses a paste" do
    state = written(ready(), %{"paste_collapse_lines" => 0})
    lines = Enum.map_join(1..60, "\n", &"l#{&1}")
    {state, _} = press(state, Input.paste(lines))
    assert text(state) == lines
  end

  test "notify and title: read from cli.json" do
    state = written(ready(), %{"notify" => "off", "title" => false})
    assert state.notify == :off
    refute state.title?
  end
end
