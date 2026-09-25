defmodule SwarmCodeCLI.UI.Settings.C74ModelsEffortTest do
  @moduledoc "cli74 U3-4: the Models & effort page (§2.2, F3 with §4.1 item 13)."
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.C74U3Helpers

  alias SwarmCodeCLI.UI.DataSource.Fake.Settings, as: FakeSettings
  alias SwarmCodeCLI.UI.Settings.{Layer, Nav, Page, Sections}

  defp changes(effects) do
    for params <- commands(effects, "values.patch"),
        change <- params["attributes"]["changes"],
        do: change
  end

  defp with_mode(mode) do
    {:ok, fake, _} = FakeSettings.control(FakeSettings.seed(), :put, ["session.mode", mode])
    fake
  end

  test "the page's groups in order, and the consensus rows kept off the page in build mode" do
    {state, _fake} = opened(:models_effort)
    ids = Enum.map(rows(state), & &1.id)

    assert Enum.take(ids, 2) == ["head:new conversations", "key:models.chat"]
    assert "head:default efforts" in ids
    assert "key:session.mode" in ids
    assert "key:session.profile" in ids
    # one "this conversation" heading: the profile row joins the group
    assert Enum.count(ids, &(&1 == "head:this conversation")) == 1
    refute "key:session.consensus_rounds" in ids
    refute "act:consensus" in ids
    assert words(key_row(state, "models.chat").value) =~ "deepseek-v4-pro"
  end

  test "session and global rows write to their own layers" do
    {state, _fake} = opened(:models_effort)

    {_state, effects} = press(state, "key:efforts.default", :right)
    assert [%{"key" => "efforts.default", "target" => target}] = changes(effects)
    refute Map.has_key?(target, "conversation_id")

    {_state, effects} = press(state, "key:session.effort", :left)

    assert [%{"key" => "session.effort", "target" => %{"conversation_id" => id}}] =
             changes(effects)

    assert id == "4f2a0000-0000-4000-8000-000000000001"
  end

  test "effort choices follow the conversation's (overlaid) model" do
    {state, _fake} = opened(:models_effort)
    setting = state.settings.data.values["session.effort"]
    row = key_row(state, "session.effort")
    {_module, opts} = row.editor
    values = Enum.map(opts.choices, & &1.value)
    assert values == Enum.map(setting.choices, &Map.get(&1, :value))
    assert "high" in values
  end

  test "choosing Consensus sends one session.mode change" do
    {state, _fake} = opened(:models_effort)
    {_state, effects} = press(state, "key:session.mode", :right)
    assert [%{"key" => "session.mode", "value" => "plan"}] = changes(effects)

    # through the editor straight to Consensus: one change, the one key
    {state, _fake} = opened(:models_effort)
    state = Nav.put_cursor(state, "key:session.mode")
    row = Nav.current(state)
    {_state, effects} = SwarmCodeCLI.UI.Reducer.Settings.Edit.commit(state, row, "consensus")
    assert [%{"key" => "session.mode", "value" => "consensus"}] = changes(effects)
  end

  test "in consensus mode the consensus sub-page is listed and opens" do
    {state, _fake} = opened(:models_effort, fake: with_mode("consensus"))
    assert %{kind: :link} = row(state, "act:consensus")

    {state, _effects} = press(state, "act:consensus", :enter)
    assert %Page{sub: :consensus} = Layer.page(state.settings)
    ids = Enum.map(rows(state), & &1.id)
    assert "key:session.consensus_rounds" in ids
    assert "key:session.judge_model" in ids
    assert "key:session.consensus_checks" in ids
    refute "info:consensus-note" in ids
  end

  test "the consensus rows say they are used only in consensus mode when reached otherwise" do
    {state, _fake} = opened(:models_effort)
    ctx = Nav.ctx(state)
    rows = Sections.sub_rows(:models_effort, ctx, :consensus)
    assert Enum.any?(rows, &(&1.id == "info:consensus-note"))
  end

  test "a session without a conversation shows one info row instead of its group" do
    {state, _fake} = opened(:models_effort)
    ctx = %{Nav.ctx(state) | conversation: nil}
    ids = :models_effort |> Sections.rows(ctx) |> Enum.map(& &1.id)
    assert "info:no-conversation" in ids
    refute "key:session.effort" in ids
    assert "key:efforts.default" in ids
  end

  test "the link rows: the project file's ignored keys and the environment" do
    {state, _fake} = opened(:models_effort)
    project_id = state.settings.data.project_id

    data = %{
      state.settings.data
      | record: %{
          {"project_config", project_id} => %{fields: %{"top_level" => %{"effort" => "high"}}}
        }
    }

    ctx = %{
      Nav.ctx(state)
      | data: data,
        launch_facts: %{flag_overrides: %{"session.model" => %{flag: "--model", value: "m"}}}
    }

    rows = Sections.rows(:models_effort, ctx)
    file = Enum.find(rows, &(&1.id == "link:project_file"))
    assert words(file.value) =~ "1 key SwarmCode ignores: effort"
    env = Enum.find(rows, &(&1.id == "link:files_env"))
    assert words(env.value) =~ "--model"

    assert [{:section, :project_file}] =
             Sections.act(:models_effort, ctx, file, :open_row)
  end

  test "Apply a profile picks from the project file's profiles and sends profile.apply" do
    {state, _fake} = opened(:models_effort)
    project_id = state.settings.data.project_id

    data = %{
      state.settings.data
      | record: %{
          {"project_config", project_id} => %{
            fields: %{"profiles" => %{"fast" => %{"effort" => "low"}}}
          }
        }
    }

    ctx = %{Nav.ctx(state) | data: data}
    row = Enum.find(Sections.rows(:models_effort, ctx), &(&1.id == "key:session.profile"))
    assert [{:picker, picker}] = Sections.act(:models_effort, ctx, row, :open_row)
    assert [%{value: "fast", hint: "low"}] = picker.options
    assert picker.on_pick == {:section, :models_effort, :profile}

    assert [
             {:command, "profile.apply",
              %{"conversation_id" => "4f2a0000-0000-4000-8000-000000000001"}, %{"name" => "fast"},
              _}
           ] =
             Sections.picked(:models_effort, ctx, :profile, "fast")

    empty = %{ctx | data: %{data | record: %{}}}
    assert [{:toast, _, :info}] = Sections.act(:models_effort, empty, row, :open_row)
  end

  test "Fetch every provider's models starts the task" do
    {state, _fake} = opened(:models_effort)
    ctx = Nav.ctx(state)
    row = Enum.find(Sections.rows(:models_effort, ctx), &(&1.id == "key:models.fetch_all"))

    assert [{:task, "provider.fetch_all", nil, %{}}] =
             Sections.act(:models_effort, ctx, row, :open_row)
  end
end
