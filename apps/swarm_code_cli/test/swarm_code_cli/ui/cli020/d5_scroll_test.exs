defmodule SwarmCodeCLI.UI.Cli020.D5ScrollTest do
  @moduledoc """
  cli020 D5 (tui-code-9, Q5): with wheel reports off, alternate scroll's
  arrow burst arrives as `{:scroll, direction, count}` and scrolls what the
  wheel scrolls, `count × wheel_lines` lines.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers

  alias SwarmCodeCLI.UI.{Input, Keymap}

  test "the input validates its direction and bounded count" do
    assert {:ok, {:scroll, :up, 3}} = Input.validate({:scroll, :up, 3})
    assert {:error, _} = Input.validate({:scroll, :left, 3})
    assert {:error, _} = Input.validate({:scroll, :down, 0})
    assert {:error, _} = Input.validate({:scroll, :down, 33})
  end

  test "a burst scrolls the transcript count × wheel_lines" do
    state = ready()
    assert {:ok, {:scroll, "main", {:line, -9}}} = Keymap.resolve({:scroll, :up, 3}, state, %{})

    assert {:ok, {:scroll, "main", {:line, 10}}} =
             Keymap.resolve({:scroll, :down, 2}, %{state | wheel_lines: 5}, %{})
  end

  test "a multi-line draft does not take the burst" do
    state = ready() |> paste("one\ntwo\nthree")
    assert {:ok, {:scroll, "main", {:line, -3}}} = Keymap.resolve({:scroll, :up, 1}, state, %{})
  end

  test "the help sheet scrolls under the burst, as under the wheel" do
    state = %{ready() | layers: [:help]}

    assert {:ok, {:scroll, "dialog", {:line, 6}}} =
             Keymap.resolve({:scroll, :down, 2}, state, %{})
  end

  test "wheel notches with reports on use wheel_lines too" do
    state = %{ready() | wheel_lines: 7}

    assert {:ok, {:scroll, _, {:line, -7}}} =
             Keymap.resolve({:mouse, :wheel_up, nil, 5, 5, []}, state, %{})
  end
end
