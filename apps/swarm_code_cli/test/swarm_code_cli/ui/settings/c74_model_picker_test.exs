defmodule SwarmCodeCLI.UI.Settings.C74ModelPickerTest do
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.DataSource.Fake.SettingsIntegrations, as: I
  alias SwarmCodeCLI.UI.Settings.ModelPicker
  import SwarmCodeCLI.Test.C74U2Ctx

  @ids I.ids()
  @chat %{"provider_id" => @ids.deepseek, "model" => "deepseek-v4-pro"}

  defp open(opts \\ %{}, c \\ ctx()) do
    row = %{key: "models.chat", label: "Chat model"}

    {:ok, s} =
      ModelPicker.init(row, Map.merge(%{current: @chat, subtitle: "new conversations"}, opts), c)

    {s, c}
  end

  defp keys(s, c, events) do
    Enum.reduce(events, s, fn e, acc ->
      {:cont, next} = ModelPicker.handle(acc, e, c)
      next
    end)
  end

  defp rows_text(s, c), do: ModelPicker.display(s, c).popover.rows |> Enum.map(&text(&1.segments))

  test "groups by provider with prices, contexts and the current mark" do
    {s, c} = open()
    view = ModelPicker.display(s, c)
    assert view.popover.meta == "3 providers · 5 models"
    assert view.context == :settings_picker
    lines = rows_text(s, c)
    assert Enum.at(lines, 0) =~ "Anthropic  Anthropic · not fetched this session"

    assert Enum.any?(
             lines,
             &(&1 =~ ~r/✓ deepseek-v4-pro\s+family default\s+0.27 · 1.10\s+current/)
           )

    assert Enum.any?(lines, &(&1 =~ ~r/claude-opus-5\s+200k\s+15.00 · 75.00/))
    assert Enum.any?(lines, &(&1 =~ ~r/claude-sonnet-5\s+family default\s+no price/))
    # the cursor starts on the current value
    assert view.value == [{"deepseek-v4-pro", :text_primary}, {" · DeepSeek", :text_faint}]
    assert view.popover.position == "4 of 5"
  end

  test "choosing writes the model wire value" do
    {s, c} = open()
    s = keys(s, c, [{:key, :up}])

    assert {:commit, %{"provider_id" => pid, "model" => "deepseek-v4-flash"}, _} =
             ModelPicker.handle(s, {:key, :enter}, c)

    assert pid == @ids.deepseek
  end

  test "the filter matches words and provider/model, and Esc clears before it closes" do
    {s, c} = open()
    s = keys(s, c, [{:text, "o"}, {:text, "p"}, {:text, "u"}, {:text, "s"}])
    assert Enum.count(ModelPicker.choices(s, c)) == 1
    assert {:commit, %{"model" => "claude-opus-5"}, _} = ModelPicker.handle(s, {:key, :enter}, c)

    s = keys(s, c, [{:key, :escape}])
    assert s.query == ""
    assert {:cancel, _} = ModelPicker.handle(s, {:key, :escape}, c)

    {s, c} = open()
    s = keys(s, c, [{:text, "/"}, {:paste, "deep/flash"}])
    assert [{:model, _, "DeepSeek", "deepseek-v4-flash", _}] = ModelPicker.choices(s, c)
  end

  test "a query that matches nothing offers the model as typed" do
    {s, c} = open()
    s = keys(s, c, [{:paste, "deepseek/deepseek-v5"}])
    assert [{:typed, pid, "DeepSeek", "deepseek-v5"}] = ModelPicker.choices(s, c)
    assert pid == @ids.deepseek

    assert Enum.any?(
             rows_text(s, c),
             &(&1 =~ "use “deepseek-v5” with DeepSeek as typed · not in its list")
           )

    assert {:commit, %{"model" => "deepseek-v5"}, _} = ModelPicker.handle(s, {:key, :enter}, c)
  end

  test "a nullable entry offers its null choice first, and it commits null" do
    {s, c} = open(%{nullable: true, null_label: "the chat model", current: nil})
    assert [{:null, "the chat model"} | _] = ModelPicker.choices(s, c)
    assert {:commit, nil, _} = ModelPicker.handle(s, {:key, :enter}, c)
  end

  test "limited to one provider for a provider's default model" do
    {s, c} = open(%{provider_id: @ids.anthropic, current: nil})

    assert Enum.map(ModelPicker.choices(s, c), &elem(&1, 3)) == [
             "claude-opus-5",
             "claude-sonnet-5"
           ]
  end

  test "Tab jumps to the next provider; f fetches the focused provider's list" do
    {s, c} = open(%{current: nil})
    assert {:model, _, "Anthropic", _, _} = Enum.at(ModelPicker.choices(s, c), s.cursor)
    s = keys(s, c, [{:key, :tab}])
    assert {:model, pid, "DeepSeek", _, _} = Enum.at(ModelPicker.choices(s, c), s.cursor)

    assert {:ops, [{:task, "provider.fetch_models", %{"id" => ^pid}, %{}}], _} =
             ModelPicker.handle(s, {:text, "f"}, c)
  end

  test "fetch state per provider and not-in-the-last-fetch marks" do
    state = I.seed()

    {{:task, task, _}, state} =
      I.command(state, %{
        "action" => "provider.fetch_models",
        "target" => %{"id" => @ids.deepseek}
      })

    {{:done, _, _}, state} = I.run_task(state, Map.put(task, "task_id", "f1"))
    c = ctx(state)
    {s, c} = open(%{}, c)
    lines = rows_text(s, c)

    assert Enum.any?(
             lines,
             &(&1 =~ "DeepSeek  OpenAI-compatible · fetched this session #{local_hhmm(18, 40)}")
           )

    assert Enum.any?(lines, &(&1 =~ ~r/deepseek-v4-flash.*not in the last fetch/))

    c =
      put_task(c, "t9", %{
        action: "provider.fetch_models",
        target: %{"id" => @ids.anthropic},
        state: "running",
        elapsed_ms: 1_000
      })

    assert Enum.any?(rows_text(s, c), &(&1 =~ "Anthropic  ◷ fetching the model list · 1 s"))
  end

  test "before the options arrive the picker says so" do
    c = ctx(I.seed(), kinds: [])
    {s, c} = open(%{}, c)
    assert rows_text(s, c) == ["…"]
    assert ModelPicker.describe(@chat, c, nil) == [{"deepseek-v4-pro", :text_primary}]
    c = ctx()

    assert ModelPicker.describe(%{"provider_id" => "gone", "model" => "x"}, c, nil) == [
             {"! the provider was deleted; pick another", :warning}
           ]
  end
end
