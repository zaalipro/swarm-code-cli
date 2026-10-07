defmodule SwarmCodeCLI.Cli020.E24SettingsDetailScrollTest do
  # cli020 E24 (tui-code-20): an open detail (`i`) longer than the page
  # scrolls with PgUp/PgDn (and D's Ctrl-U/Ctrl-D, as half pages); it says
  # what is above and below, and closing it starts over at the top.
  use ExUnit.Case, async: true

  import SwarmCodeCLI.C75Helpers
  import SwarmCodeCLI.UI.C74U3Helpers, except: [screen: 1]

  alias SwarmCodeCLI.UI.Pass73Helpers
  alias SwarmCodeCLI.UI.Settings.{Grid, Nav}

  @size {140, 20}

  defp detail do
    state = rich(Pass73Helpers.ready([], columns: 140, rows: 20))

    state = %{
      state
      | launch_facts: %{
          env_overrides: %{"terminal.theme" => %{var: "SWARM_THEME", value: "light"}}
        }
    }

    {state, _fake} = opened(:models_effort, state: state)
    effort = Enum.find(Nav.rows(state), &(&1.label =~ "Effort"))
    {detail, _} = state |> Nav.put_cursor(effort.id) |> verb(:info)
    detail
  end

  defp text(state), do: state |> page_lines(@size) |> Enum.map(&String.trim/1)

  test "PgDn scrolls the open detail; the first line says what is above" do
    top = text(detail())
    assert List.last(top) =~ ~r/^↓ \d+ lines below$/

    {down, _} = verb(detail(), :page_down)
    page = text(down)
    assert hd(page) =~ ~r/^↑ \d+ lines? above$/
    refute page == top
    assert length(page_lines(down, @size)) == Grid.for(140, 20).body_rows

    {up, _} = verb(down, :page_up)
    assert text(up) == top
  end

  test "it stops at the end and at the top" do
    state = Enum.reduce(1..20, detail(), fn _, st -> elem(verb(st, :page_down), 0) end)
    page = text(state)
    refute Enum.any?(page, &(&1 =~ "below"))
    assert hd(page) =~ "above"

    {back, _} = verb(state, :page_up)
    assert text(back) != page

    top = Enum.reduce(1..40, state, fn _, st -> elem(verb(st, :page_up), 0) end)
    assert text(top) == text(detail())
  end

  test "closing the detail resets its scroll" do
    {down, _} = verb(detail(), :page_down)
    {closed, _} = verb(down, :info)
    {again, _} = verb(closed, :info)
    assert text(again) == text(detail())
  end
end
