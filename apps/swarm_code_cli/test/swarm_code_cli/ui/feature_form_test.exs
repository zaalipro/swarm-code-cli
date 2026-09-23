defmodule SwarmCodeCLI.UI.FeatureFormTest do
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{
    Capabilities,
    FeatureForm,
    Init,
    Input,
    Keymap,
    Library,
    Projector,
    Reducer,
    SafeText,
    Size
  }

  alias SwarmCodeCLI.UI.DataSource.{DTO, Delivery}
  alias SwarmCodeCLI.UI.DataSource.AdmissionError

  test "workflow Start opens declared inputs and sends typed scoped arguments only on submit" do
    state =
      ready(:workflows, "release", :start, [
        field("arg:task", "Task", required: true),
        field("arg:count", "Count", kind: :integer, value: "2"),
        field("arg:verify", "Verify", kind: :boolean, value: "true"),
        field("budget", "Agent budget", kind: :integer, value: "12")
      ])

    {opened, []} = Reducer.update(state, Library.activation(state, "form"))
    assert [{:feature_form, :workflows, "release"}, {:library, :workflows}] = opened.layers
    owner = opened.feature_form.owner
    assert opened.focus == "field:arg:task"

    assert {:ok, {:field_editor, {:feature_field, ^owner, "arg:task"}, {:paste, "Ship CLI"}}} =
             Keymap.resolve(Input.paste("Ship CLI"), opened, %{})

    {edited, _} = input(opened, Input.paste("Ship CLI"))
    assert :ignore = Keymap.resolve(Input.key(:enter), edited, %{})
    {pending, [{:command, request}]} = Reducer.update(edited, :feature_submit)

    assert request.kind ==
             {:feature_command, :workflows, :start, "release",
              %{
                "args" => %{"task" => "Ship CLI", "count" => 2, "verify" => true},
                "budget" => 12
              }}

    assert request.scope == state.watches.workspace.scope
    assert {^pending, []} = Reducer.update(pending, :feature_submit)
    assert :ignore = Keymap.resolve(Input.paste(" changed"), pending, %{})
    assert FeatureForm.value(pending, "arg:task") == "Ship CLI"
  end

  test "new and existing schedules use nil or selected row ID; choices use keyboard controls" do
    fields = [
      field("name", "Name", value: "Weekly review", required: true),
      field("schedule_kind", "Repeat",
        kind: :choice,
        choices: ~w(daily weekly monthly cron once),
        value: "daily"
      ),
      field("weekdays", "Weekdays", kind: :json, value: "[1,5]"),
      field("day_of_month", "Day", kind: :integer)
    ]

    for {item, expected} <- [{"new", nil}, {"schedule-id", "schedule-id"}] do
      state = ready(:schedules, item, :save, fields)
      {state, []} = Reducer.update(state, Library.activation(state, "form"))
      {state, []} = input(%{state | focus: "field:schedule_kind"}, Input.key(:right))
      assert FeatureForm.value(state, "schedule_kind") == "weekly"
      {_, [{:command, request}]} = Reducer.update(state, :feature_submit)
      assert {:feature_command, :schedules, :save, ^expected, attrs} = request.kind
      assert attrs["weekdays"] == [1, 5]
      assert attrs["day_of_month"] == nil
      refute Map.has_key?(attrs, "project_id")
    end
  end

  test "required, malformed numbers and JSON errors remain editable with field-specific feedback" do
    state =
      ready(:settings, "limits", :update, [
        field("max_agent_turns", "Agent turns", kind: :integer, value: "2x", required: true),
        field("monthly_budget_usd", "Monthly budget", kind: :number, value: "12.5"),
        field("pricing", "Pricing", kind: :json, value: "{")
      ])

    {state, []} = Reducer.update(state, Library.activation(state, "form"))
    {invalid, []} = Reducer.update(state, :feature_submit)
    assert invalid.feature_form.error =~ "Agent turns"
    assert invalid.focus == "field:max_agent_turns"
    {state, _} = replace(invalid, "max_agent_turns", "30")
    {invalid, []} = Reducer.update(state, :feature_submit)
    assert invalid.feature_form.error =~ "Pricing"
    {state, _} = replace(invalid, "pricing", "{}")
    {pending, [{:command, request}]} = Reducer.update(state, :feature_submit)
    assert elem(request.kind, 4)["monthly_budget_usd"] == 12.5
    {rejected, []} = response(pending, request, :rejected)
    assert rejected.layers == pending.layers
    assert rejected.feature_form.error =~ "invalid data source request"
    assert FeatureForm.value(rejected, "max_agent_turns") == "30"
    {pending, [{:command, request}]} = Reducer.update(rejected, :feature_submit)
    {accepted, effects} = response(pending, request, :accepted)
    assert accepted.layers == [{:library, :settings}]
    assert accepted.feature_form == nil
    assert Enum.any?(effects, &match?({:query, _}, &1))
  end

  test "cancel drops form editors and timers; stale responses never close a replacement form" do
    state = ready(:workflows, "release", :start, [field("arg:task", "Task", required: true)])
    {state, []} = Reducer.update(state, Library.activation(state, "form"))
    {state, [{:start_timer, timer, _, _}]} = input(state, Input.text_fragment(:press, "task", []))
    {pending, [{:command, request}]} = Reducer.update(state, :feature_submit)
    {closed, effects} = input(pending, Input.key(:escape))
    assert {:cancel_timer, timer} in effects
    assert closed.feature_form == nil
    {closed, _} = response(closed, request, :accepted)
    assert closed.layers == [{:library, :workflows}]
    assert {^closed, []} = Reducer.update(closed, {:timer_fired, timer})
  end

  test "long forms scroll focused fields into view at terminal widths and keep submit controls" do
    fields = for n <- 1..25, do: field("field#{n}", "Field #{n}", value: "value #{n}")
    state = ready(:settings, "defaults", :update, fields)
    {state, []} = Reducer.update(state, Library.activation(state, "form"))

    for width <- [80, 120] do
      {sized, _} = Reducer.update(state, {:resize, %Size{columns: width, rows: 24}})
      {scene, _} = Projector.project(%{sized | focus: "field:field25"})
      assert scene.overlay.body_scroll > 0
      text = inspect(scene.overlay.blocks, limit: :infinity)
      refute text =~ "\\e["

      assert Enum.any?(
               scene.overlay.footer,
               &(Map.has_key?(&1, :text) and SafeText.value(&1.text) =~ "Save")
             )
    end

    {too_long, _} = input(state, Input.paste(String.duplicate("x", 16_385)))
    assert too_long.feature_form.error =~ "16,384"
  end

  test "form fields and actions are inert outside their owner and read-only controls cannot mutate" do
    state =
      ready(:settings, "limits", :update, [field("max_agent_turns", "Turns", kind: :integer)])

    assert {^state, []} = Reducer.update(state, :feature_submit)
    assert {^state, []} = Reducer.update(state, {:feature_cycle, "max_agent_turns", 1})
    {opened, []} = Reducer.update(state, Library.activation(state, "form"))

    assert {^opened, []} =
             Reducer.update(
               opened,
               {:field_editor, {:feature_field, "foreign", "max_agent_turns"}, {:insert, "5"}}
             )

    assert {^opened, []} =
             Reducer.update(
               opened,
               {:field_editor, {:feature_field, opened.feature_form.owner, "project_id"},
                {:insert, "foreign"}}
             )

    assert FeatureForm.value(opened, "max_agent_turns") == ""
  end

  defp field(key, label, opts),
    do: struct!(DTO.FormField, Keyword.merge([key: key, label: label], opts))

  defp ready(feature, id, action, fields) do
    size = %Size{columns: 120, rows: 40}

    {state, _} =
      Reducer.init(%Init{
        size: size,
        capabilities: %Capabilities{size: size},
        source_epoch: "epoch",
        destination: {:conversation, "conversation"}
      })

    {state, [{:query, request}]} = Reducer.update(state, {:open_layer, {:library, feature}})

    form =
      struct!(DTO.FeatureForm,
        title: "Configure",
        submit_label: "Save",
        action: action,
        fields: fields
      )

    item =
      struct!(DTO.LibraryItem,
        id: id,
        title: "Item",
        actions: if(action == :start, do: [:start], else: []),
        form: form
      )

    {state, []} =
      Library.response(state, request, %DTO.LibrarySnapshot{
        feature: feature,
        request_id: request.request_id,
        items: [item]
      })

    state
  end

  defp input(state, input) do
    {:ok, action} = Keymap.resolve(input, state, %{})
    Reducer.update(state, action)
  end

  defp replace(state, key, text) do
    state = %{state | focus: "field:" <> key}
    owner = state.feature_form.owner
    {state, _} = Reducer.update(state, {:field_editor, {:feature_field, owner, key}, :select_all})
    Reducer.update(state, {:field_editor, {:feature_field, owner, key}, {:paste, text}})
  end

  defp response(state, request, status) do
    error = if status == :rejected, do: AdmissionError.new(:invalid_request), else: nil

    Reducer.update(
      state,
      {:data,
       %Delivery{
         kind: :response,
         watch_ref: nil,
         request_id: request.request_id,
         scope: request.scope,
         generation: request.generation,
         revision: nil,
         sequence: nil,
         body: %DTO.Outcome{status: status, request_id: request.request_id, error: error}
       }}
    )
  end
end
