defmodule SwarmCodeCLI.UI.Pass73ComposerKeywordTest do
  @moduledoc """
  pass73 T5: the word "workflow" in a message (K's `WorkflowKeyword`) is drawn
  in the workflow colour, bold, in the composer, and a one-line hint above the
  composer says the message goes as `/create-workflow` and which key sends it
  plain. A slash command, a word inside backticks or a longer name
  (`create-workflow`) is neither highlighted nor hinted.
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{
    Capabilities,
    Drafts,
    Editor,
    Fixtures,
    Paint,
    Projector,
    SafeText,
    Size,
    State,
    Theme
  }

  alias SwarmCodeCLI.UI.Paint.{Options, Plan}
  alias SwarmCodeCLI.UI.Projector.Composer

  @size %Size{columns: 160, rows: 45}

  test "the keyword is bold in the workflow colour; the rest of the draft is plain" do
    state = typed(idle(), "build a Workflow that tags releases and other workflows")
    spans = composer_spans(state)

    keyword = Enum.filter(spans, &(:bold in &1.style.modifiers and &1.style.foreground == blue()))
    assert Enum.map(keyword, &SafeText.value(&1.text)) == ["Workflow", "workflows"]

    plain = Enum.find(spans, &(SafeText.value(&1.text) =~ "that tags releases"))
    refute :bold in plain.style.modifiers
  end

  test "no highlight for a slash command, backticks or a longer name" do
    for text <- [
          "/create-workflow tag releases",
          "fix the `workflow` module",
          "read priv/workflows/ and create-workflow.md"
        ] do
      spans = composer_spans(typed(idle(), text))

      refute Enum.any?(spans, &(&1.style.foreground == blue() and :bold in &1.style.modifiers)),
             text

      assert Composer.workflow_hint(typed(idle(), text), 160) == nil, text
    end
  end

  test "a draft that routes gets the hint line above the composer, with the opt-out key" do
    state = typed(idle(), "make a workflow for the nightly build")
    hint = Composer.workflow_hint(state, 160)
    text = Enum.map_join(hint.spans, &SafeText.value(&1.text))
    assert text =~ "workflow · sends as /create-workflow · Ctrl-S plain message"

    screen = screen(state)
    at = Enum.find_index(screen, &(&1 =~ "sends as /create-workflow"))
    assert at
    # The hint sits on the row right above the draft.
    assert Enum.at(screen, at + 1) =~ "make a workflow for the nightly build"
  end

  test "the highlight follows a draft that wraps and scrolls" do
    long = String.duplicate("word ", 60) <> "then a workflow at the end"
    spans = composer_spans(typed(idle(), long))

    assert Enum.any?(
             spans,
             &(SafeText.value(&1.text) == "workflow" and &1.style.foreground == blue())
           )
  end

  test "ASCII terminals get the same hint without the middle dot" do
    size = @size
    caps = %Capabilities{size: size, ascii?: true}
    state = typed(%{Fixtures.representative(:chat, size, caps) | focus: "composer"}, "a workflow")
    state = done(state)
    text = Enum.map_join(Composer.workflow_hint(state, 160).spans, &SafeText.value(&1.text))
    assert text =~ "workflow - sends as /create-workflow - Ctrl-S plain message"
  end

  # ------------------------------------------------------------------ helpers

  defp blue, do: Theme.style(:run_workflow, %Capabilities{size: @size}).foreground

  defp idle do
    done(%{Fixtures.representative(:chat, @size, %Capabilities{size: @size}) | focus: "composer"})
  end

  defp done(state) do
    runs = Map.new(state.read_model.runs, fn {id, run} -> {id, %{run | state: :done}} end)
    put_in(state.read_model.runs, runs)
  end

  defp typed(state, text) do
    key = State.current_draft_key(state)
    draft = Drafts.fetch(state.drafts, key)
    {:ok, editor} = Editor.apply(draft.editor, {:paste, text})
    %{state | drafts: Drafts.put(state.drafts, %{draft | editor: editor})}
  end

  defp composer_spans(state) do
    {scene, _} = Projector.project(state)
    composer = Enum.find(scene.regions, &(&1.role == :composer))
    Enum.flat_map(composer.blocks, &Map.get(&1, :spans, []))
  end

  defp screen(state) do
    {scene, _} = Projector.project(state)
    {:ok, plan} = Paint.build(scene, %Options{color_mode: :truecolor})

    for y <- 0..(state.size.rows - 1) do
      Enum.map_join(0..(state.size.columns - 1), fn x ->
        case Plan.cell(plan, x, y) do
          {:glyph, g, _, _} -> g
          _ -> " "
        end
      end)
    end
  end
end
