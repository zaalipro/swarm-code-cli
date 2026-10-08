defmodule SwarmCodeCLI.UI.Cli021.B4CommandHighlightTest do
  @moduledoc """
  cli021 B4: the command token of a slash draft is drawn in the command colour
  (the accent the palette names its commands in), its arguments in normal text,
  an unknown `/word` muted. Typing, the cursor and the wrapping are unchanged.
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{
    Capabilities,
    Drafts,
    Editor,
    Fixtures,
    Projector,
    SafeText,
    Size,
    State,
    Theme
  }

  @size %Size{columns: 120, rows: 40}
  @caps %Capabilities{size: @size, color_mode: :truecolor}

  defp accent, do: Theme.style(:accent, @caps).foreground
  defp muted, do: Theme.style(:text_muted, @caps).foreground
  defp primary, do: Theme.style(:text_primary, @caps).foreground

  defp idle do
    state = %{Fixtures.representative(:chat, @size, @caps) | focus: "composer"}
    runs = Map.new(state.read_model.runs, fn {id, run} -> {id, %{run | state: :done}} end)
    put_in(state.read_model.runs, runs)
  end

  defp typed(text) do
    state = idle()
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

  defp span(spans, text), do: Enum.find(spans, &(SafeText.value(&1.text) == text))

  test "a known command is in the accent, bold; its arguments are normal text" do
    spans = composer_spans(typed("/panel compact"))
    command = span(spans, "/panel")
    assert command.style.foreground == accent()
    assert :bold in command.style.modifiers
    arguments = Enum.find(spans, &(SafeText.value(&1.text) =~ "compact"))
    assert arguments.style.foreground == primary()
    refute :bold in arguments.style.modifiers
  end

  test "the worker commands and their hidden old names are known" do
    for name <- ["/worker_effort", "/swarm_effort", "/effort", "/model", "/quit"] do
      spans = composer_spans(typed(name <> " x"))
      assert span(spans, name).style.foreground == accent(), name
    end
  end

  test "an unknown /word is muted, and so is a half-typed one" do
    for word <- ["/nosuchthing", "/pan"] do
      spans = composer_spans(typed(word <> " rest"))
      assert span(spans, word).style.foreground == muted(), word
    end
  end

  test "only the first word of a draft that starts with a slash" do
    spans = composer_spans(typed("/panel full and /effort"))

    commands =
      Enum.filter(spans, fn span ->
        span.style.foreground == accent() and SafeText.value(span.text) =~ "/"
      end)

    assert Enum.map(commands, &SafeText.value(&1.text)) == ["/panel"]
  end

  test "a path or a plain message is not a command" do
    for text <- ["/etc/hosts is wrong", "fix /panel please", "hello"] do
      spans = composer_spans(typed(text))

      refute Enum.any?(
               spans,
               &(&1.style.foreground == accent() and SafeText.value(&1.text) =~ "/")
             ),
             text
    end
  end

  test "the draft's text is unchanged by the colouring" do
    text = "/panel summaries off"
    spans = composer_spans(typed(text))
    drawn = spans |> Enum.map(&SafeText.value(&1.text)) |> Enum.join()
    assert drawn =~ text
  end

  test "a draft that wraps keeps its first token highlighted; a scrolled one has none on screen" do
    wrapped = composer_spans(typed("/goal " <> String.duplicate("word ", 40)))
    assert span(wrapped, "/goal").style.foreground == accent()

    scrolled = composer_spans(typed("/goal " <> String.duplicate("word ", 400)))
    assert span(scrolled, "/goal") == nil
  end
end
