defmodule SwarmCodeCLI.UI.Settings.C74EditorsTest do
  @moduledoc """
  cli74 U1-8/U1-9: the settings editors, key by key — enum, number
  (bounds, specials, nullable, big steps), text, checklist, multi-line
  (Ctrl-S, Ctrl-X and the text coming back), list (add, edit, remove,
  move, remove all, item checks, the filter, a 2 000-item list drawn in a
  window), the language-server command, and the model fallback when the
  model picker is not in this build.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers, only: [ready: 0]

  alias SwarmCode.Settings.Registry
  alias SwarmCodeCLI.UI.Reducer
  alias SwarmCodeCLI.UI.Settings.{Ctx, Editors, Nav, Row}

  @ctx %Ctx{}

  defp run(module, opts, events) do
    {:ok, state} = module.init(%Row{id: "r"}, opts, @ctx)

    Enum.reduce_while(events, {:cont, state}, fn event, {_, state} ->
      case module.handle(state, event, @ctx) do
        {:cont, state} -> {:cont, {:cont, state}}
        other -> {:halt, other}
      end
    end)
  end

  defp text(string), do: Enum.map(String.graphemes(string), &{:text, &1})

  test "enum: arrows move, Enter writes, Esc cancels, a letter jumps" do
    opts = %{choices: [%{value: "a", label: "Alpha"}, %{value: "b", label: "Beta"}], value: "a"}
    assert {:commit, "b", _} = run(Editors.Enum, opts, [{:key, :right}, {:key, :enter}])
    assert {:cancel, _} = run(Editors.Enum, opts, [{:key, :right}, {:key, :escape}])
    assert {:commit, "b", _} = run(Editors.Enum, opts, [{:text, "b"}, {:key, :enter}])
  end

  test "number: a typed value outside the bounds shows the message and does not commit" do
    entry = Registry.fetch!("terminal.composer_rows")
    opts = %{entry: entry, value: 3, min: 1, max: 8, step: 1, nullable: false}

    assert {:cont, state} =
             run(Editors.Number, opts, [{:key, {:ctrl, "u"}}] ++ text("99") ++ [{:key, :enter}])

    %{lines: lines} = Editors.Number.display(state, @ctx)
    assert Enum.any?(lines, fn line -> Enum.any?(line, &(elem(&1, 0) =~ "between")) end)

    assert {:commit, 5, _} =
             run(Editors.Number, opts, [{:key, :right}, {:key, :right}, {:key, :enter}])
  end

  test "number: Shift-→ moves the command timeout by one big step" do
    entry = Registry.fetch!("limits.command_timeout")

    opts = %{
      entry: entry,
      value: entry.default,
      min: entry.min,
      max: entry.max,
      step: entry.step,
      big_step: entry.big_step
    }

    assert Editors.Number.step(opts, entry.default, 1, :big) - entry.default == entry.big_step
    assert entry.big_step == 60 or entry.big_step == 60_000
  end

  test "text: one line only; the entry's checks run on Enter" do
    entry = Registry.fetch!("terminal.hint_letters")
    assert {:cont, state} = run(Editors.Text, %{entry: entry, value: ""}, [{:paste, "a\nb"}])
    assert state.error == "one line only"

    assert {:commit, "sfghjklwer", _} =
             run(Editors.Text, %{entry: entry, value: ""}, text("sfghjklwer") ++ [{:key, :enter}])
  end

  test "checklist: Space ticks, Enter writes in the choices' order" do
    opts = %{
      choices: [%{value: "a", label: "A"}, %{value: "b", label: "B"}, %{value: "c", label: "C"}],
      value: ["c"]
    }

    assert {:commit, ["a", "c"], _} =
             run(Editors.Checklist, opts, [{:key, :space}, {:key, :enter}])
  end

  test "multi-line: Enter breaks the line, Ctrl-S writes, Ctrl-X hands it to the editor" do
    assert {:commit, "one\ntwo", _} =
             run(
               Editors.Multiline,
               %{value: ""},
               text("one") ++ [{:key, :enter}] ++ text("two") ++ [{:key, {:ctrl, "s"}}]
             )

    assert {:ops, [{:external_edit, %{content: "x", suffix: ".md"}}], _} =
             run(Editors.Multiline, %{value: "x"}, [{:key, {:ctrl, "x"}}])

    assert {:cont, state} = run(Editors.Multiline, %{value: "", max: 4}, text("hello"))
    assert state.error == "that is longer than 4 bytes"
    assert state.buffer.text == "hell"
  end

  test "list: add, edit, remove, move, remove all; items are checked" do
    entry = Registry.fetch!("research.include_domains")
    opts = %{value: ["a.com"], entry: entry}

    assert {:commit, ["a.com", "b.org"], _} =
             run(
               Editors.List,
               opts,
               [{:text, "a"}] ++ text("b.org") ++ [{:key, :enter}, {:key, {:ctrl, "s"}}]
             )

    assert {:cont, state} =
             run(Editors.List, opts, [{:text, "a"}] ++ text("not a domain") ++ [{:key, :enter}])

    assert is_binary(state.error)

    assert {:commit, ["c.net"], _} =
             run(
               Editors.List,
               opts,
               [{:key, :enter}, {:key, {:ctrl, "u"}}] ++
                 text("c.net") ++ [{:key, :enter}, {:key, {:ctrl, "s"}}]
             )

    assert {:commit, [], _} = run(Editors.List, opts, [{:text, "x"}, {:key, {:ctrl, "s"}}])

    two = %{value: ["a.com", "b.com"], entry: entry}

    assert {:commit, ["b.com", "a.com"], _} =
             run(Editors.List, two, [{:text, "J"}, {:key, {:ctrl, "s"}}])

    assert {:commit, [], _} =
             run(Editors.List, two, [{:text, "X"}, {:text, "y"}, {:key, {:ctrl, "s"}}])

    assert {:commit, ["a.com", "b.com"], _} =
             run(Editors.List, two, [{:text, "X"}, {:text, "n"}, {:key, {:ctrl, "s"}}])
  end

  test "list: a 2 000-item list draws only a window and filters with /" do
    items = for n <- 1..2_000, do: "host#{n}.com"
    {:ok, state} = Editors.List.init(%Row{id: "r"}, %{value: items}, @ctx)
    %{lines: lines} = Editors.List.display(state, @ctx)
    assert length(lines) <= 12

    {:cont, state} = Editors.List.handle(state, {:text, "/"}, @ctx)

    state =
      Enum.reduce(text("host1999"), state, fn event, acc ->
        elem(Editors.List.handle(acc, event, @ctx), 1)
      end)

    %{lines: lines} = Editors.List.display(state, @ctx)
    assert Enum.any?(lines, fn line -> Enum.any?(line, &(elem(&1, 0) == "host1999.com")) end)
  end

  test "lsp command: default, off, or a typed command" do
    assert {:commit, nil, _} =
             run(Editors.LspCommand, %{value: "off"}, [{:key, :left}, {:key, :enter}])

    assert {:commit, "off", _} =
             run(Editors.LspCommand, %{value: nil}, [{:key, :right}, {:key, :enter}])

    assert {:commit, "elixir-ls --stdio", _} =
             run(Editors.LspCommand, %{value: nil}, text("elixir-ls --stdio") ++ [{:key, :enter}])
  end

  test "a model row opens the model picker (U2) with the current model" do
    state = Reducer.update(ready(), {:settings_open, {:section, :models_effort}}) |> elem(0)
    value = %{"provider_id" => "p1", "model" => "deepseek-v4-pro"}

    setting = %{
      key: "models.chat",
      value: value,
      layers: [],
      winner: :global,
      base: value,
      state: :ok
    }

    layer = state.settings

    state = %{
      state
      | settings: %{layer | data: %{layer.data | values: %{"models.chat" => setting}}}
    }

    row = Enum.find(Nav.rows(state), &(&1.key == "models.chat"))
    assert {SwarmCodeCLI.UI.Settings.ModelPicker, %{current: ^value}} = row.editor

    {state, _} = SwarmCodeCLI.UI.Reducer.Settings.Edit.open(state, row)
    assert state.settings.editing.module == SwarmCodeCLI.UI.Settings.ModelPicker
    assert %{key: "models.chat", current: ^value} = state.settings.editing.state
  end
end
