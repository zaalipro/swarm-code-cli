defmodule SwarmCodeCLI.UI.Settings.C74FTableRowsTest do
  @moduledoc """
  cli74 F15 (A46, found in the sandbox): a table row (a language server, a
  search engine) that is being edited shows the editor on its line; it drew
  its columns and the editor was invisible.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers, only: [ready: 0]

  alias SwarmCodeCLI.UI.{Projector, Reducer, SafeText}
  alias SwarmCodeCLI.UI.DataSource.{Delivery, Request}
  alias SwarmCodeCLI.UI.DataSource.Fake.Settings, as: FakeSettings
  alias SwarmCodeCLI.UI.DataSource.DTO
  alias SwarmCodeCLI.UI.Reducer.Settings.{Ops, Responses}
  alias SwarmCodeCLI.UI.Settings.{Nav, Page}
  alias SwarmCodeCLI.UI.Settings.Sections.Providers

  defp serve({state, effects}, fake) do
    for({kind, %Request{} = r} <- effects, kind in [:query, :command], do: r)
    |> Enum.reduce({state, fake}, fn request, {acc, fake} ->
      {fake, body, _} =
        case request.kind do
          {:settings_query, _} -> FakeSettings.query(fake, request)
          {:settings_command, _} -> FakeSettings.command(fake, request)
        end

      delivery = %Delivery{
        kind: :response,
        watch_ref: nil,
        request_id: request.request_id,
        scope: request.scope,
        generation: request.generation,
        revision: nil,
        sequence: nil,
        body: body
      }

      {acc, _} = Reducer.update(acc, {:data, delivery})
      {acc, fake}
    end)
  end

  defp lines(state) do
    {scene, _} = Projector.project(state)

    scene.regions
    |> Enum.flat_map(& &1.blocks)
    |> Enum.map(fn block -> Enum.map_join(block.spans, "", &SafeText.value(&1.text)) end)
  end

  test "Enter on a language shows its command editor on the language's line" do
    {state, _fake} =
      ready()
      |> Reducer.update({:settings_open, {:section, :language_servers}})
      |> serve(FakeSettings.seed())

    before = Enum.find(lines(state), &(&1 =~ "Elixir"))
    assert before =~ ".ex .exs"

    {state, _} = Ops.run(state, [{:edit, "key:lsp.elixir"}])
    assert state.settings.mode == :editing

    line = Enum.find(lines(state), &(&1 =~ "Elixir"))
    refute line =~ ".ex .exs"
    assert line != before
  end

  # cli74 F16 (A43, found in the sandbox): a refused replacement said so
  # three times (the section's two lines and the paste's own line).
  test "a refused key replacement says so once, and not after Esc" do
    fake = FakeSettings.seed()
    {:ok, fake, []} = FakeSettings.control(fake, :stub_reply, ["provider.set_key", {:task, %{}}])
    state = ready()
    state = %{state | capabilities: %{state.capabilities | paste: :supported}}

    {state, fake} =
      state |> Reducer.update({:settings_open, {:section, :providers}}) |> serve(fake)

    "rec:provider:" <> id =
      Enum.find(Nav.rows(state), &(&1.label =~ "DeepSeek" and &1.id =~ "rec:provider:")).id

    {state, fake} =
      state
      |> Ops.run([{:open, %Page{section: :providers, record: {"provider", id}}}])
      |> serve(fake)

    key = Enum.find(Nav.rows(state), &(&1.id == "fld:provider:#{id}:api_key"))
    [{:paste, target}] = Providers.act(Nav.ctx(state), key, :open_row)
    {state, _} = Ops.run(state, [{:paste, target}])
    {state, _} = Reducer.update(state, {:settings, {:paste, "sk-refused-0000000000000"}})
    {state, _fake} = state |> Reducer.update({:settings, {:verb, :paste_commit}}) |> serve(fake)
    task_id = state.settings.paste.pending_task
    assert is_binary(task_id)
    assert state |> lines() |> Enum.count(&(&1 =~ "checking the new key")) == 1

    failed = %DTO.SettingsTask{
      task_id: task_id,
      action: "provider.set_key",
      target: %{"id" => id},
      state: :failed,
      message: "The new key was refused (401)."
    }

    {state, _} = Responses.delta(state, failed)
    text = lines(state)
    assert Enum.count(text, &(&1 =~ "The new key was refused (401).")) == 1
    # Once on the page (the footer names the same keys without the dot).
    assert Enum.count(text, &(&1 =~ "save it anyway · Esc")) == 1

    {state, _} = Reducer.update(state, {:settings, {:verb, :escape}})
    assert state.settings.paste == nil
    refute Enum.any?(lines(state), &(&1 =~ "save it anyway"))
  end

  # cli74 F17 (A22, found in the sandbox): the service's task deltas carry no
  # `at`, so an ended test said no time.
  test "an ended task from the service says the local time it ended" do
    fake = FakeSettings.seed()
    state = %{ready() | now: 1_790_000_000_000}

    {state, fake} =
      state |> Reducer.update({:settings_open, {:section, :providers}}) |> serve(fake)

    "rec:provider:" <> id =
      Enum.find(Nav.rows(state), &(&1.label =~ "DeepSeek" and &1.id =~ "rec:provider:")).id

    {state, _fake} =
      state
      |> Ops.run([{:open, %Page{section: :providers, record: {"provider", id}}}])
      |> serve(fake)

    done = %DTO.SettingsTask{
      task_id: "t-f17",
      action: "provider.test",
      target: %{"id" => id},
      state: :done,
      summary: %{"count" => 2, "ms" => 5}
    }

    {state, _} = Responses.delta(state, done)
    {_, {hour, minute, _}} = :calendar.system_time_to_local_time(state.now, :millisecond)
    clock = :io_lib.format("~2..0B:~2..0B", [hour, minute]) |> to_string()
    assert Enum.any?(lines(state), &(&1 =~ "✓ listed 2 models in 5 ms · #{clock}"))
  end

  # cli74 F18 (found in the sandbox): the provider's delete page was
  # "Settings › Providers › …" at 160 columns.
  test "a provider's delete page names the provider in the header" do
    fake = FakeSettings.seed()

    {state, fake} =
      ready() |> Reducer.update({:settings_open, {:section, :providers}}) |> serve(fake)

    "rec:provider:" <> id =
      Enum.find(Nav.rows(state), &(&1.label =~ "DeepSeek" and &1.id =~ "rec:provider:")).id

    {state, _fake} =
      state
      |> Ops.run([{:open, %Page{section: :providers, record: {"provider", id}}}])
      |> serve(fake)

    # The page a provider that serves a default opens before it is deleted.
    {state, _} =
      Ops.run(state, [{:open, %Page{section: :providers, record: {"provider", id}, sub: :delete}}])

    assert SwarmCodeCLI.UI.Settings.Page.level(
             SwarmCodeCLI.UI.Settings.Layer.page(state.settings)
           ) == :sub

    assert hd(lines(state)) =~ "Settings › Providers › DeepSeek"
  end

  # cli74 F19 (found in the sandbox): "Last opened" said the stored UTC time.
  test "stored UTC stamps read as the local wall clock" do
    local =
      {{2026, 9, 25}, {18, 44, 0}}
      |> :calendar.universal_time_to_local_time()
      |> NaiveDateTime.from_erl!()
      |> Calendar.strftime("%Y-%m-%d %H:%M")

    alias SwarmCodeCLI.UI.Settings.IntegrationRows, as: R
    assert R.local_stamp("2026-09-25T18:44:12", "%Y-%m-%d %H:%M") == local
    assert R.local_stamp("2026-09-25T18:44:12Z", "%Y-%m-%d %H:%M") == local
    assert R.local_stamp("2026-09-25T18:44:12.123456Z", "%Y-%m-%d %H:%M") == local
    assert R.local_stamp("yesterday", "%H:%M") == nil
  end

  # cli74 F20 (found in the sandbox): "[ T  T  Trust ]".
  test "a confirmation draws its letter once" do
    fake = FakeSettings.seed()

    {state, _fake} =
      ready() |> Reducer.update({:settings_open, {:section, :approvals}}) |> serve(fake)

    confirm = %SwarmCodeCLI.UI.Settings.Confirm{
      id: "t",
      title: "Trust ailogic?",
      safe: "Not now",
      danger: "T  Trust",
      letter: "T"
    }

    {state, _} = Ops.run(state, [{:confirm, confirm, then: []}])
    text = Enum.join(lines(state), "\n")
    assert text =~ "[ T  Trust ]"
    refute text =~ "T  T  Trust"
  end

  # cli74 F21 (found in the sandbox): after a provider was deleted its staged
  # replacement picks stayed, and leaving asked about "changes to provider <id>".
  test "deleting a provider drops what was staged for it" do
    fake = FakeSettings.seed()

    {state, fake} =
      ready() |> Reducer.update({:settings_open, {:section, :providers}}) |> serve(fake)

    "rec:provider:" <> id =
      Enum.find(Nav.rows(state), &(&1.label =~ "OpenRouter" and &1.id =~ "rec:provider:")).id

    {state, fake} =
      state
      |> Ops.run([{:open, %Page{section: :providers, record: {"provider", id}}}])
      |> serve(fake)

    staged = Map.put(state.settings.staged, {"provider", id}, %{"replacements" => %{}})
    state = %{state | settings: %{state.settings | staged: staged}}
    delete = Enum.find(Nav.rows(state), &(&1.label =~ "Delete this provider"))
    {state, _} = Ops.run(state, Providers.act(Nav.ctx(state), delete, :open_row))
    assert {:confirm, _} = state.settings.popover

    {deleted, _fake} = state |> Reducer.update({:settings, {:text, "D"}}) |> serve(fake)
    assert deleted.settings.status.text =~ "Deleted"
    refute Map.has_key?(deleted.settings.staged, {"provider", id})
  end

  # cli74 F29 (A17, found in the sandbox): a paste on a focused key row was dropped
  # silently; the row says "paste the key · Cmd-V", so the paste opens it.
  test "a paste on a focused key row opens the paste with that key; elsewhere it does nothing" do
    fake = FakeSettings.seed()
    state = ready()
    state = %{state | capabilities: %{state.capabilities | paste: :supported}}

    {state, fake} =
      state |> Reducer.update({:settings_open, {:section, :providers}}) |> serve(fake)

    "rec:provider:" <> id =
      Enum.find(Nav.rows(state), &(&1.label =~ "DeepSeek" and &1.id =~ "rec:provider:")).id

    {state, _fake} =
      state
      |> Ops.run([{:open, %Page{section: :providers, record: {"provider", id}}}])
      |> serve(fake)

    on_name = Nav.put_cursor(state, "fld:provider:#{id}:name")
    {ignored, _} = Reducer.update(on_name, {:settings, {:paste, "sk-pasted-0000000000001"}})
    assert ignored.settings.mode == :browse
    assert ignored.settings.paste == nil

    on_key = Nav.put_cursor(state, "fld:provider:#{id}:api_key")
    {pasted, _} = Reducer.update(on_key, {:settings, {:paste, "sk-pasted-0000000000001"}})
    assert pasted.settings.mode == :paste
    assert pasted.settings.paste.bytes == "sk-pasted-0000000000001"
    assert Enum.any?(lines(pasted), &(&1 =~ "pasted · not shown"))
    refute Enum.any?(lines(pasted), &(&1 =~ "sk-pasted"))
  end

  # cli74 F30 (found in the sandbox at 160 x 45): a registry action row drew its
  # label twice ("Export settings…  ▸ Export settings…"); the value says what it does.
  test "a registry action row says what it does beside its label, not the label again" do
    {state, _fake} =
      ready()
      |> Reducer.update({:settings_open, {:section, :import_export}})
      |> serve(FakeSettings.seed())

    export = Enum.find(Nav.rows(state), &(&1.id == "key:transfer.export"))
    value = Enum.map_join(export.value, "", &elem(&1, 0))

    assert export.label == "Export settings…"
    refute value =~ "Export settings"
    assert value == "▸ writes the chosen scopes to a JSON file (0600)"
  end
end
