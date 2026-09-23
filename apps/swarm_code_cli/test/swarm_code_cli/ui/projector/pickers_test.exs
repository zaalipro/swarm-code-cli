defmodule SwarmCodeCLI.UI.Projector.PickersTest do
  @moduledoc """
  pass70 D7 (ux M7): the palette and the model picker as painted in colour —
  the title with the query's letters in the accent, the kind or the shortcut
  against the right edge, provider headings above their models with the one
  in use checked, a box as tall as its rows — and the composer's `@path`
  popup with its matched letters. (The slash popup draws E's `args` when the
  catalogue carries them; this branch's catalogue does not.)
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.Demo.Conversation
  alias SwarmCodeCLI.UI.{Capabilities, Drafts, Editor, FieldEditors, Paint, Projector, Size}
  alias SwarmCodeCLI.UI.{Switcher, Theme}
  alias SwarmCodeCLI.UI.Paint.{Options, Plan}

  defp scene(name, {columns, rows}, opts \\ []) do
    size = %Size{columns: columns, rows: rows}
    caps = %Capabilities{size: size, color_mode: Keyword.get(opts, :color, :truecolor)}
    Conversation.state(name, size, caps)
  end

  defp screen(state) do
    {scene, table} = Projector.project(state)
    assert {:ok, plan} = Paint.build(scene, %Options{color_mode: state.capabilities.color_mode})
    assert :ok = Plan.validate(plan)

    rows =
      for y <- 0..(state.size.rows - 1) do
        for x <- 0..(state.size.columns - 1), reduce: "" do
          acc ->
            case Plan.cell(plan, x, y) do
              {:glyph, glyph, _, _} -> acc <> glyph
              _ -> acc
            end
        end
        |> String.trim_trailing()
      end

    {rows, scene, table, plan}
  end

  defp foreground(plan, x, y) do
    {:glyph, _, _, style} = Plan.cell(plan, x, y)
    elem(plan.palette, style).foreground
  end

  defp palette(state, query) do
    layer = {:switcher, "palette"}
    {:ok, editor} = Editor.apply(Editor.new(max_bytes: 16_384), {:insert, query})

    %{
      state
      | layers: [layer],
        focus: "dialog",
        field_editors: FieldEditors.put(state.field_editors, Switcher.field_key(layer), editor)
    }
  end

  defp draft(state, text) do
    {:ok, editor} = Editor.apply(Editor.new(), {:paste, text})
    draft = Drafts.fetch(state.drafts, {"demo-conversation", :main})
    %{state | drafts: Drafts.put(state.drafts, %{draft | editor: editor})}
  end

  describe "the palette" do
    test "a matching entry shows the query's letters in the accent and its key on the right" do
      state = scene(:first_reply, {120, 36}) |> palette("help")
      {rows, _scene, _table, plan} = screen(state)

      y = Enum.find_index(rows, &(&1 =~ ~r/Help +\? │/))
      assert y, Enum.join(rows, "\n")

      row = Enum.at(rows, y)
      x = row |> :binary.match("Help") |> elem(0)
      x = String.length(binary_part(row, 0, x))
      accent = Theme.style(:accent, state.capabilities).foreground.value
      assert foreground(plan, x, y) == accent
    end

    # pass70 F: the palette matches fuzzily, so it lists titles that do not
    # contain the query; the highlight crashed the projector on every one of
    # them (typing "Settings" in the palette closed the session).
    test "every prefix of a query projects, whether or not a title contains it" do
      for query <- ["S", "Se", "Set", "Sett", "Settings", "stg", "zz"] do
        state = scene(:first_reply, {120, 36}) |> palette(query)
        {rows, _scene, _table, _plan} = screen(state)
        assert Enum.any?(rows, &(&1 =~ "Search:"))
      end
    end

    test "entries that are not actions say what they are" do
      state = scene(:first_reply, {120, 36}) |> palette("Run:")
      {rows, _scene, _table, _plan} = screen(state)
      # E3 labels run entries "Run: <title>"; the kind sits right-aligned.
      assert Enum.any?(rows, &(&1 =~ ~r/Run: .* run │/)), Enum.join(rows, "\n")
    end

    test "the box is as tall as its rows" do
      state = scene(:first_reply, {120, 40}) |> palette("help")
      {_rows, scene, _table, _plan} = screen(state)
      assert scene.overlay.rect.height < 24
    end
  end

  describe "the model picker" do
    test "providers head their models, the model in use is checked, headings are not items" do
      state = scene(:first_reply, {120, 36})
      state = %{state | layers: [{:model_picker, :chat, "m1"}], focus: "dialog"}
      {rows, scene, _table, _plan} = screen(state)

      llmotions = Enum.find_index(rows, &(&1 =~ ~r/│  llmotions +│/))
      anthropic = Enum.find_index(rows, &(&1 =~ ~r/│  anthropic +│/))
      assert llmotions && anthropic && llmotions < anthropic

      assert Enum.at(rows, llmotions + 1) =~ ~r/✓ deepseek-v4\.1-flash +in use │/
      assert Enum.at(rows, anthropic + 1) =~ "claude-opus-5"
      assert Enum.any?(rows, &(&1 =~ "1 of 3 · Enter chooses · Esc closes"))
      assert scene.overlay.rect.height <= 10
    end

    test "monochrome keeps the provider after the model and no headings" do
      state = scene(:first_reply, {120, 36}, color: :monochrome)
      state = %{state | layers: [{:model_picker, :chat, "m1"}], focus: "dialog"}
      {rows, _scene, _table, _plan} = screen(state)

      refute Enum.any?(rows, &(&1 =~ ~r/│  anthropic +│/))
      assert Enum.any?(rows, &(&1 =~ "claude-opus-5  anthropic"))
    end
  end

  describe "composer popups" do
    test "the @path popup lists files with the matched letters picked out" do
      state = scene(:first_reply, {120, 36}) |> draft("look at @gua")

      completion = %{
        key: {"demo-conversation", :main},
        query: "gua",
        request_id: "r1",
        index: 0,
        dismissed?: false,
        items: [
          %{id: "lib/tickets/guard.ex", title: "lib/tickets/guard.ex", matches: [12, 13, 14]},
          %{id: "test/tickets/guard_test.exs", title: "test/tickets/guard_test.exs", matches: []}
        ]
      }

      state = Map.put(state, :path_completion, completion)
      {rows, _scene, _table, plan} = screen(state)

      y = Enum.find_index(rows, &(&1 =~ "@lib/tickets/guard.ex"))
      assert y, Enum.join(rows, "\n")
      assert Enum.at(rows, y) =~ ~r/Tab insert$/
      assert Enum.at(rows, y + 1) =~ "@test/tickets/guard_test.exs"

      row = Enum.at(rows, y)
      at = row |> :binary.match("@lib/tickets/") |> elem(0)
      x = String.length(binary_part(row, 0, at)) + 1
      accent = Theme.style(:accent, state.capabilities).foreground.value
      assert foreground(plan, x + 12, y) == accent
      refute foreground(plan, x, y) == accent
    end

    test "a dismissed completion draws nothing" do
      state = scene(:first_reply, {120, 36}) |> draft("look at @gua")

      completion = %{
        index: 0,
        dismissed?: true,
        items: [%{id: "lib/a.ex", title: "lib/a.ex", matches: []}]
      }

      {rows, _scene, _table, _plan} = screen(Map.put(state, :path_completion, completion))
      refute Enum.any?(rows, &(&1 =~ "@lib/a.ex"))
    end
  end
end
