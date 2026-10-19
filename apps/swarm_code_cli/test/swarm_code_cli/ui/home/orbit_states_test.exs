defmodule SwarmCodeCLI.UI.Home.OrbitStatesTest do
  @moduledoc """
  orbit U7: Home's first run (D-first-run) and the project map focused
  (D-interact), and the command Home copies for a conversation of another project.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.OrbitHelpers, only: [fixture: 2, assert_golden: 2]

  alias SwarmCodeCLI.Cli020EHelpers, as: H
  alias SwarmCodeCLI.UI.{Projector, Theme}
  alias SwarmCodeCLI.UI.Home.{CopyCommand, View}

  defp rows(state), do: H.screen(state)
  defp first_run(size \\ {120, 36}, opts \\ []), do: fixture(size, [scene: :first_run] ++ opts)
  defp interact(size \\ {120, 36}, opts \\ []), do: fixture(size, [scene: :interact] ++ opts)

  describe "first run" do
    test "the screen is the golden" do
      assert_golden("first_run_120x36.txt", H.screen_text(first_run()))
    end

    test "the empty conversation the project was given is not a row" do
      state = first_run()
      assert [%{title: "New conversation"}] = state.conversations.items
      assert SwarmCodeCLI.UI.Home.rows(state) == []
      assert View.first_run?(state)
      refute Enum.any?(rows(state), &(&1 =~ "New conversation"))
      refute Enum.any?(rows(state), &(&1 =~ "resume in"))
    end

    test "the welcome card stands where the list would" do
      rows = rows(first_run())
      assert Enum.at(rows, 23) =~ "✳ Ready to build"
      assert Enum.at(rows, 24) =~ "Ask for a change, inspect the project, or choose a mode."
      assert Enum.at(rows, 26) =~ "Enter    send"
      assert Enum.at(rows, 27) =~ "/        commands"
      assert Enum.at(rows, 28) =~ "Ctrl-P   workflows, research, memory, settings"
    end

    test "an untrusted project says what trust and approval do, from the workspace" do
      rows = rows(first_run())
      assert Enum.at(rows, 30) =~ "! untrusted · /trust reads AGENTS.md and allows edits"
      assert Enum.at(rows, 31) =~ "/approval auto lets it edit; read-only now"
      assert Enum.at(rows, 35) =~ "read-only · untrusted"
      assert Enum.at(rows, 34) =~ "/trust lets it edit files"
    end

    test "a trusted project shows neither line" do
      state = first_run({120, 36}, workspace: [trusted: true, approval_mode: :auto])
      rows = rows(state)
      refute Enum.any?(rows, &(&1 =~ "untrusted"))
      refute Enum.any?(rows, &(&1 =~ "/approval"))
      refute Enum.at(rows, 34) =~ "/trust"
      assert Enum.at(rows, 34) =~ "Enter first conversation here   F2 settings"
    end

    test "the approval line follows the snapshot, not the screen" do
      state = first_run({120, 36}, workspace: [trusted: false, approval_mode: :auto])
      rows = rows(state)
      assert Enum.at(rows, 30) =~ "! untrusted"
      refute Enum.any?(rows, &(&1 =~ "/approval"))
    end

    test "recently, elsewhere lists the newest conversations of the other projects" do
      rows = rows(first_run())
      assert Enum.at(rows, 23) =~ "recently, elsewhere"
      assert Enum.at(rows, 23) =~ "Alt-1…5 copy"
      assert Enum.at(rows, 24) =~ ~r/1  ● rate-limit chip wiring\s+swarm-code-cli\s+2 min$/u
      assert Enum.at(rows, 26) =~ ~r/3  ● competitor pricing scan\s+llmotions\s+12 min$/u
      assert Enum.at(rows, 27) =~ ~r/4  ● pass 76 review notes\s+swarm-code\s+40 min$/u
      assert Enum.at(rows, 28) =~ ~r/5  ● paste width regression\s+swarm-code-cli\s+52 min$/u
      assert Enum.at(rows, 30) =~ "Another project opens in its own tab: Enter copies"
      assert Enum.at(rows, 31) =~ "the command, ncode ~/dev/swarm-code-cli -r 0b6f5b3e"
    end

    test "the composer starts the first conversation here" do
      rows = rows(first_run())

      assert Enum.at(rows, 33) =~
               "› Type to start the first conversation in ailogic, or / for commands…"

      assert Enum.at(rows, 34) =~
               "Enter first conversation here   /trust lets it edit files   F2 settings"
    end

    test "the legend, the ring and the title belong to the new project" do
      rows = rows(first_run())
      assert Enum.at(rows, 0) =~ "ailogic"
      assert Enum.at(rows, 18) =~ "new"
      assert Enum.at(rows, 19) =~ "ring ▰▰▱▱▱▱▱▱▱▱  $12.10 of $60"
      assert Enum.at(rows, 20) =~ "bars 1 live · research in llmotions"
      assert Enum.at(rows, 21) =~ "dot  nothing waits for you"
      refute Enum.at(rows, 19) =~ "nightly"
    end

    test "the status row does not advertise opening rows that are not there" do
      status = Enum.at(rows(first_run()), 35)
      assert status =~ "Tab list"
      assert status =~ "F1 keys"
      refute status =~ "Alt-1"
    end

    test "narrow classes keep the welcome card without the elsewhere block" do
      for size <- [{110, 32}, {80, 24}, {60, 16}] do
        rows = rows(first_run(size))
        assert Enum.any?(rows, &(&1 =~ "Ready to build")), "#{inspect(size)} welcomes"
        refute Enum.any?(rows, &(&1 =~ "recently, elsewhere"))
      end
    end

    test "the welcome follows the composer's mode" do
      state = first_run({120, 36}, workspace: [mode: :plan])
      assert Enum.at(rows(state), 23) =~ "✳ Ready to plan"
    end
  end

  describe "the project map focused" do
    test "the screen is the golden" do
      assert_golden("interact_120x36.txt", H.screen_text(interact()))
    end

    test "the selected bead is named beside it on the selection fill" do
      state = interact()
      {x, y} = H.locate(state, "competitor pricing scan")
      plan = H.plan(state)
      selection = Theme.style(:selection, state.capabilities).background.value
      assert y < 22, "the label is on the orbit, not in the list"
      assert H.cell_style(plan, x, y).background == selection
      assert H.cell_style(plan, x + 5, y).background == selection
      assert Enum.at(rows(state), y) =~ "competitor pricing scan  12 min"
    end

    test "the list shows the selected project's conversations and where they open" do
      rows = rows(interact())
      assert Enum.at(rows, 23) =~ "llmotions · opens in its own tab"
      assert Enum.at(rows, 23) =~ "↑↓ star"
      assert Enum.at(rows, 24) =~ "▌ 1  ● competitor pricing scan"
      assert Enum.at(rows, 24) =~ "research · 25%"
      assert Enum.at(rows, 25) =~ "2  ○ landing hero copy"
      assert Enum.at(rows, 26) =~ "3  ○ pricing table refactor"
      refute Enum.any?(rows, &(&1 =~ "runs"))
      refute Enum.any?(rows, &(&1 =~ "MCP fixture isolation"))
    end

    test "the selected row is on the selection fill" do
      state = interact()
      selection = Theme.style(:selection, state.capabilities).background.value
      assert H.cell_style(H.plan(state), 20, 24).background == selection
    end

    test "the preview follows the bead and ends with the command to copy" do
      rows = rows(interact())
      assert Enum.at(rows, 23) =~ "competitor pricing scan"
      assert Enum.at(rows, 24) =~ "llmotions · ~/dev/llmotions"
      assert Enum.at(rows, 25) =~ "● research · live · 25%"
      assert Enum.at(rows, 26) =~ "started 14 min ago"
      assert Enum.at(rows, 31) =~ "Enter copies the command to open it"
      assert Enum.at(rows, 32) =~ "ncode ~/dev/llmotions -r 7c1e9a2b"
      refute Enum.any?(rows, &(&1 =~ "last prompt"))
    end

    test "the composer is unfocused and the hints are the map's" do
      state = interact()
      rows = rows(state)
      assert Enum.at(rows, 33) =~ "› Type to start a new conversation, or / for commands…"
      assert Enum.at(rows, 34) =~ "Esc back to the composer   Tab next: the composer"
      assert Enum.at(rows, 35) =~ "←→ orbit   ↑↓ star   Enter copy command   Esc back"
      {scene, _} = Projector.project(state)
      assert scene.cursor == nil
    end

    test "this project's own bead opens it instead of copying" do
      state = interact({120, 36}, home: [orbit: 0, bead: 1])
      rows = rows(state)
      assert Enum.at(rows, 23) =~ "resume in swarm-code-cli"
      assert Enum.at(rows, 25) =~ "▌ 2"
      assert Enum.at(rows, 35) =~ "Enter open"
      refute Enum.at(rows, 35) =~ "copy command"
    end

    test "the wide class keeps every other orbit's title" do
      state = interact({160, 44})
      orbit_area = state |> rows() |> Enum.slice(2, 20) |> Enum.join("\n")
      assert orbit_area =~ "rate-limit chip wiring"
      assert orbit_area =~ "pass 76 review notes"
      assert orbit_area =~ "fake provider script"
      assert orbit_area =~ "competitor pricing scan  12 min"
    end
  end

  describe "CopyCommand" do
    test "a path under the home folder is written with ~" do
      assert CopyCommand.command("/Users/dev/dev/llmotions", "7c1e9a2b-0000-4000", "/Users/dev") ==
               "ncode ~/dev/llmotions -r 7c1e9a2b"
    end

    test "a path outside it is written as it is" do
      assert CopyCommand.command("/srv/app/ncode", "abcdef0123456789", "/Users/dev") ==
               "ncode /srv/app/ncode -r abcdef01"
    end

    test "a path with a space is single-quoted, whole and absolute" do
      assert CopyCommand.command("/Users/dev/My Projects/x", "abcdef0123", "/Users/dev") ==
               "ncode '/Users/dev/My Projects/x' -r abcdef01"
    end

    test "a quote inside a path is closed, escaped and reopened" do
      assert CopyCommand.command("/tmp/it's", "abcdef0123", nil) ==
               "ncode '/tmp/it'\\''s' -r abcdef01"
    end

    test "shell metacharacters are quoted, not trusted" do
      assert CopyCommand.path("/tmp/a;rm -rf x", "/Users/dev") == "'/tmp/a;rm -rf x'"
      assert CopyCommand.path("/tmp/$(whoami)", "/Users/dev") == "'/tmp/$(whoami)'"
    end

    test "the home folder itself, a trailing slash and no home" do
      assert CopyCommand.path("/Users/dev", "/Users/dev") == "/Users/dev"
      assert CopyCommand.path("/Users/dev/p", "/Users/dev/") == "~/p"
      assert CopyCommand.path("/Users/dev/p", nil) == "/Users/dev/p"
      assert CopyCommand.path("/Users/dev/p", "") == "/Users/dev/p"
    end

    test "a sibling folder that merely starts with the home name is not under it" do
      assert CopyCommand.path("/Users/developer/p", "/Users/dev") == "/Users/developer/p"
    end

    test "the display path abbreviates the same way and never quotes" do
      assert CopyCommand.abbreviate("/Users/dev/My Projects/x", "/Users/dev") == "~/My Projects/x"
      assert CopyCommand.abbreviate("/srv/x", "/Users/dev") == "/srv/x"
    end

    test "the prefix is the first eight characters" do
      assert CopyCommand.prefix("7c1e9a2b-0000-4000-8000-000000000003") == "7c1e9a2b"
      assert CopyCommand.prefix("abc") == "abc"
      assert CopyCommand.prefix(nil) == ""
    end
  end
end
