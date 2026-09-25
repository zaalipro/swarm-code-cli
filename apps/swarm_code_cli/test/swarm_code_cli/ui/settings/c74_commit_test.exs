defmodule SwarmCodeCLI.UI.Settings.C74CommitTest do
  @moduledoc """
  cli74 U1-6/U1-7: registry rows (value, tag, marks, lines, editor, detail),
  the minimal editors, and the commit path of terminal keys — one write in
  flight per key, the queued value, `saving…`, accepted/unchanged/conflict/
  rejected, undo and redo, toasts, live consumers — and every section drawn
  by the settings projector.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers

  alias SwarmCode.Settings.Registry
  alias SwarmCodeCLI.UI.{Input, Projector, Reducer, SafeText}
  alias SwarmCodeCLI.UI.Settings.{Editors, Layer, Nav, Provenance, Row, Rows, Sections}

  defp act(state, action), do: Reducer.update(state, action)
  defp act!(state, action), do: elem(act(state, action), 0)
  defp verb(state, verb), do: act(state, {:settings, {:verb, verb}})
  defp verb!(state, verb), do: elem(verb(state, verb), 0)

  defp open(state, key), do: act!(state, {:settings_open, {:key, key}})

  defp row(state, key), do: Enum.find(Nav.rows(state), &(&1.id == "key:" <> key))

  defp words(segments), do: Enum.map_join(segments, "", &elem(&1, 0))

  defp cli_write(effects),
    do: Enum.find(effects, &match?({:settings_cli_write, _, _, _, _}, &1))

  defp cli_snapshot(values), do: %{values: values, status: :ok}

  defp answer(state, {:settings_cli_write, generation, ref, changes, _expected}, result \\ nil) do
    result =
      result ||
        {:ok,
         cli_snapshot(
           Enum.reduce(changes, state.prefs, fn
             {name, :remove}, acc -> Map.delete(acc, name)
             {name, value}, acc -> Map.put(acc, name, value)
           end)
         )}

    act(state, {:settings, {:cli_result, generation, ref, result}})
  end

  defp screen(state) do
    {scene, _actions} = Projector.project(state)

    scene.regions
    |> Enum.flat_map(& &1.blocks)
    |> Enum.map_join("\n", fn block ->
      Enum.map_join(block.spans, "", &SafeText.value(&1.text))
    end)
  end

  describe "rows from the registry" do
    test "a terminal toggle row: its value, the default tag and a toggle editor" do
      state = ready() |> open("terminal.show_diffs")
      row = row(state, "terminal.show_diffs")

      assert %Row{kind: :setting, label: "Show diffs"} = row
      assert words(row.value) == "on"
      assert words(row.tag) == "default"
      assert row.marks == []
      assert {Editors.Toggle, %{value: true}} = row.editor
      assert row.detail.key_line == ~s(terminal.show_diffs · cli.json "show_diffs")
      assert {"scope", "this machine's terminal"} in row.detail.facts
    end

    test "a value in cli.json wins over the default and is marked changed" do
      state = %{ready() | prefs: %{"panel" => "compact"}} |> open("terminal.panel")
      row = row(state, "terminal.panel")

      assert words(row.value) =~ "ompact"
      assert words(row.tag) == "cli.json"
      assert :changed in row.marks
    end

    test "an env override wins while set, and the row says so; an ignored one never wins" do
      facts = %{
        env_overrides: %{
          "terminal.theme" => %{var: "SWARM_THEME", value: "light"},
          "terminal.keymap" => %{
            var: "SWARM_KEYMAP",
            value: "emacs",
            ignored: true,
            note: "not a keymap"
          }
        }
      }

      state =
        %{ready() | prefs: %{"theme" => "dark"}, launch_facts: facts} |> open("terminal.theme")

      theme = row(state, "terminal.theme")

      assert words(theme.tag) == "env SWARM_THEME"

      assert Enum.any?(
               theme.lines,
               &(words(&1) =~ "SWARM_THEME=light wins while set · cli.json: dark")
             )

      keymap_entry = Registry.fetch!("terminal.keymap")
      setting = Provenance.cli_value(keymap_entry, %{}, [], facts, %{})
      assert setting.winner == :default
      assert Enum.any?(setting.layers, &(&1.layer == :env and &1.ignored))
    end

    test "every section's default page builds rows and draws at three sizes and in ASCII" do
      for id <- Sections.ids(), {columns, rows} <- [{160, 45}, {100, 30}, {80, 24}] do
        state = ready() |> resize(columns, rows) |> act!({:settings_open, {:section, id}})
        assert is_list(Nav.rows(state))
        text = screen(state)
        assert text =~ "Settings"
        assert text =~ Sections.title(id)
      end

      ascii = ready() |> ascii() |> act!({:settings_open, {:section, :layout}})
      refute screen(ascii) =~ "─"
    end
  end

  describe "the commit path of terminal keys" do
    test "Space writes a toggle; the answer applies it live, toasts and can be undone" do
      state = ready() |> open("terminal.show_diffs")
      generation = state.settings.generation

      {state, effects} = verb(state, :toggle)

      assert {:settings_cli_write, ^generation, ref, %{"show_diffs" => false},
              %{"show_diffs" => :absent}} = write = cli_write(effects)

      assert words(row(state, "terminal.show_diffs").value) == "off"

      assert Enum.any?(
               effects,
               &match?({:start_timer, _, 300, {:settings, {:saving, _, ^ref}}}, &1)
             )

      saving = act!(state, {:settings, {:saving, generation, ref}})
      assert words(row(saving, "terminal.show_diffs").tag) == "saving…"
      assert :pending in row(saving, "terminal.show_diffs").marks

      {state, _} = answer(state, write)
      assert state.show_diffs == false
      assert state.prefs["show_diffs"] == false
      assert state.settings.writes == %{}
      assert state.settings.status.text == "Show diffs → off"
      assert [%{label: "Show diffs"}] = state.settings_history.past

      {state, effects} = verb(state, :undo)

      assert {:settings_cli_write, _, _, %{"show_diffs" => :remove}, %{"show_diffs" => false}} =
               undo = cli_write(effects)

      {state, _} = answer(state, undo)
      assert state.show_diffs == true
      assert state.settings.status.text =~ "Undid: Show diffs"
      assert state.settings_history.past == []
      assert [_] = state.settings_history.future
    end

    test "a second value while one is in flight is queued and sent after the first answers" do
      state = ready() |> open("terminal.panel")
      {state, effects} = verb(state, :right)
      first = cli_write(effects)
      assert {:settings_cli_write, _, _, %{"panel" => "compact"}, %{"panel" => :absent}} = first

      {state, effects} = verb(state, :right)
      assert cli_write(effects) == nil
      assert words(row(state, "terminal.panel").value) =~ "idden"

      {_state, effects} = answer(state, first)

      assert {:settings_cli_write, _, _, %{"panel" => "hidden"}, %{"panel" => "compact"}} =
               cli_write(effects)
    end

    test "a conflict keeps mine and theirs; Enter re-sends mine against theirs; Esc takes theirs" do
      state = ready() |> open("terminal.panel")
      {state, effects} = verb(state, :right)
      write = cli_write(effects)

      {state, _} = answer(state, write, {:conflict, %{"panel" => "hidden"}})
      row = row(state, "terminal.panel")
      assert :conflict in row.marks
      assert Enum.any?(row.lines, &(words(&1) =~ "changed while you edited"))
      assert state.settings_history.past == []

      {_resent, effects} = verb(state, :enter)

      assert {:settings_cli_write, _, _, %{"panel" => "compact"}, %{"panel" => "hidden"}} =
               cli_write(effects)

      taken = verb!(state, :back)
      assert taken.settings.conflicts == %{}
      assert taken.settings != nil
    end

    test "a rejected value comes back with the message under the row and on the status" do
      state = ready() |> open("terminal.panel")
      {state, effects} = verb(state, :right)
      write = cli_write(effects)

      {state, _} = answer(state, write, {:error, :invalid, %{"panel" => "is invalid"}})
      row = row(state, "terminal.panel")
      assert :invalid in row.marks
      assert Enum.any?(row.lines, &(words(&1) == "✗ is invalid"))
      assert state.settings.status.text == "Couldn't save: is invalid"
      assert words(row.value) =~ "ull"
    end

    test "a number steps in place and writes once, 600 ms after the last step" do
      state = ready() |> open("terminal.composer_rows")
      {state, effects} = verb(state, :right)
      assert cli_write(effects) == nil
      assert [{:start_timer, timer, 600, {:settings, {:settle, _, timer}}}] = effects
      assert words(row(state, "terminal.composer_rows").value) == "4"

      {state, effects} = verb(state, :right)
      assert {:cancel_timer, ^timer} = hd(effects)
      [{:start_timer, second, 600, _}] = tl(effects)

      {state, effects} = act(state, {:settings, {:settle, state.settings.generation, second}})

      assert {:settings_cli_write, _, _, %{"composer_rows" => 5}, _} = write = cli_write(effects)
      {state, _} = answer(state, write)
      assert state.composer_height == 5
    end

    test "moving off a stepped number writes it at once" do
      state = ready() |> open("terminal.composer_rows")
      state = verb!(state, :right)
      {_state, effects} = verb(state, :down)
      assert {:settings_cli_write, _, _, %{"composer_rows" => 4}, _} = cli_write(effects)
    end

    test "Enter opens a text editor; typing and Enter write it; Esc puts it back" do
      state = ready() |> open("terminal.hint_letters")
      state = verb!(state, :enter)
      assert state.settings.mode == :editing
      assert SwarmCodeCLI.UI.Settings.context(state.settings) == :settings_edit

      state = verb!(state, :clear_line)
      state = Enum.reduce(String.graphemes("sfgh"), state, &press!(&2, letter(&1)))
      assert screen(state) =~ "sfgh"

      # The entry's own check refuses it and the editor stays open with the words.
      {state, effects} = press(state, Input.key(:enter))
      assert state.settings.mode == :editing
      assert cli_write(effects) == nil
      assert screen(state) =~ "use at least 8 letters"

      state = Enum.reduce(String.graphemes("jklwe"), state, &press!(&2, letter(&1)))
      {state, effects} = press(state, Input.key(:enter))
      assert state.settings.mode == :browse
      assert {:settings_cli_write, _, _, %{"hint_letters" => "sfghjklwe"}, _} = cli_write(effects)

      cancelled = state |> verb!(:enter) |> press!(letter("z")) |> press!(Input.key(:escape))
      assert cancelled.settings.mode == :browse
      assert cancelled.settings != nil
    end

    test "r resets a terminal key by removing it from cli.json" do
      state = %{ready() | prefs: %{"panel" => "compact"}} |> open("terminal.panel")
      {state, effects} = verb(state, :reset)

      assert {:settings_cli_write, _, _, %{"panel" => :remove}, %{"panel" => "compact"}} =
               write = cli_write(effects)

      {state, _} = answer(state, write)
      assert state.panel_mode == :full
      assert state.settings.status.text == "Side panel back to full"
    end

    test "a letter the row has no use for says so" do
      state = ready() |> open("terminal.panel") |> verb!(:fetch)
      assert state.settings.status.text == "f does nothing on this row"
    end
  end

  test "Rows.applies_words names every applies value" do
    for applies <- [:at_once, :next_turn, :next_launch, :new_clients, :restart],
        do: assert(is_binary(Rows.applies_words(applies)))
  end

  defp resize(state, columns, rows),
    do: act!(state, {:resize, %SwarmCodeCLI.UI.Size{columns: columns, rows: rows}})

  defp ascii(state),
    do: %{state | capabilities: %{state.capabilities | ascii?: true, glyph_tier: :ascii}}

  test "the layer never shows raw terms" do
    state = ready() |> act!({:settings_open, {:section, :appearance}})
    refute screen(state) =~ "%{"
    assert %Layer{} = state.settings
  end
end
