defmodule SwarmCodeCLI.UI.Settings.C74ApprovalsTest do
  @moduledoc "cli74 U3-7: the Approvals & trust page (§2.10, F14, D12–D14)."
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.C74U3Helpers
  import SwarmCodeCLI.UI.Pass73Helpers, only: [ready: 2]

  alias SwarmCodeCLI.UI.Reducer
  alias SwarmCodeCLI.UI.DataSource.{DTO, Delivery, Delta}
  alias SwarmCodeCLI.UI.Settings.{Confirm, Nav, Picker, Sections}

  defp changes(effects) do
    for params <- commands(effects, "values.patch"),
        change <- params["attributes"]["changes"],
        do: change
  end

  defp confirm(state) do
    case state.settings.popover do
      {:confirm, %{confirm: %Confirm{} = confirm, then: then}} -> {confirm, then}
      _ -> nil
    end
  end

  test "the page: the project picker first, then the registry rows and the families" do
    {state, _fake} = opened(:approvals)
    ids = Enum.map(rows(state), & &1.id)

    assert hd(ids) == "act:project_picker"
    assert words(row(state, "act:project_picker")) =~ "ailogic"
    assert "key:project.approval_mode" in ids
    assert "key:project.trusted" in ids
    assert "item:project.allow:0" in ids
    assert "act:forget_all" in ids
    assert "head:other projects" in ids
  end

  test "going down to read-only does not ask; full access asks" do
    {state, _fake} = opened(:approvals)
    assert words(key_row(state, "project.approval_mode")) == "Auto"

    {down, effects} = press(state, "key:project.approval_mode", :left)
    assert [%{"key" => "project.approval_mode", "value" => "read_only"}] = changes(effects)
    assert confirm(down) == nil

    {up, effects} = press(state, "key:project.approval_mode", :right)
    assert changes(effects) == []
    assert {%Confirm{title: "Give ailogic full access?"}, then} = confirm(up)
    assert then == [{:patch, "project.approval_mode", "full_access"}]
  end

  test "untrusting asks and says approvals go back to read-only" do
    {state, _fake} = opened(:approvals)
    {state, effects} = press(state, "key:project.trusted", :toggle)
    assert changes(effects) == []
    assert {%Confirm{title: "Stop trusting ailogic?", lines: [line]}, then} = confirm(state)
    assert line =~ "read-only"
    assert then == [{:patch, "project.trusted", false}]
  end

  test "trusting asks and lists the hooks that will start running" do
    {state, _fake} = opened(:approvals)
    ctx = Nav.ctx(state)

    {:record, "project_config", id} =
      Enum.find(Sections.loads(:approvals, ctx), &match?({:record, _, _}, &1))

    config = %{"hooks" => %{"post_tool_use" => [%{"command" => "mix format"}]}}
    ctx = %{ctx | data: %{ctx.data | record: %{{"project_config", id} => config}}}
    values = Map.update!(ctx.data.values, "project.trusted", &Map.put(&1, :value, false))
    ctx = %{ctx | data: %{ctx.data | values: values}}

    row = Enum.find(Sections.rows(:approvals, ctx), &(&1.key == "project.trusted"))

    assert [{:confirm, %Confirm{title: "Trust ailogic?", lines: lines}, then: then}] =
             Sections.commit(:approvals, ctx, row, true)

    assert "  post_tool_use · mix format" in lines
    assert then == [{:patch, "project.trusted", true}]
  end

  test "x forgets one family; Forget all asks first" do
    {state, _fake} = opened(:approvals)
    family = row(state, "item:project.allow:0").label

    {_state, effects} = press(state, "item:project.allow:0", :delete)
    assert [%{"key" => "project.allow", "value" => value}] = changes(effects)
    refute family in value
    assert length(value) == 4

    {state, effects} = press(state, "act:forget_all", :enter)
    assert changes(effects) == []

    assert {%Confirm{title: "Forget 5 commands?"}, [{:patch, "project.allow", []}]} =
             confirm(state)
  end

  test "the project picker and the other projects switch the page's project" do
    {state, _fake} = opened(:approvals)
    {state, _} = press(state, "act:project_picker", :enter)

    assert {:picker, %Picker{on_pick: {:section, :approvals, :project}, options: options}} =
             state.settings.popover

    assert length(options) >= 2

    other = Enum.find(rows(state), &String.starts_with?(&1.id, "other:"))
    "other:" <> other_id = other.id
    assert [{:project, ^other_id}] = Sections.act(:approvals, Nav.ctx(state), other, :open_row)

    assert [{:project, ^other_id}] =
             Sections.picked(:approvals, Nav.ctx(state), :project, other_id)

    # the page follows the layer's chosen project (`{:project, id}` sets it)
    state = %{state | settings: %{state.settings | page_project_id: other_id, popover: nil}}
    rows = Sections.rows(:approvals, Nav.ctx(state))
    assert words(hd(rows)) =~ "notes"
    refute Enum.any?(rows, &(&1.id == "other:" <> other_id))
  end

  test "an accepted mode change and the workspace snapshot after it: one notice, one toast" do
    state = ready([], snapshot: %{approval_mode: :auto})
    {state, _fake} = opened(:approvals, state: state)
    {state, _effects} = press(state, "key:project.approval_mode", :left)

    watch = state.watches.workspace

    {state, _} =
      Reducer.update(
        state,
        {:data,
         %Delivery{
           kind: :delta,
           watch_ref: watch.watch_ref,
           request_id: nil,
           scope: watch.scope,
           generation: watch.generation,
           revision: 2,
           sequence: watch.sequence + 1,
           body: %Delta{
             kind: :workspace_metadata,
             conversation_id: "c",
             body: struct(DTO.WorkspaceMetadata, conversation_id: "c", approval_mode: :read_only),
             revision: 2,
             sequence: watch.sequence + 1
           }
         }}
      )

    assert [%{from: :auto, to: :read_only}] = state.policy_notices
    assert {:command_feedback, _words} = state.notice
  end
end
