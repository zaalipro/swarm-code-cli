defmodule SwarmCodeCLI.UI.Settings.C74OverviewTest do
  @moduledoc """
  cli74 U1-16: the Overview page (F1) at 160×45 with Appendix A data from
  the service's fake store: the page column's text, the focus on the first
  attention item, Enter on an item, a glance line and `… N more`, the
  client's attention (AT13 cli.json, AT14 key overrides), *changed in this
  session*, the empty and loading words, and the strip on the search row.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers, only: [ready: 0]

  alias SwarmCode.Settings.{Entry, Registry}
  alias SwarmCodeCLI.UI.{Reducer, SafeText, Size}
  alias SwarmCodeCLI.UI.DataSource.{Delivery, Request}
  alias SwarmCodeCLI.UI.DataSource.Fake.Settings, as: FakeSettings
  alias SwarmCodeCLI.UI.Keymap.Overrides
  alias SwarmCodeCLI.UI.Projector.Settings, as: SettingsProjector
  alias SwarmCodeCLI.UI.Settings.{Grid, Layer, Nav, Rows, Sections, Undo}
  alias SwarmCodeCLI.UI.Settings.Sections.Overview

  defp act(state, action), do: Reducer.update(state, action)
  defp act!(state, action), do: elem(act(state, action), 0)

  defp sent(effects),
    do: for({kind, %Request{} = request} <- effects, kind in [:query, :command], do: request)

  # Answers every settings request from the fake store until none is left.
  defp serve({state, effects}, fake) do
    case sent(effects) do
      [] ->
        state

      requests ->
        {state, more, fake} =
          Enum.reduce(requests, {state, [], fake}, fn request, {acc, more, fake} ->
            {fake, body, _facts} =
              case request.kind do
                {:settings_query, _} -> FakeSettings.query(fake, request)
                {:settings_command, _} -> FakeSettings.command(fake, request)
              end

            {acc, next} = act(acc, {:data, delivery(request, body)})
            {acc, more ++ next, fake}
          end)

        serve({state, more}, fake)
    end
  end

  defp delivery(request, body),
    do: %Delivery{
      kind: :response,
      watch_ref: nil,
      request_id: request.request_id,
      scope: request.scope,
      generation: request.generation,
      revision: nil,
      sequence: nil,
      body: body
    }

  # Appendix A as the terminal sees it: the fake store's data, SWARM_THEME
  # and VISUAL set, and three cli.json values (the theme is shadowed by env).
  defp appendix_a(size \\ {160, 45}) do
    {columns, rows} = size
    state = act!(ready(), {:resize, %Size{columns: columns, rows: rows}})

    state = %{
      state
      | prefs: %{"theme" => "dark", "panel" => "compact", "show_diffs" => false},
        launch_facts: %{
          env_overrides: %{
            "terminal.theme" => %{var: "SWARM_THEME", value: "light"},
            "terminal.editor" => %{var: "VISUAL", value: "hx"}
          }
        }
    }

    serve(act(state, {:settings_open, nil}), FakeSettings.seed())
  end

  defp lines(state) do
    {[region], nil} = SettingsProjector.project(state, nil)

    Enum.map(region.blocks, fn block ->
      Enum.map_join(block.spans, "", &SafeText.value(&1.text))
    end)
  end

  # The page column of the body, one string per line, runs of spaces
  # folded to two and the ends trimmed. Pass 75 (E): the page is the grid's
  # page span of each body line (no `│` rules any more); the group spine
  # (`╭─ `, `│`, `╰`) is dropped, the focus `▌` kept, and the blank lines
  # between groups are left out.
  defp page_column(state), do: state |> page_rows() |> Enum.map(&elem(&1, 1))

  # The page column with each line's spine cell (NO_COLOR draws the twin:
  # `*` a set value, `|` a default, `!` attention, `>` the focus, a space on
  # a continuation line or a title).
  defp page_rows(state) do
    grid = Grid.for(state.size.columns, state.size.rows)

    state
    |> lines()
    |> Enum.slice(grid.body_top, grid.body_rows)
    |> Enum.map(fn line ->
      page = String.slice(line, grid.page.left, grid.page.width)

      text =
        page
        |> unspine()
        |> String.replace(~r/ {2,}/, "  ")
        |> String.trim()

      {String.first(page) || " ", text}
    end)
    |> Enum.reject(&(elem(&1, 1) == ""))
  end

  # The spine cell (`╭─ ` of a title, `│ ╰ ╭`; the twin's `* | !`) is dropped,
  # and so is the twin's `----` run of a title.
  defp unspine("╭─ " <> rest), do: rest

  defp unspine(line) do
    line = String.replace(line, ~r/ -{3,}/, "")

    case String.next_grapheme(line) do
      {spine, rest} when spine in ["│", "╰", "╭", "*", "|", "!"] -> " " <> rest
      _ -> line
    end
  end

  # Every scalar with its value, as the registry's rules resolve it.
  defp resolved(state) do
    ctx = Nav.ctx(state)

    for id <- Sections.ids(),
        entry <- Registry.for_section(id),
        Entry.scalar?(entry),
        entry.type not in [:fact, :action, :link],
        %{} = setting <- [Rows.setting(ctx, entry)],
        do: {entry, setting}
  end

  describe "F1 at 160×45 with Appendix A" do
    test "the page column: attention, glance, changed from default, where values come from" do
      state = appendix_a()
      column = page_column(state)

      # pass 75 (E): the focus is the twin's `>` in the spine column (R28.2),
      # and a value wider than its column wraps rather than being cut (R22.4).
      assert Enum.take(column, 17) == [
               "needs attention  3",
               ">! github MCP server failed to start  Enter open",
               "command not found: github-mcp-server",
               "! 2 models in use have no price  Enter open",
               "claude-sonnet-5, qwen3-coder",
               "! ailogic's project file has entries SwarmCode ignores  Enter open",
               "effort, hooks.post_edit, profiles.fast.mode",
               "at a glance",
               "providers  4 · 3 usable · chat DeepSeek · deepseek-v4-pro",
               "search  2 of 6 engines on · Tavily first",
               "MCP  3 servers · 1 failed · 41 tools",
               "agents  6 at once · depth 2 · 60 turns",
               "approvals  auto · trusted · 5 always-allowed commands",
               "storage  1.8 GB · 214 sessions · last cleanup 12 days",
               "ago",
               "budget  $38.20 of $50.00 this month  ▰▰▰▰▰▰▰▰▰▰▰▰▱▱▱▱",
               "changed from default  #{changed_count(state)} · @modified lists every one"
             ]

      # The first 9 changed values, the strongest layers first, then the rest.
      # Pass 75: a changed value carries no `•`; its spine names the layer
      # that set it (the twin's `*`, R21.7), and its wrapped lines have none.
      changed = state |> page_rows() |> Enum.drop(17)

      {shown, [{_, more} | _]} =
        Enum.split_while(changed, &(not (elem(&1, 1) =~ ~r/^\+\d+ more$/)))

      values = for {"*", text} <- shown, do: text
      assert length(values) == 9
      assert Enum.all?(shown, fn {spine, _} -> spine in ["*", " "] end)
      assert more == "+#{changed_count(state) - 9} more"

      assert Enum.at(values, 2) ==
               "Theme  Light · cli.json says Dark  env SWARM_THEME"

      assert Enum.at(values, 3) == "Editor for Ctrl-X  hx  env VISUAL"
    end

    test "where values come from: the fixed points, and every value counted once" do
      # pass 75 (E): the blank line between groups and the wrapped values put
      # this group below a 38-row body; a taller terminal shows it whole. Its
      # rows are the lines with a spine (a wrapped line has none).
      state = appendix_a({160, 70})
      column = page_rows(state)
      start = Enum.find_index(column, &String.starts_with?(elem(&1, 1), "where values come from"))

      rows =
        for {spine, text} <- Enum.drop(column, start + 1), spine != " ", do: text

      rows = Enum.take(rows, 8)

      counts =
        Map.new(rows, fn row ->
          [_, layer, n] = Regex.run(~r/^(.+?)\s+(\d+)(?:\s|$)/, row)
          {layer, String.to_integer(n)}
        end)

      assert counts["flag"] == 2
      assert counts["env"] == 2
      assert counts["project file"] == 0
      assert Enum.sum(Map.values(counts)) == length(resolved(state))
      assert Enum.find(rows, &String.starts_with?(&1, "env")) =~ "SWARM_THEME, VISUAL"
      assert Enum.find(rows, &String.starts_with?(&1, "cli.json")) =~ "panel, show_diffs"
      assert Enum.find(rows, &String.starts_with?(&1, "project file")) =~ "set there, shadowed"
    end

    test "the search row counts what changed, what needs attention and what env sets" do
      [_header, search | _] = lines(appendix_a())
      n = changed_count(appendix_a())
      # pass 75 (R25.2): three spaces apart, the attention chip padded
      assert String.replace(search, ~r/ {2,}/, "  ") =~
               "• #{n} changed from default  ! 3 need attention  2 from env"
    end
  end

  describe "moving on from the Overview" do
    test "a blank open focuses the first attention item; Enter opens its record" do
      state = appendix_a()
      assert Nav.current(state).id == "att:mcp_failed:github"
      assert state.settings.deep_link == nil

      state = act!(state, {:settings, {:verb, :enter}})
      assert Layer.section(state.settings) == :mcp
      assert {"mcp_server", _id} = Layer.page(state.settings).record
    end

    test "an item that points at a section opens the section" do
      state = Nav.put_cursor(appendix_a(), "att:unpriced_models")
      state = act!(state, {:settings, {:verb, :enter}})
      assert Layer.section(state.settings) == :pricing
      assert Layer.depth(state.settings) == 1
    end

    test "a glance line opens its section" do
      state = Nav.put_cursor(appendix_a(), "info:glance:storage")
      state = act!(state, {:settings, {:verb, :enter}})
      assert Layer.section(state.settings) == :storage
    end

    test "… N more opens the search on @modified with every changed value" do
      state = appendix_a()
      total = changed_count(state)
      state = Nav.put_cursor(state, "info:changed_more")
      state = act!(state, {:settings, {:verb, :enter}})
      assert state.settings.mode == :search
      assert state.settings.search.query == "@modified"
      assert length(state.settings.search.found.results) == total
    end

    test "a changed value is an ordinary row: Enter edits it in place" do
      state = Nav.put_cursor(appendix_a(), "key:terminal.editor")
      state = act!(state, {:settings, {:verb, :enter}})
      assert state.settings.editing.row_id == "key:terminal.editor"
      assert Layer.section(state.settings) == :overview
    end
  end

  describe "the client's attention" do
    test "AT13: cli.json that cannot be read, is open to others or holds values it cannot use" do
      state = appendix_a()

      bad = put_cli(state, %{status: :not_json, invalid: [], mode: 0o600})
      assert "cli.json is not valid JSON" in titles(bad)

      open = put_cli(state, %{status: :ok, invalid: ["panel", "mouse"], mode: 0o644})
      assert "cli.json is readable by other users (0644)" in titles(open)
      assert "2 values in cli.json are not understood" in titles(open)
      assert Enum.any?(page_column(open), &(&1 =~ "panel, mouse · the defaults answer instead"))

      failed = put_cli(state, {:error, :eacces})
      [first | _] = Overview.items(Nav.ctx(failed))
      assert first.severity == :error
      assert first.id in ["cli:unreadable", "mcp_failed:github"]
      assert "cli.json could not be read" in titles(failed)
    end

    test "AT14: key overrides the keymap ignored, with the first reason" do
      state = appendix_a()
      overrides = %Overrides{errors: [{"open_palette", "Ctrl-C is fixed"}, {"quit", "no key"}]}
      state = %{state | key_overrides: overrides}
      assert "2 key overrides in cli.json were ignored" in titles(state)
      assert Enum.any?(page_column(state), &(&1 == "open_palette: Ctrl-C is fixed"))

      state = Nav.put_cursor(state, "att:keys:ignored")
      assert Layer.section(act!(state, {:settings, {:verb, :enter}}).settings) == :keys
    end
  end

  describe "changed in this session" do
    test "the newest 6 first, with `u` while something can be undone" do
      changelog =
        for n <- 1..8,
            do: %{
              at: 1_790_000_000_000 + n * 60_000,
              text: "Change #{n}",
              undo?: true,
              key: nil
            }

      step = %{
        write_key: {:cli, "panel"},
        label: "Side panel",
        old: "full",
        new: "compact",
        inverse: {:patch, "terminal.panel", :absent},
        redo: {:patch, "terminal.panel", "compact"},
        at: 1
      }

      state = appendix_a({160, 80})
      state = %{state | settings_history: %Undo{changelog: Enum.reverse(changelog), past: [step]}}
      column = page_column(state)
      start = Enum.find_index(column, &String.starts_with?(&1, "changed in this session"))
      assert Enum.at(column, start) == "changed in this session  u undoes the newest"
      entries = column |> Enum.drop(start + 1) |> Enum.take_while(&(&1 != ""))
      assert length(entries) == 6
      assert Enum.all?(entries, &Regex.match?(~r/^\d\d:\d\d  Change \d$/, &1))
      assert hd(entries) =~ "Change 8"
    end
  end

  describe "before and without attention" do
    test "before the overview arrives the page says it is looking" do
      state =
        ready()
        |> act!({:resize, %Size{columns: 160, rows: 45}})
        |> act!({:settings_open, nil})

      assert "Looking for what needs you…" in page_column(state)
      assert state.settings.deep_link == :first_attention
    end

    test "nothing to attend to: the words, and the focus on the first row" do
      fake = FakeSettings.seed()
      state = act!(ready(), {:resize, %Size{columns: 160, rows: 45}})
      {state, effects} = act(state, {:settings_open, nil})
      state = serve({state, effects}, fake)
      layer = state.settings
      overview = %{layer.data.overview | attention: []}
      state = %{state | settings: %{layer | data: %{layer.data | overview: overview}}}
      assert "Nothing needs your attention." in page_column(state)
      assert Nav.settle(state) |> Nav.current() |> Map.get(:id) =~ "info:glance:"
    end
  end

  defp changed_count(state),
    do: state |> resolved() |> Enum.count(fn {_, s} -> s.winner not in [nil, :default] end)

  defp titles(state), do: state |> Nav.ctx() |> Overview.items() |> Enum.map(& &1.title)

  defp put_cli(%{settings: layer} = state, cli),
    do: %{state | settings: %{layer | data: %{layer.data | cli: cli}}}
end
