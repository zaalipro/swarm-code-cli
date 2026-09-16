defmodule SwarmCodeCLI.UI.ReducerPresentationTest do
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{
    Reducer,
    Init,
    Size,
    Capabilities,
    Drafts,
    Editor,
    Draft,
    Layout,
    SafeText
  }

  def initial do
    size = %Size{columns: 170, rows: 40}

    {state, _} =
      Reducer.init(%Init{
        size: size,
        capabilities: %Capabilities{size: size},
        source_epoch: "e",
        destination: {:conversation, "c"}
      })

    state
  end

  test "every draft dirty dimension prompts while presentation alone remains clean" do
    state = initial()
    clean = Drafts.fetch(state.drafts, {"c", :main})
    {:ok, name} = SafeText.external("picture", SafeText.Limits.content())

    attachment =
      Draft.AttachmentRef.new!(
        id: "a",
        name: name,
        media_type: "image/png",
        byte_size: 0,
        status: :pending,
        reference: "ref"
      )

    for draft <- [
          %{clean | target: :main},
          %{clean | attachments: [attachment]},
          %{clean | staged_validation: {:pending, "v"}},
          %{clean | chips: [{:command, "cmd", name}]}
        ] do
      dirty = %{state | drafts: Drafts.put(state.drafts, draft)}
      {next, []} = Reducer.update(dirty, {:quit_requested, :detach})
      assert next.layers == [{:unsent_changes, :detach}]
      assert next.focus == "cancel"
    end

    {:ok, editor} = Editor.apply(clean.editor, {:insert, " "})
    {:ok, editor} = Editor.apply(editor, :select_all)
    draft = %{clean | editor: editor, height: 8, scroll_x: 200, scroll_y: 100}
    clean_state = %{state | drafts: Drafts.put(state.drafts, draft)}
    assert {_, [{:detach, 0}]} = Reducer.update(clean_state, {:quit_requested, :detach})
  end

  test "dock preferences survive clamping and reset exactly; composer is bounded" do
    state = initial()
    {state, []} = Reducer.update(state, {:layout_adjust, :navigator, {:preset, :wide}})
    {state, []} = Reducer.update(state, {:layout_adjust, :inspector, {:preset, :wide}})
    {narrow, []} = Reducer.update(state, {:resize, %Size{columns: 60, rows: 20}})
    assert narrow.preferences == state.preferences
    {restored, []} = Reducer.update(narrow, {:resize, state.size})
    # The navigator pane is gone, so its preference round-trips without ever
    # becoming a rectangle; the inspector still proves the clamping path.
    assert restored.preferences.navigator_width == 32
    refute Map.has_key?(Layout.calculate(restored.size, restored.preferences).rects, :navigator)
    assert Layout.calculate(restored.size, restored.preferences).rects.inspector.width == 56
    {restored, []} = Reducer.update(restored, {:layout_adjust, :navigator, :reset})
    {restored, []} = Reducer.update(restored, {:layout_adjust, :inspector, :reset})
    assert restored.preferences.navigator_width == 26
    assert restored.preferences.inspector_width == 42

    grown =
      Enum.reduce(1..20, restored, fn _, acc ->
        elem(Reducer.update(acc, {:composer_height, {:nudge, 1}}), 0)
      end)

    assert grown.composer_height == 8

    shrunk =
      Enum.reduce(1..20, grown, fn _, acc ->
        elem(Reducer.update(acc, {:composer_height, {:nudge, -1}}), 0)
      end)

    assert shrunk.composer_height == 1
    assert {reset, []} = Reducer.update(shrunk, {:composer_height, :reset})
    assert reset.composer_height == 3
  end

  # Opening the companion is entirely an effect: the pinned state proves the
  # reducer touched nothing, including the revision.
  test "opening the visual companion emits one effect and leaves state untouched" do
    state = initial()
    assert {:ok, :open_companion} = SwarmCodeCLI.UI.Action.validate(:open_companion)
    assert {^state, [{:companion, :open}]} = Reducer.update(state, :open_companion)
    assert {:ok, {:companion, :open}} = SwarmCodeCLI.UI.Effect.validate({:companion, :open})
  end
end
