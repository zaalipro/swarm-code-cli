defmodule SwarmCodeCLI.UI.Home.OrbitProjectorTest do
  @moduledoc """
  orbit U5: Home at 120x36 (D-main-dark). The golden is the screen as text; the
  other tests pin what the golden cannot show: roles, backgrounds and the data
  the screen is built from.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.OrbitHelpers, only: [fixture: 0, fixture: 2, assert_golden: 2]

  alias SwarmCodeCLI.Cli020EHelpers, as: H
  alias SwarmCodeCLI.UI.{Projector, Theme}
  alias SwarmCodeCLI.UI.DataSource.DTO
  alias SwarmCodeCLI.UI.Home
  alias SwarmCodeCLI.UI.Home.Mark

  defp rows(state), do: H.screen(state)

  defp foreground(state, role), do: Theme.style(role, state.capabilities).foreground.value

  describe "120x36" do
    test "the screen is the golden" do
      assert_golden("main_120x36.txt", H.screen_text(fixture()))
    end

    test "Home covers the screen: one region, first, and a full set of rows" do
      state = fixture()
      {scene, _table} = Projector.project(state)
      assert [%{id: "home", role: :main} = region] = scene.regions
      assert region.rect.width == 120 and region.rect.height == 36
      assert length(region.blocks) == 36
      assert length(rows(state)) == 36
    end

    test "row 0 holds the project, the home tab and the version" do
      [first | _] = rows(fixture())
      assert first =~ "swarm-code-cli"
      assert first =~ "▌ home"
      assert String.ends_with?(first, "ncode 0.2.2")
    end

    test "the legend names the ring, the bars and the dot" do
      rows = rows(fixture())
      assert Enum.at(rows, 19) =~ "ring ▰▰▰▰▰▰▱▱▱▱  $38.40 of $60"
      assert Enum.at(rows, 19) =~ "○ nightly deps audit · scheduled · in 14 min"
      assert Enum.at(rows, 20) =~ "bars 3 live · swarm research chat"
      assert Enum.at(rows, 21) =~ "dot  1 needs you · Ctrl-N go"
    end

    test "each orbit is named over its top and counted under its bottom" do
      rows = rows(fixture())
      names = Enum.at(rows, 1)

      positions =
        for name <- ["swarm-code-cli", "swarm-code", "llmotions", "ailogic"] do
          {pos, _} = :binary.match(names, name)
          pos
        end

      assert positions == Enum.sort(positions)
      assert Enum.at(rows, 18) =~ "9 · 1 live"
      assert Enum.at(rows, 18) =~ "3 · 1 live"
    end

    test "the age ticks are at the right edge on rows 2, 8, 12, 15 and 17" do
      rows = rows(fixture())

      for {row, label} <- [{2, "now"}, {8, "1 h"}, {12, "1 d"}, {15, "7 d"}, {17, "30 d"}] do
        assert String.ends_with?(Enum.at(rows, row), label), "row #{row} ends with #{label}"
      end
    end

    test "rows 24 to 32 hold the nine titles in order" do
      rows = rows(fixture())

      titles = [
        "rate-limit chip wiring",
        "MCP fixture isolation",
        "paste width regression",
        "reaper ownership for kill_async",
        "workflow host file reads",
        "dashboard launch brief",
        "settings strata hues",
        "history search ranking",
        "side panel lane colours"
      ]

      for {title, index} <- Enum.with_index(titles) do
        row = Enum.at(rows, 24 + index)
        assert row =~ Integer.to_string(index + 1)
        assert row =~ title
      end

      assert Enum.at(rows, 24) =~ "▌ 1"
      assert Enum.at(rows, 24) =~ "approval waiting"
      assert Enum.at(rows, 25) =~ "swarm · 60%"
      assert Enum.at(rows, 27) =~ "unread"
      assert Enum.at(rows, 24) =~ "2 min ago"
      assert Enum.at(rows, 29) =~ "26 h ago"
      assert Enum.at(rows, 32) =~ "6 d ago"
    end

    test "the preview shows the selected conversation" do
      rows = rows(fixture())
      assert Enum.at(rows, 23) =~ "rate-limit chip wiring"
      assert Enum.at(rows, 24) =~ "4 runs · started 3 d ago · 2 min ago"
      assert Enum.at(rows, 26) =~ "last prompt"
      assert Enum.at(rows, 27) =~ "wire the rate-limit chip into the"
      assert Enum.at(rows, 28) =~ "status row and the side-panel strip"
      assert Enum.at(rows, 30) =~ "! 1 approval waiting"
      assert Enum.at(rows, 32) =~ "Enter open   Ctrl-N go to the approval"
    end

    test "the composer, its hint and the status row" do
      rows = rows(fixture())
      assert Enum.at(rows, 33) =~ "› Type to start a new conversation, or / for commands…"

      assert Enum.at(rows, 34) =~
               "Enter new conversation in swarm-code-cli   Esc continue the latest: rate-limit chip wiring"

      status = Enum.at(rows, 35)
      assert status =~ "auto · opus 5.5 · xhigh · ⎇ main +3 · 1 waiting"
      assert status =~ "Tab map"
      assert status =~ "Alt-1…9 open"
      assert status =~ "F1 keys"
      refute status =~ "ctx"
      refute status =~ "$"
    end

    test "the dot is a warning, the ring is accent up to 64 % and ghost after" do
      state = fixture()
      plan = H.plan(state)
      {row, col, _, _} = Enum.find(Mark.elements({32, 16}), &match?({_, _, _, :dot}, &1))
      assert H.cell_style(plan, 4 + col, 2 + row).foreground == foreground(state, :warning)

      ring =
        for {r, c, _, {:ring, f}} <- Mark.elements({32, 16}), do: {r, c, f}

      accent = foreground(state, :accent)
      ghost = foreground(state, :text_ghost)

      for {r, c, f} <- ring do
        style = H.cell_style(plan, 4 + c, 2 + r)

        if f <= 0.64,
          do: assert(style.foreground == accent, "ring cell f=#{f} lit"),
          else: assert(style.foreground == ghost, "ring cell f=#{f} ghost")
      end
    end

    test "bars: swarm 60 %, research 25 %, chat whole, two empty slots" do
      state = fixture()
      plan = H.plan(state)

      by_bar =
        for {r, c, _, {:bar, k, _}} <- Mark.elements({32, 16}), reduce: %{} do
          acc ->
            Map.update(
              acc,
              k,
              [H.cell_style(plan, 4 + c, 2 + r).foreground],
              &[H.cell_style(plan, 4 + c, 2 + r).foreground | &1]
            )
        end

      assert foreground(state, :run_swarm) in by_bar[0]
      assert foreground(state, :text_faint) in by_bar[0]
      assert foreground(state, :run_research) in by_bar[1]
      assert Enum.uniq(by_bar[2]) == [foreground(state, :text_primary)]
      assert Enum.uniq(by_bar[3]) == [foreground(state, :disabled)]
      assert Enum.uniq(by_bar[4]) == [foreground(state, :disabled)]
    end

    test "the selected row sits on the hover surface while the composer has focus" do
      state = fixture()
      plan = H.plan(state)
      hover = Theme.style(:hover, state.capabilities).background.value
      assert H.cell_style(plan, 20, 24).background == hover
      assert H.cell_style(plan, 20, 25).background == nil
      selected = fixture({120, 36}, home: [focus: :list])
      selection = Theme.style(:selection, selected.capabilities).background.value
      assert H.cell_style(H.plan(selected), 20, 24).background == selection
    end

    test "the cursor is in the composer, at the end of the draft" do
      state = fixture()
      {scene, _} = Projector.project(state)
      assert %{x: 3, y: 33, shape: :bar} = scene.cursor
    end
  end

  describe "before the overview answers" do
    test "the legend shows ellipses, the ring is a ghost and only this project is named" do
      state = fixture({120, 36}, overview: nil)
      rows = rows(state)
      assert Enum.at(rows, 19) =~ "ring ▱▱▱▱▱▱▱▱▱▱  …"
      assert Enum.at(rows, 20) =~ "bars …"
      assert Enum.at(rows, 21) =~ "dot  …"
      assert Enum.at(rows, 1) =~ "swarm-code-cli"
      refute Enum.at(rows, 1) =~ "llmotions"
      refute Enum.at(rows, 18) =~ "live"

      plan = H.plan(state)
      ghost = foreground(state, :text_ghost)

      for {r, c, _, {kind, _}} <- Mark.elements({32, 16}), kind in [:ring, :ring_cap] do
        assert H.cell_style(plan, 4 + c, 2 + r).foreground == ghost
      end

      for {r, c, _, {:bar, _, _}} <- Mark.elements({32, 16}) do
        assert H.cell_style(plan, 4 + c, 2 + r).foreground == foreground(state, :disabled)
      end
    end

    test "the resume list does not wait for it" do
      rows = rows(fixture({120, 36}, overview: nil))
      assert Enum.at(rows, 24) =~ "rate-limit chip wiring"
      assert Enum.at(rows, 32) =~ "side panel lane colours"
    end

    test "an error answer reads like no answer" do
      error = %DTO.HomeOverview{state: :error}
      rows = rows(fixture({120, 36}, overview: error))
      assert Enum.at(rows, 19) =~ "…"
      assert Enum.at(rows, 24) =~ "rate-limit chip wiring"
    end
  end

  describe "the data it is built from" do
    test "the money words" do
      assert Home.View.money(38.4) == "$38.40"
      assert Home.View.money(60.0) == "$60"
      assert Home.View.money(60.5) == "$60.50"
      assert Home.View.money(0.07) == "$0.07"
    end

    test "without a budget the ring falls back to the tightest provider window" do
      state = fixture()
      overview = %{state.home.overview | month: %DTO.HomeMonth{spend_usd: 12.0, budget_usd: nil}}

      shell = %DTO.ShellSnapshot{
        rate_limits: [
          %DTO.RateLimit{
            provider_id: "p1",
            provider: "Anthropic",
            scope: "5 h",
            used_percent: 41.0
          }
        ]
      }

      state = put_in(state.read_model.snapshots[:shell], shell)
      state = %{state | home: %{state.home | overview: overview}}
      assert %{source: :limit, words: "Anthropic 5 h 41%"} = Home.View.ring(state)
      assert Enum.at(rows(state), 19) =~ "Anthropic 5 h 41%"
    end

    test "with neither a budget nor a limit the ring says so" do
      state = fixture()
      overview = %{state.home.overview | month: nil}
      state = %{state | home: %{state.home | overview: overview}}
      assert %{frac: nil, words: "no budget set"} = Home.View.ring(state)
      assert Enum.at(rows(state), 19) =~ "no budget set"
    end

    test "nothing waiting and nothing running read as such" do
      state = fixture()
      overview = %{state.home.overview | waiting_total: 0, live_runs: [], live_overflow: 0}
      state = %{state | home: %{state.home | overview: overview}}
      rows = rows(state)
      assert Enum.at(rows, 20) =~ "bars nothing running"
      assert Enum.at(rows, 21) =~ "dot  nothing waits for you"
    end

    test "live runs beyond five count as +N" do
      state = fixture()
      overview = %{state.home.overview | live_overflow: 2}
      state = %{state | home: %{state.home | overview: overview}}
      assert Enum.at(rows(state), 20) =~ "bars 5 live · swarm research chat +2"
    end

    test "a task of another project names it" do
      state = fixture()

      task = %{
        state.home.overview.next_scheduled
        | project_id: "ffffffff-0000-4000-8000-000000000009",
          project_name: "ailogic"
      }

      overview = %{state.home.overview | next_scheduled: task}
      state = %{state | home: %{state.home | overview: overview}}
      assert Enum.at(rows(state), 19) =~ "○ nightly deps audit · ailogic · in 14 min"
    end

    test "the selection moves the window of the list" do
      state = fixture({120, 36}, home: [selected: 8])
      rows = rows(state)
      assert Enum.at(rows, 32) =~ "▌ 9"
      assert Enum.at(rows, 32) =~ "side panel lane colours"
      assert Enum.at(rows, 23) =~ "side panel lane colours"
    end
  end

  describe "the draft" do
    test "a typed draft replaces the placeholder and the caret follows it" do
      state = fixture()

      {:ok, editor} =
        SwarmCodeCLI.UI.Editor.apply(SwarmCodeCLI.UI.Editor.new(), {:paste, "fix the flaky test"})

      draft = SwarmCodeCLI.UI.Drafts.fetch(state.drafts, {"fixture-epoch", :home})

      state = %{
        state
        | drafts: SwarmCodeCLI.UI.Drafts.put(state.drafts, %{draft | editor: editor})
      }

      rows = rows(state)
      assert Enum.at(rows, 33) =~ "› fix the flaky test"
      refute Enum.at(rows, 33) =~ "Type to start"
      {scene, _} = Projector.project(state)
      assert %{x: 21, y: 33} = scene.cursor
    end

    test "a local command in the draft says what Enter runs" do
      state = fixture()

      {:ok, editor} =
        SwarmCodeCLI.UI.Editor.apply(SwarmCodeCLI.UI.Editor.new(), {:paste, "/trust"})

      draft = SwarmCodeCLI.UI.Drafts.fetch(state.drafts, {"fixture-epoch", :home})

      state = %{
        state
        | drafts: SwarmCodeCLI.UI.Drafts.put(state.drafts, %{draft | editor: editor})
      }

      assert Enum.at(rows(state), 34) =~ "Enter run /trust"
    end

    test "on re-entry the hint says back to" do
      state = fixture({120, 36}, home: [entered: :key])
      assert Enum.at(rows(state), 34) =~ "Esc back to: rate-limit chip wiring"
    end
  end
end
