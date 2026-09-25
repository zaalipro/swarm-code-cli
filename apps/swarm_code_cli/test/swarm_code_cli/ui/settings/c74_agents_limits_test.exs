defmodule SwarmCodeCLI.UI.Settings.C74AgentsLimitsTest do
  @moduledoc "cli74 U3-6: the Agents & limits page (§2.9, F9)."
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.C74U3Helpers

  alias SwarmCodeCLI.UI.Settings.{Nav, Sections}
  alias SwarmCodeCLI.UI.Settings.Editors.Number

  defp with_defs(state, items) do
    data = %{state.settings.data | records: %{{"agent_def", %{}} => %{items: items}}}
    %{Nav.ctx(state) | data: data}
  end

  test "the registry's groups and rows, then the link to the always-allowed commands" do
    {state, _fake} = opened(:agents_limits)
    ids = Enum.map(rows(state), & &1.id)

    for head <- ~w(limits isolation shell), do: assert(("head:" <> head) in ids, head)
    assert "key:limits.max_concurrent_agents" in ids
    assert "key:limits.sub_agent_timeout" in ids
    assert List.last(ids) == "link:approvals"
  end

  test "the time limit's editor refuses what the service would, with the registry's words" do
    {state, _fake} = opened(:agents_limits)
    {Number, opts} = key_row(state, "limits.sub_agent_timeout").editor

    assert {:error, "must be 0 (no limit) or between 60 and 86400"} = Number.parse(opts, "30")
    assert {:ok, 0} = Number.parse(opts, "no limit")
  end

  test "agent definitions are link rows into Library; none yet says how to write one" do
    {state, _fake} = opened(:agents_limits)

    ctx =
      with_defs(state, [
        %{
          fields: %{
            "name" => "reviewer",
            "tier" => "project",
            "model" => "m1",
            "effort" => "high"
          }
        },
        %{fields: %{"name" => "reviewer", "tier" => "user", "shadowed" => true}}
      ])

    rows = Sections.rows(:agents_limits, ctx)
    project = Enum.find(rows, &(&1.id == "agent:project:reviewer"))
    user = Enum.find(rows, &(&1.id == "agent:user:reviewer"))
    assert words(project.value) =~ "m1 · high"
    assert words(user.value) =~ "the sub-agent model"
    assert words(user.tag) == "shadowed"

    assert [{:section, :library}, {:toast, text, _}] =
             Sections.act(:agents_limits, ctx, project, :open_row)

    assert text =~ "reviewer"

    none = :agents_limits |> Sections.rows(with_defs(state, [])) |> Enum.map(& &1.id)
    assert "info:agents-none" in none
  end

  test "Enter on the approvals link opens Approvals & trust" do
    {state, _fake} = opened(:agents_limits)
    link = row(state, "link:approvals")

    assert [{:section, :approvals}] =
             Sections.act(:agents_limits, Nav.ctx(state), link, :open_row)
  end
end
