defmodule SwarmCodeCLI.UI.Settings.C74SearchTest do
  @moduledoc """
  cli74 U1-12: the settings search (index, ranking, `@filters`, fuzzy,
  empty words, record items), the in-page filter of long lists (D37), the
  `:` command line, and the F2 scene.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers, only: [ready: 0, press!: 2, letter: 1]

  alias SwarmCodeCLI.UI.{Input, Projector, Reducer, SafeText, Size}
  alias SwarmCodeCLI.UI.Settings.{Ctx, Data, Layer, Nav, Page, Row, Search}

  defp act(state, action), do: Reducer.update(state, action)
  defp act!(state, action), do: elem(act(state, action), 0)
  defp typed(state, text), do: Enum.reduce(String.graphemes(text), state, &press!(&2, letter(&1)))

  defp screen(state) do
    {scene, _} = Projector.project(state)

    scene.regions
    |> Enum.flat_map(& &1.blocks)
    |> Enum.map_join("\n", fn block ->
      Enum.map_join(block.spans, "", &SafeText.value(&1.text))
    end)
  end

  defp ctx(data \\ %Data{}),
    do: %Ctx{data: data, prefs: %{"panel" => "compact"}, launch_facts: %{}}

  describe "ranking and filters" do
    test "an exact key ranks first, then label prefix, label word, key word, description" do
      index = Search.index(ctx())
      %{results: [{:exact_key, first} | _]} = Search.run(index, "terminal.panel")
      assert first.key == "terminal.panel"

      %{results: [{rank, top} | _]} = Search.run(index, "side panel")
      assert rank == :label_prefix
      assert top.key == "terminal.panel"

      ranks = Search.run(index, "timeout").results |> Enum.map(&elem(&1, 0))
      assert ranks == Enum.sort_by(ranks, &Enum.find_index(Search.ranks(), fn r -> r == &1 end))
    end

    test "@cli, @modified and @section narrow before words" do
      index = Search.index(ctx())
      cli = Search.run(index, "@cli").results
      assert cli != []

      assert Enum.all?(cli, fn {_, entry} ->
               entry.kind == :key and String.starts_with?(entry.key, "terminal.")
             end)

      modified = Search.run(index, "@modified").results |> Enum.map(&elem(&1, 1).key)
      assert modified == ["terminal.panel"]

      limits = Search.run(index, "@section:agents_limits").results

      assert limits != [] and
               Enum.all?(limits, fn {_, entry} -> entry.section == :agents_limits end)
    end

    test "words that match nothing fall back to a subsequence of labels and keys" do
      %{fuzzy?: true, results: [_ | _]} = Search.run(Search.index(ctx()), "sdpnl")
    end

    test "a provider's model finds the provider record" do
      page = %{
        items: [
          %{
            kind: "provider",
            id: "p1",
            fields: %{"name" => "DeepSeek", "models" => ["deepseek-v4-lite", "deepseek-v4-pro"]}
          }
        ],
        loaded_at: 1
      }

      data = %Data{records: %{{"providers", %{}} => page}}

      %{results: [{:label_prefix, hit} | _]} =
        Search.run(Search.index(ctx(data)), "deepseek-v4-lite")

      assert hit.target == {:record, "provider", "p1", {:model, "deepseek-v4-lite"}}
    end

    test "search over the whole index stays fast" do
      index = Search.index(ctx())
      big = Enum.take(Stream.cycle(index), Search.max_entries())
      # The best of five runs: the bound is the search's cost, not the
      # scheduler's while other tests run.
      micros =
        1..5
        |> Enum.map(fn _ -> elem(:timer.tc(fn -> Search.run(big, "limit command") end), 0) end)
        |> Enum.min()

      assert micros < 20_000, "#{micros} µs"
    end
  end

  describe "the search row" do
    test "typing shows grouped results as real rows; Enter edits one in place (F2)" do
      state =
        ready() |> act!({:resize, %Size{columns: 160, rows: 45}}) |> act!({:settings_open, nil})

      state = press!(state, letter("/"))
      assert state.settings.mode == :search
      state = typed(state, "side panel")

      text = screen(state)
      assert text =~ "Side panel"
      assert text =~ "results · Esc clears"

      state = press!(state, Input.key(:down))
      assert Nav.current(state).id == "key:terminal.panel"
      {state, effects} = act(state, {:settings, {:verb, :right}})

      assert Enum.any?(
               effects,
               &match?({:settings_cli_write, _, _, %{"panel" => "compact"}, _}, &1)
             )

      assert state.settings.search.query == "side panel"
    end

    test "g on a result goes to it in its section; Esc clears then leaves" do
      state =
        ready() |> act!({:settings_open, nil}) |> press!(letter("/")) |> typed("composer height")

      state = press!(state, Input.key(:down))
      state = press!(state, letter("g"))
      assert state.settings.mode == :browse
      assert Layer.section(state.settings) == :layout
      assert Nav.current(state).id == "key:terminal.composer_rows"

      state = ready() |> act!({:settings_open, nil}) |> press!(letter("/")) |> typed("zz")
      state = press!(state, Input.key(:escape))
      assert state.settings.search.query == ""
      state = press!(state, Input.key(:escape))
      assert state.settings.mode == :browse
    end

    test "nothing found says so with the closest keys and the hint" do
      state = ready() |> act!({:settings_open, nil}) |> press!(letter("/")) |> typed("xyzzy qqq")
      rows = Nav.rows(state)
      assert %Row{kind: :info} = hd(rows)
      assert screen(state) =~ "Nothing matches “xyzzy qqq”."
      assert screen(state) =~ "Try @modified, @env"
    end

    test "/settings @words opens straight into the search" do
      state = act!(ready(), {:settings_open, "@cli"})
      assert state.settings.mode == :search
      assert %{results: [_ | _]} = state.settings.search.found
    end
  end

  describe "the in-page filter (D37)" do
    test "/ on a list of more than 20 rows filters it in place; / on an empty filter opens the search" do
      state = ready() |> act!({:settings_open, {:section, :pricing}})
      layer = Layer.push(state.settings, %Page{section: :pricing, sub: "models"})
      state = %{state | settings: layer}

      # The filter as `/` opens it on a 312-row sub-page.
      state = %{
        state
        | settings: %{
            state.settings
            | filter: %{page: {:pricing, nil, "models"}, query: "", total: 312},
              mode: :search
          }
      }

      state = typed(state, "model-31")
      assert state.settings.filter.query == "model-31"
      assert screen(state) =~ "filter 312 rows"

      cleared = press!(state, Input.key(:escape))
      assert cleared.settings.filter.query == ""
      left = press!(cleared, Input.key(:escape))
      assert left.settings.filter == nil

      search =
        %{state | settings: %{state.settings | filter: %{state.settings.filter | query: ""}}}
        |> press!(letter("/"))

      assert search.settings.search != nil
    end
  end

  describe "the command line" do
    test ":set writes, :get tells, a bad value stays on the line with its message" do
      state = ready() |> act!({:settings_open, nil}) |> press!(letter(":"))
      assert state.settings.mode == :command_line
      state = typed(state, "set terminal.panel compact")
      {state, effects} = act(state, {:settings, {:verb, :enter}})

      assert Enum.any?(
               effects,
               &match?({:settings_cli_write, _, _, %{"panel" => "compact"}, _}, &1)
             )

      assert state.settings.mode == :browse

      bad = state |> press!(letter(":")) |> typed("set terminal.composer_rows 99")
      {bad, effects} = act(bad, {:settings, {:verb, :enter}})

      assert effects == [] or
               not Enum.any?(effects, &match?({:settings_cli_write, _, _, _, _}, &1))

      assert bad.settings.mode == :command_line
      assert bad.settings.command_line.error =~ "between"
      assert screen(bad) =~ "between"

      got =
        state
        |> press!(letter(":"))
        |> typed("get terminal.show_diffs")
        |> press!(Input.key(:enter))

      assert got.settings.status.text == "terminal.show_diffs = on"

      unknown = state |> press!(letter(":")) |> typed("set nope 1") |> press!(Input.key(:enter))
      assert unknown.settings.command_line.error == "not a setting: nope"
    end

    test ":goto moves to a section or a key; Tab completes a command and a key" do
      state =
        ready()
        |> act!({:settings_open, nil})
        |> press!(letter(":"))
        |> typed("goto storage")
        |> press!(Input.key(:enter))

      assert Layer.section(state.settings) == :storage

      state = state |> press!(letter(":")) |> typed("se")
      state = press!(state, Input.key(:tab))
      assert state.settings.command_line.text == "set "
    end
  end
end
