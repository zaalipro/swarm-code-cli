defmodule SwarmCodeCLI.UI.Cli022.X3ScheduleFormTest do
  @moduledoc """
  cli022 F1 (parity P4): a new scheduled task starts with no effort (it follows
  Settings' scheduled default) and no zone of its own (the daemon fills in the
  Mac's, as the desktop's form does); `default` stores nil.
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{
    Capabilities,
    FeatureForm,
    Init,
    Input,
    Keymap,
    Library,
    Reducer,
    Size
  }

  alias SwarmCodeCLI.UI.DataSource.DTO

  defp field(form, key), do: Enum.find(form.fields, &(&1.key == key))

  test "the new form's effort is a choice that starts on default" do
    effort = field(Library.new_form(:schedules), "effort")
    assert effort.kind == :choice
    assert effort.value == "default"
    assert effort.choices == ~w(default low medium high max)
  end

  test "the new form's zone is not pinned to UTC: blank, optional, and says who fills it" do
    zone = field(Library.new_form(:schedules), "timezone")
    assert zone.value == ""
    refute zone.required
    assert zone.label =~ "this Mac"
    refute inspect(Library.new_form(:schedules)) =~ "Etc/UTC"
  end

  test "a daemon-supplied form gains the default choice; an unset effort reads default" do
    form = %DTO.FeatureForm{
      title: "Edit schedule",
      fields: [
        %DTO.FormField{key: "name", label: "Name", value: "a", required: true},
        %DTO.FormField{
          key: "effort",
          label: "Effort",
          kind: :choice,
          choices: ~w(low high),
          value: ""
        }
      ]
    }

    effort = form |> Library.schedule_form() |> field("effort")
    assert effort.choices == ~w(default low high)
    assert effort.value == "default"

    pinned = %{form | fields: [hd(form.fields), %{field(form, "effort") | value: "high"}]}
    assert pinned |> Library.schedule_form() |> field("effort") |> Map.get(:value) == "high"
    assert Library.schedule_form(Library.schedule_form(form)) == Library.schedule_form(form)
  end

  defp open_new_form do
    size = %Size{columns: 120, rows: 40}

    {state, _} =
      Reducer.init(%Init{
        size: size,
        capabilities: %Capabilities{size: size},
        source_epoch: "epoch",
        destination: {:conversation, "conversation"}
      })

    {state, [{:query, request}]} = Reducer.update(state, {:open_layer, {:library, :schedules}})

    {state, []} =
      Library.response(state, request, %DTO.LibrarySnapshot{
        feature: :schedules,
        request_id: request.request_id,
        items: []
      })

    {state, []} = Reducer.update(state, {:open_layer, {:feature_form, :schedules, "new"}})
    state
  end

  defp type_into(state, key, text) do
    state = %{state | focus: "field:" <> key}
    {:ok, action} = Keymap.resolve(Input.paste(text), state, %{})
    {state, _} = Reducer.update(state, action)
    state
  end

  defp submitted(state) do
    {_state, [{:command, request}]} = Reducer.update(state, :feature_submit)
    {:feature_command, :schedules, :save, nil, attrs} = request.kind
    attrs
  end

  test "submitting the untouched form stores a nil effort and a nil zone" do
    state = open_new_form()
    assert FeatureForm.value(state, "effort") == "default"
    state = state |> type_into("name", "Nightly") |> type_into("prompt", "run it")
    attrs = submitted(state)
    assert Map.fetch!(attrs, "effort") == nil
    assert Map.fetch!(attrs, "timezone") == nil
    assert attrs["name"] == "Nightly"
  end

  test "cycling the effort to a level stores it, and back to default stores nil again" do
    state =
      open_new_form() |> type_into("name", "Nightly") |> type_into("prompt", "run it")

    state = %{state | focus: "field:effort"}
    {:ok, right} = Keymap.resolve(Input.key(:right), state, %{})
    {pinned, _} = Reducer.update(state, right)
    assert FeatureForm.value(pinned, "effort") == "low"
    assert submitted(pinned)["effort"] == "low"

    {:ok, left} = Keymap.resolve(Input.key(:left), pinned, %{})
    {back, _} = Reducer.update(pinned, left)
    assert FeatureForm.value(back, "effort") == "default"
    assert Map.fetch!(submitted(back), "effort") == nil
  end

  # cli022 int: the workspace's scheduled default and the Mac's zone.
  test "with the workspace's defaults the label names the level and the zone starts filled" do
    ws = %DTO.WorkspaceSnapshot{scheduled_effort_default: "high", local_zone: "Asia/Dubai"}
    form = Library.schedule_form(Library.new_form(:schedules), ws)
    assert field(form, "effort").label =~ "default · high"
    assert field(form, "effort").value == "default"
    assert field(form, "timezone").value == "Asia/Dubai"

    # An edit form keeps the task's own zone; an unset Settings level keeps the words.
    edit = %DTO.FeatureForm{
      title: "Edit",
      fields: [%DTO.FormField{key: "timezone", label: "Timezone", value: "Europe/Paris"}]
    }

    assert field(Library.schedule_form(edit, ws), "timezone").value == "Europe/Paris"

    unset =
      Library.schedule_form(Library.new_form(:schedules), %{ws | scheduled_effort_default: nil})

    refute field(unset, "effort").label =~ "·"
  end
end
