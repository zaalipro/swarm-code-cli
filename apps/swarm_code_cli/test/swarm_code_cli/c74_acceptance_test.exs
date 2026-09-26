defmodule SwarmCodeCLI.C74AcceptanceTest do
  @moduledoc """
  cli74 F-4: the §6 acceptance items marked *test*, on the merged tree. The
  loops of A2, A3, A5, A31 and A33 are here; every other item points to the
  owner test (or the finisher's) that proves it. The sandbox items (the
  release, a sandbox HOME, GNU screen, `sqlite3` on the sandbox database) are
  in `docs/research/2026-09-25-cli74-settings-outcome.md`.

  | Item | Proven by |
  |---|---|
  | A1 open/close, focus/draft/scroll kept | `ui/settings/c74_open_test.exs` ("F2 opens…", "/config and /prefs…", "the boot query…"), `entry/c74_settings_open_test.exs` |
  | A2 every section at four sizes | here |
  | A3 every registry entry on its page and in search, `/settings <key>` | here |
  | A4 every record kind page opens | `ui/settings/sections/c74_*_test.exs` (providers, search_web, mcp, pricing, library, memory, language_servers, storage), `ui/settings/c74_project_file_test.exs` (hook, profile), daemon `c74_client_e2e_test.exs` (every section on the real service) |
  | A5 too small | here |
  | A6 writes per layer, `session.mode` four columns | `ui/settings/c74_commit_test.exs`, `ui/settings/c74_data_test.exs`, daemon `settings/c74_values_test.exs` |
  | A8 desktop messages | `ui/settings/c74_commit_test.exs` ("a rejected value…"), core `settings/c74_types_test.exs`, daemon `c74_registry_parity_test.exs` |
  | A9 provenance, env, flag, ignored layers | `ui/settings/c74_commit_test.exs` ("an env override wins…"), `entry/c74_terminal_preferences_test.exs`, `ui/settings/c74_models_effort_test.exs` |
  | A10 live terminal preferences | `ui/settings/c74_preferences_test.exs`, `ui/settings/c74_keys_layout_startup_test.exs`, `entry/c74_launch_test.exs` |
  | A11 cli.json | core `settings/c74_cli_file_test.exs`, `ui/pass72_preferences_runtime_test.exs` |
  | A12 undo/redo | `ui/settings/c74_undo_test.exs` |
  | A13 `swarmcode config` | `entry/c74_config_command_test.exs` |
  | A14 conflicts | `ui/settings/c74_commit_test.exs` ("a conflict keeps mine and theirs…"), `ui/settings/c74_data_test.exs` (a second change carries the saved CAS), daemon `c74_values_test.exs`, `c74_socket_test.exs` |
  | A15 record and file CAS | daemon `c74_providers_test.exs`, `c74_mcp_test.exs`, `c74_files_test.exs`; `ui/settings/sections/c74_memory_test.exs` |
  | A16 deltas re-query | `ui/settings/c74_data_test.exs` ("settings_update re-reads…", "…delivered on the shell watch…"), daemon `c74_backend_settings_test.exs` |
  | A17–A20 secrets | `ui/settings/c74_secret_canary_test.exs`, daemon `c74_secrets_test.exs`, `c74_socket_test.exs`, `ui/data_source/c74_settings_codec_test.exs` |
  | A21 MCP env masking, import | daemon `c74_mcp_test.exs`, `c74_mcp_import_test.exs`, `c74_transfer_test.exs`; `ui/settings/sections/c74_mcp_test.exs` |
  | A22–A26 async tasks | daemon `c74_tasks_test.exs`, `c74_providers_test.exs`, `c74_mcp_test.exs`; `ui/settings/c74_tasks_test.exs`, `ui/settings/sections/c74_providers_test.exs` |
  | A27 storage | daemon `c74_storage_test.exs`, `ui/settings/sections/c74_storage_test.exs` |
  | A28–A30 keys | `ui/keymap/c74_overrides_test.exs`, `ui/settings/c74_keymap_test.exs`, `ui/settings/c74_editors_u3_test.exs`, `ui/bindings_test.exs`, `mix swarm_code.keymap --check` |
  | A31 F1 Overview at 160×45 | here (rail) and `ui/settings/c74_overview_test.exs` (page column) |
  | A32 F14 at 90×30 | `ui/settings/c74_approvals_test.exs`, `ui/settings/c74_projector_test.exs` |
  | A33 80×24 drill-down | here |
  | A34 NO_COLOR / ASCII | `ui/settings/c74_projector_test.exs` ("the ASCII twin…", "monochrome keeps every mark…") |
  | A35 bounds | `ui/settings/c74_projector_test.exs` ("a 400-row page…"), `ui/settings/c74_search_test.exs` ("search over the whole index stays fast"), `ui/c74_f_ascii_fast_path_test.exs` |
  | A36 provider-less start | `ui/settings/c74_provider_test.exs`, daemon `c74_backend_settings_test.exs` |
  | A37 LiveBackend | `ui/settings/c74_data_test.exs` ("an unsaved live session…"), daemon `c74_backend_settings_test.exs` |
  | A38 no capability | `ui/settings/c74_data_test.exs` ("a service without settings…") |
  | A39 reads never insert | daemon `c74_values_test.exs`, `c74_search_test.exs`, `c74_providers_test.exs` |
  | A40 owned work | daemon `c74_tasks_test.exs`, `ui/settings/c74_safety_test.exs` |
  | A41 fake-only, plain golden | `ui/data_source/c74_settings_integrations_test.exs`, `demo/*` goldens |
  | A43–A62 section behaviours | the section tests named in A4, `ui/settings/c74_effort_levels_test.exs`, `ui/settings/c74_budget_desktop_test.exs`, `ui/settings/c74_files_env_test.exs`, `ui/settings/c74_import_export_test.exs`, `ui/settings/c74_approvals_test.exs`, `ui/settings/c74_models_effort_test.exs`, daemon `c74_socket_test.exs`, `c74_connection_test.exs` |
  | A63 palette | `ui/settings/c74_open_test.exs` ("the palette lists Settings…", ">settings: lists every setting row") |
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.C74U3Helpers

  alias SwarmCode.Settings.Registry
  alias SwarmCodeCLI.UI.{Input, Keymap, Projector, SafeText, Size}
  alias SwarmCodeCLI.UI.Settings.{Layer, Nav, Page, Search, Sections}

  @sizes [{160, 45}, {120, 30}, {90, 30}, {80, 24}]

  defp sized(state, columns, rows),
    do: act!(state, {:resize, %Size{columns: columns, rows: rows}})

  defp lines(state) do
    {scene, _} = Projector.project(state)

    scene.regions
    |> Enum.flat_map(& &1.blocks)
    |> Enum.map(fn block -> Enum.map_join(block.spans, "", &SafeText.value(&1.text)) end)
  end

  describe "A2: every section at every size" do
    for {columns, rows} <- @sizes do
      test "#{columns} × #{rows}" do
        for %{id: id} <- Sections.all() do
          {state, _fake} = opened(id)
          state = sized(state, unquote(columns), unquote(rows))
          screen = lines(state)
          text = Enum.join(screen, "\n")

          assert length(screen) >= unquote(rows) - 1, "#{id}: #{length(screen)} lines"
          assert Nav.rows(state) != [], "#{id}: no rows"
          refute text =~ ~r/\bnil\b/, "#{id}:\n#{text}"
          refute text =~ "not available in this build", "#{id}:\n#{text}"
        end
      end
    end
  end

  describe "A3: every registry entry" do
    # D15: the project file's top-level keys are rows only while the file
    # sets them (Appendix A's file sets `effort`); `e` edits the whole file
    # from anywhere on the page (no row of its own).
    @only_when_set ~w(project_file.swarm_effort project_file.model project_file.swarm_model
                      project_file.denied project_file.edit)

    test "is on its section's page exactly once, and /settings <key> focuses it" do
      entries = Registry.all()
      IO.puts("A3: #{length(entries)} registry entries")

      for entry <- entries, entry.key not in @only_when_set do
        {state, _fake} = opened(entry.section)
        state = act!(state, {:settings_open, {:key, entry.key}}) |> Nav.settle()

        matches = Enum.filter(Nav.rows(state), &entry_row?(&1, entry.key))
        assert length(matches) == 1, "#{entry.key}: #{length(matches)} rows on its page"
        assert Layer.section(state.settings) == entry.section
        # the row itself, or (a key drawn as a group heading) the first row under it
        [row] = matches
        rows = Nav.rows(state)

        focus =
          if SwarmCodeCLI.UI.Settings.Row.focusable?(row),
            do: row,
            else:
              rows
              |> Enum.drop_while(&(&1 != row))
              |> Enum.find(&SwarmCodeCLI.UI.Settings.Row.focusable?/1)

        assert Nav.current(state) == focus, "#{entry.key} is not focused"
      end
    end

    test "is found by its key, its label and each synonym" do
      {state, _fake} = opened(:overview)
      index = Search.index(Nav.ctx(state))

      for entry <- Registry.all() do
        for words <- [entry.key, entry.label | entry.synonyms] do
          found = Search.run(index, words).results |> Enum.map(&elem(&1, 1))

          assert Enum.any?(found, &(Map.get(&1, :key) == entry.key)),
                 "#{entry.key} not found by #{inspect(words)}"
        end
      end
    end

    defp entry_row?(nil, _key), do: false

    defp entry_row?(row, key),
      do: row.key == key or row.id in ["key:" <> key, "act:" <> key]
  end

  describe "A5" do
    test "below 80 × 20 one sentence says so, and Esc closes the layer" do
      state = ready() |> sized(72, 18) |> act!({:settings_open, nil})
      text = state |> lines() |> Enum.map_join(" ", &String.trim/1) |> String.trim()

      assert text =~
               "Settings needs 80 × 20; this terminal is 72 × 18. Make it larger, or use swarmcode config in a shell."

      {:ok, action} = Keymap.resolve(Input.key(:escape), state, %{})
      assert act!(state, action).settings == nil
    end
  end

  describe "A31: the F1 rail at 160 × 45" do
    test "the sections in rail order under their groups, Overview first" do
      {state, _fake} = opened(:overview)
      state = sized(state, 160, 45)

      rail =
        state
        |> lines()
        |> Enum.drop(3)
        |> Enum.map(&(&1 |> String.split("│") |> hd() |> String.trim()))
        |> Enum.reject(&(&1 == ""))
        # a mark (•N, !N) or a record count (Providers 4, QA #2 P2-11)
        |> Enum.map(&String.replace(&1, ~r/\s+[•!]?\d+$/u, ""))

      expected =
        ["Overview"] ++
          Enum.flat_map(
            [
              {"models", ~w(models_effort providers pricing)a},
              {"tools", ~w(search_web deep_research mcp language_servers)a},
              {"agents", ~w(agents_limits approvals project_file memory library)a},
              {"this terminal", ~w(appearance layout keys startup)a},
              {"data", ~w(storage budget)a},
              {"more", ~w(desktop files_env import_export)a}
            ],
            fn {group, ids} -> [group | Enum.map(ids, &Sections.title/1)] end
          )

      assert Enum.take(rail, length(expected)) == expected
    end
  end

  describe "A33: 80 × 24 drill-down" do
    test "sections list → section → record → sub-page, Esc back one level each time" do
      {state, fake} = opened(:mcp)
      state = sized(state, 80, 24)

      # the section's page; the record; its env sub-page
      github = Enum.find(Nav.rows(state), &(&1.label == "github"))
      assert github, Enum.map_join(Nav.rows(state), "\n", & &1.label)
      {state, fake} = state |> Nav.put_cursor(github.id) |> key(:enter) |> serve(fake)
      assert Page.level(Layer.page(state.settings)) == :record

      env = Enum.find(Nav.rows(state), &(&1.label =~ "Environment"))
      assert env
      {state, _fake} = state |> Nav.put_cursor(env.id) |> key(:enter) |> serve(fake)
      assert Page.level(Layer.page(state.settings)) == :sub

      for row <- Nav.rows(state), row.label != "" do
        assert Enum.join(lines(state), "\n") =~ String.slice(row.label, 0, 20)
      end

      esc = fn state ->
        {:ok, action} = Keymap.resolve(Input.key(:escape), state, %{})
        act!(state, action)
      end

      state = esc.(state)
      assert Page.level(Layer.page(state.settings)) == :record
      state = esc.(state)
      assert Page.level(Layer.page(state.settings)) == :section
      assert Layer.section(state.settings) == :mcp
      # F16 (cli74 F33): the section's header says where Esc goes: the sections page.
      assert hd(lines(state)) =~ "Esc sections"

      state = esc.(state)
      assert state.settings.region == :rail
      text = Enum.join(lines(state), "\n")
      assert hd(lines(state)) =~ "Esc back to chat"

      # The sections page scrolls with its cursor (MCP servers) in view.
      for title <- ["Providers", "MCP servers", "Language servers", "Agents & limits"],
          do: assert(text =~ title, title)

      assert Enum.any?(lines(state), &(&1 =~ "▌" and &1 =~ "MCP servers"))

      # ↓ moves to the next section and Enter opens it as a page.
      state = state |> key(:down) |> elem(0) |> key(:enter) |> elem(0)
      assert state.settings.region == :page
      assert Layer.section(state.settings) == :language_servers

      state = esc.(state)
      assert state.settings.region == :rail
      state = esc.(state)
      assert state.settings == nil
    end
  end

  describe "F14: under 120 columns a one-row section strip" do
    test "the strip names the section and its neighbours, the count, and [ ] step it" do
      {state, _fake} = opened(:approvals)
      state = sized(state, 90, 30)
      [_header, strip | _] = lines(state)

      assert strip =~ "[ "
      assert strip =~ "Approvals & trust"
      assert strip =~ "Agents & limits"
      assert strip =~ "10 of 22"
      assert SwarmCodeCLI.UI.Width.cells(strip, :narrow) <= 90
      # The search row's counts shorten (F14: `• 14  ! 3  2 env`).
      refute Enum.at(lines(state), 2) =~ "changed from default"

      state =
        SwarmCodeCLI.UI.Pass73Helpers.press!(state, SwarmCodeCLI.UI.Pass73Helpers.letter("]"))

      [_header, strip | _] = lines(state)
      assert strip =~ "11 of 22"

      wide = sized(state, 120, 30)
      refute Enum.at(lines(wide), 1) =~ " of 22"
      small = sized(state, 80, 24)
      refute Enum.at(lines(small), 1) =~ " of 22"
    end
  end

  defp ready, do: SwarmCodeCLI.UI.Pass73Helpers.ready()

  defp key(state, name) do
    {:ok, action} = Keymap.resolve(Input.key(name), state, %{})
    act(state, action)
  end
end
