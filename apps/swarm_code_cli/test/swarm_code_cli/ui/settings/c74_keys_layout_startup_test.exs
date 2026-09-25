defmodule SwarmCodeCLI.UI.Settings.C74KeysLayoutStartupTest do
  @moduledoc "cli74 U3-10: Layout & transcript, Keys & input (+ Key bindings), Session & startup."
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.C74U3Helpers

  alias SwarmCodeCLI.UI.Keymap.Overrides
  alias SwarmCodeCLI.UI.Settings.{Confirm, Layer, Nav, Page, Picker, Sections}
  alias SwarmCodeCLI.UI.Settings.Editors.Text
  alias SwarmCodeCLI.UI.Settings.Sections.{KeysInput, SessionStartup}

  defp line_words(row), do: Enum.map_join(row.lines, " / ", &words/1)
  defp find(rows, id), do: Enum.find(rows, &(&1.id == id))

  defp bindings_ctx(keys \\ %{}) do
    {state, _fake} = opened(:keys)
    ctx = Nav.ctx(state)

    %{
      ctx
      | prefs: Map.put(ctx.prefs || %{}, "keys", keys),
        overrides: Overrides.compile(keys),
        page: %Page{section: :keys, sub: {:key_bindings, nil}}
    }
  end

  describe "Layout & transcript" do
    test "every §2.15 row applies at once, with the panel and diff hints" do
      {state, _fake} = opened(:layout)

      for key <- ~w(terminal.panel terminal.composer_rows terminal.inspector_width
                    terminal.show_diffs terminal.notice_seconds terminal.diff_lines) do
        assert key_row(state, key), key
      end

      assert line_words(key_row(state, "terminal.panel")) =~ "Ctrl-B cycles it"
      assert words(key_row(state, "terminal.diff_lines")) == "12"
    end
  end

  describe "Keys & input" do
    test "Lines per notch is disabled while wheel scrolling is off" do
      {state, _fake} = opened(:keys)
      assert key_row(state, "terminal.wheel_lines").state != :disabled

      ctx = %{Nav.ctx(state) | prefs: Map.put(state.prefs || %{}, "mouse", false)}
      row = :keys |> Sections.rows(ctx) |> find("key:terminal.wheel_lines")
      assert row.state == :disabled
      assert line_words(row) =~ "only when Wheel scrolling is on"
    end

    test "hint letters refuse with the registry's words" do
      {state, _fake} = opened(:keys)
      {Text, opts} = key_row(state, "terminal.hint_letters").editor

      assert {:error, "only lowercase letters a–z"} = Text.check(opts, "ABCDEFGH")
      assert {:error, "each letter once"} = Text.check(opts, "ssfghjkl")
      assert {:error, "use at least 8 letters"} = Text.check(opts, "sfgh")

      assert {:error, "y a d n q answer approvals or close; they cannot be hint letters"} =
               Text.check(opts, "sfghjkly")
    end

    test "Enter on Key bindings opens the sub-page" do
      {state, _fake} = opened(:keys)
      assert words(key_row(state, "terminal.keys")) =~ "actions"
      {state, _effects} = press(state, "key:terminal.keys", :enter)
      assert %Page{sub: {:key_bindings, nil}} = Layer.page(state.settings)
      assert KeysInput.title(Nav.ctx(state)) == "Keys & input › Key bindings"
      assert row(state, "bind:context")
    end
  end

  describe "Key bindings" do
    test "the sketch: context row, groups, keys, contexts and where they come from" do
      ctx = bindings_ctx(%{"run_palette" => ["F7", "F8"]})
      rows = Sections.sub_rows(:keys, ctx, {:key_bindings, nil})

      assert %{label: "Context"} = picker = hd(rows)
      assert words(picker) == "all ▾"
      assert words(picker.tag) == "/ filter or a key (/ctrl-j)"

      palette = find(rows, "bind:command_palette")
      assert all_words(palette) =~ "Ctrl-P"
      assert words(palette.tag) == "· default"

      diffs = find(rows, "bind:run_palette")
      assert words(diffs) == "F7, F8"
      assert words(diffs.tag) == "· changed"
      assert :changed in diffs.marks

      fixed = Enum.find(rows, &(words(&1.tag) == "fixed"))
      assert fixed.state == :readonly
      assert fixed.keys == []
      assert find(rows, "act:reset_bindings")
      assert Enum.any?(rows, &(all_words(&1) =~ "swarmcode config reset terminal.keys"))
    end

    test "/ctrl-j lists what Ctrl-J does; words match labels" do
      ctx = bindings_ctx()
      rows = Sections.sub_rows(:keys, ctx, {:key_bindings, nil})

      assert ["bind:composer_newline"] =
               ctx |> KeysInput.filter(rows, "/ctrl-j") |> Enum.map(& &1.id)

      assert ctx
             |> KeysInput.filter(rows, "palette")
             |> Enum.any?(&(&1.id == "bind:command_palette"))
    end

    test "the context picker narrows the page" do
      ctx = bindings_ctx()
      picker = ctx |> then(&Sections.sub_rows(:keys, &1, {:key_bindings, nil})) |> hd()

      assert [{:picker, %Picker{on_pick: {:section, :keys, :context}, options: options}}] =
               Sections.act(:keys, ctx, picker, :open_row)

      assert Enum.any?(options, &(&1.value == :composer))

      assert [:back, {:open, %Page{sub: {:key_bindings, :composer}}}] =
               Sections.picked(:keys, ctx, :context, :composer)

      narrowed = Sections.sub_rows(:keys, ctx, {:key_bindings, :composer})
      assert find(narrowed, "bind:composer_newline")
      assert words(hd(narrowed)) == "composer ▾"
    end

    test "+ adds, x removes one of several, X unbinds (asks), r resets one" do
      ctx = bindings_ctx(%{"run_palette" => ["F7", "F8"]})
      rows = Sections.sub_rows(:keys, ctx, {:key_bindings, nil})
      diffs = find(rows, "bind:run_palette")

      assert [{:edit, "bind:run_palette", %{add?: true}}] =
               Sections.act(:keys, ctx, diffs, :add_key)

      assert [{:patch, "terminal.keys", %{"run_palette" => ["F7"]}}] =
               Sections.act(:keys, ctx, diffs, :delete)

      assert [{:confirm, %Confirm{title: "Unbind " <> _}, then: then}] =
               Sections.act(:keys, ctx, diffs, :remove_all)

      assert then == [{:patch, "terminal.keys", %{"run_palette" => []}}]
      assert [{:patch, "terminal.keys", %{}}] = Sections.act(:keys, ctx, diffs, :reset)
    end

    test "Reset every key binding asks first, naming the count" do
      ctx = bindings_ctx(%{"run_palette" => ["F6"], "command_palette" => ["Ctrl-K"]})

      reset =
        ctx
        |> then(&Sections.sub_rows(:keys, &1, {:key_bindings, nil}))
        |> find("act:reset_bindings")

      assert [
               {:confirm, %Confirm{title: "Reset 2 key bindings?"},
                then: [{:reset, ["terminal.keys"]}]}
             ] =
               Sections.act(:keys, ctx, reset, :open_row)

      none = bindings_ctx()
      assert [{:toast, _, :info}] = Sections.act(:keys, none, reset, :open_row)
    end
  end

  describe "Session & startup" do
    test "the launch rows and this launch's facts" do
      {state, _fake} = opened(:startup)
      assert words(key_row(state, "terminal.startup_conversation")) =~ "latest"
      assert key_row(state, "terminal.companion")

      ctx = %{
        Nav.ctx(state)
        | launch_facts: %{project_root: "/Users/dev/ailogic", flags: %{"--new" => ""}}
      }

      rows = Sections.rows(:startup, ctx)
      root = find(rows, "key:terminal.project_root")
      assert words(root) == "/Users/dev/ailogic"
      assert words(find(rows, "key:terminal.launch_flags")) == "--new"
      assert [{:copy, "/Users/dev/ailogic"}, _] = Sections.act(:startup, ctx, root, :copy)

      assert [{:open_folder, "/Users/dev/ailogic"}] =
               Sections.act(:startup, ctx, root, :open_related)
    end

    test "flag words" do
      assert SessionStartup.flag_words(nil) == "none"

      assert SessionStartup.flag_words(%{"--resume" => "4f2a", "--new" => ""}) ==
               "--new --resume 4f2a"
    end
  end
end
