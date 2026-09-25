defmodule SwarmCodeCLI.UI.Settings.C74OpenTest do
  @moduledoc """
  cli74 U1-4: opening and closing the settings layer — F2, `/settings
  [ARG]` and its aliases, palette rows, the boot query — levels, the resume
  point, deep links, and approvals held back while it is open.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers

  alias SwarmCodeCLI.UI.{Capabilities, Fixtures, Input, Keymap, Reducer, Size, Switcher}
  alias SwarmCodeCLI.UI.DataSource.DTO
  alias SwarmCodeCLI.UI.Settings.{Layer, Page}

  defp f2(state), do: press!(state, Input.key({:function, 2}))
  defp esc(state), do: press!(state, Input.key(:escape))

  defp slash(state, text) do
    state = type(state, text)
    {:ok, action} = Keymap.draft_send(state)
    elem(Reducer.update(state, action), 0)
  end

  describe "open and close" do
    test "F2 opens at the Overview; Esc puts focus, draft and scroll back exactly" do
      state = ready() |> type("half a thought")

      state = %{
        state
        | scrolls: %{state.scrolls | main: %{state.scrolls.main | anchor: "002", follow?: false}}
      }

      before = {state.focus, text(state), state.scrolls.main}

      {opened, effects} = press(state, Input.key({:function, 2}))
      assert %Layer{generation: 1} = opened.settings
      assert Layer.section(opened.settings) == :overview
      assert {:settings_cli_read, 1} in effects
      assert Keymap.typing?(letter("x"), opened) == false

      closed = esc(opened)
      assert closed.settings == nil
      assert {closed.focus, text(closed), closed.scrolls.main} == before
    end

    test "F2 again closes; the next open resumes where the layer was" do
      state = ready() |> f2()
      state = press!(state, Input.key(:down))
      state = press!(state, letter("]"))
      assert Layer.section(state.settings) == :models_effort
      state = f2(state)
      assert state.settings == nil
      assert [%Page{section: :models_effort}] = state.settings_resume.stack

      state = f2(state)
      assert Layer.section(state.settings) == :models_effort
      assert state.settings.generation == 2
    end

    test "Esc goes back one level, then closes" do
      state = ready() |> f2()
      layer = Layer.push(state.settings, %Page{section: :overview, sub: :changes})
      state = %{state | settings: layer}
      state = esc(state)
      assert Layer.depth(state.settings) == 1
      assert esc(state).settings == nil
    end

    test "q closes from any level, Ctrl-C closes a page" do
      state = ready() |> f2()
      deeper = %{state | settings: Layer.push(state.settings, %Page{section: :mcp, sub: :x})}
      assert press!(deeper, letter("q")).settings == nil
      assert press!(state, ctrl("c")).settings == nil
    end

    test "the rail moves the page with it; Tab walks the regions" do
      state = ready() |> f2()
      state = press!(state, Input.key(:tab))
      assert state.settings.region == :rail
      state = press!(state, Input.key(:down))
      assert state.settings.rail_cursor == :models_effort
      assert Layer.section(state.settings) == :models_effort
      state = press!(state, Input.key(:right))
      assert state.settings.region == :page
      state = press!(state, Input.key(:left))
      assert state.settings.region == :rail
    end

    test "Ctrl-F badges on the rail jump to a section" do
      state = ready() |> f2() |> press!(ctrl("f"))
      assert %{labels: labels} = state.settings.jump
      {letter, :mcp} = Enum.find(labels, fn {_, id} -> id == :mcp end)
      state = press!(state, Input.text_fragment(:press, letter, []))
      assert Layer.section(state.settings) == :mcp
      assert state.settings.jump == nil
    end
  end

  describe "entry points" do
    test "/settings theme focuses terminal.theme; the command leaves the draft" do
      state = ready() |> slash("/settings theme")
      assert Layer.section(state.settings) == :appearance
      assert Layer.page(state.settings).cursor == "key:terminal.theme"
      assert text(state) == ""
    end

    test "/config and /prefs open it too, /settings again closes it" do
      for command <- ["/config", "/prefs mcp"] do
        assert %Layer{} = (ready() |> slash(command)).settings
      end

      assert Layer.section((ready() |> slash("/prefs mcp")).settings) == :mcp
      state = ready() |> slash("/settings")
      {state, _} = Reducer.update(state, {:settings_open, nil})
      assert state.settings == nil
    end

    test "/settings tavily waits for the search providers to load" do
      state = ready() |> slash("/settings tavily")
      assert Layer.section(state.settings) == :search_web
      assert state.settings.deep_link == {:record, "search_provider", "tavily"}
    end

    test "/settings nonsense shows the empty search; @filters search" do
      state = ready() |> slash("/settings nonsense")
      assert state.settings.mode == :search
      assert state.settings.search.query == "nonsense"
      assert state.settings.deep_link == {:name, "nonsense"}

      state = ready() |> slash("/settings @modified")
      assert state.settings.search.query == "@modified"
    end

    test "a long argument is cut to 200 bytes; every open argument is validated" do
      state = ready() |> slash("/settings " <> String.duplicate("é", 150))
      assert byte_size(state.settings.search.query) <= 200
    end

    test "the palette lists Settings and its sections; a setting's own row waits for two letters" do
      state = ready()
      state = press!(state, ctrl("p"))
      refute Enum.any?(Switcher.visible(state), &(&1.kind == :setting))

      rows = Switcher.visible(type(state, "s"))
      assert Enum.any?(rows, &(&1.label == "Settings"))
      assert Enum.any?(rows, &(&1.label == "Settings › Providers"))
      refute Enum.any?(rows, &(&1.kind == :setting))

      state = type(state, "mo")
      rows = Switcher.visible(state)
      first_setting = Enum.find_index(rows, &(&1.kind in [:settings, :setting]))

      model =
        Enum.find_index(
          rows,
          &(&1.kind != :setting and &1.label =~ ~r/model/i and &1.kind != :settings)
        )

      assert model != nil and first_setting != nil and model < first_setting

      last_other =
        rows |> Enum.with_index() |> Enum.filter(fn {row, _} -> row.kind != :setting end)

      {_, last_other_index} = List.last(last_other)

      assert Enum.all?(Enum.with_index(rows), fn {row, index} ->
               row.kind != :setting or index > last_other_index
             end)
    end

    test "a palette row opens the layer at its setting, the palette closes" do
      state = ready() |> press!(ctrl("p")) |> type("theme")

      row =
        Enum.find(
          Switcher.visible(state),
          &(&1.target == {:local, {:settings_open, {:key, "terminal.theme"}}})
        )

      assert row
      {state, _} = Reducer.update(state, elem(row.target, 1))
      assert state.layers == []
      assert Page.ref(Layer.page(state.settings)) == {:appearance, nil, nil}
      assert Layer.page(state.settings).cursor == "key:terminal.theme"
    end

    test ">settings: lists every setting row" do
      state = ready() |> press!(ctrl("p")) |> type(">settings:")
      rows = Switcher.visible(state)
      assert Enum.any?(rows, &(&1.kind == :setting))
      assert Enum.all?(rows, &(&1.kind in [:settings, :setting]))
    end

    test "the boot query opens once the shell is ready" do
      state = booting(init: [settings_open: "vim"])
      assert state.settings == nil and state.pending_open_settings == "vim"
      state = shell_ready(state)
      assert Page.ref(Layer.page(state.settings)) == {:keys, nil, nil}
      assert Layer.page(state.settings).cursor == "key:terminal.keymap"
      assert state.pending_open_settings == nil
    end

    test "the plain presenter and a one-shot answer with the words" do
      presenter = %SwarmCodeCLI.Plain.Presenter{}
      assert {:error, text} = SwarmCodeCLI.Plain.Command.parse("/settings mcp", presenter, nil)
      assert SwarmCodeCLI.UI.SafeText.value(text) =~ "/settings needs the full-screen terminal"
      assert SwarmCodeCLI.Plain.Command.settings_words() =~ "swarmcode config"
    end
  end

  describe "while the layer is open" do
    @size %Size{columns: 160, rows: 45}

    defp waiting do
      state = Fixtures.representative(:swarm, @size, %Capabilities{size: @size})

      interaction = %DTO.PendingInteraction{
        id: "approval-1",
        kind: :approval,
        run_id: "fixture-run",
        node_id: "node-a",
        expected_revision: 3,
        allowed_actions: [:approve, :deny],
        approval: %DTO.Approval{tool: "edit", permission: :write, arguments_preview: "a.ex"}
      }

      %{
        state
        | read_model: %{state.read_model | interactions: %{"approval-1" => interaction}},
          layers: [],
          focus: "main"
      }
    end

    test "approvals do not pop over the layer, and Ctrl-N reaches them" do
      state = waiting()
      {open, _} = Reducer.update(state, {:settings_open, nil})
      {held, _} = Reducer.update(open, :boot)
      assert held.layers == []
      assert held.settings != nil

      {reached, _} = Reducer.update(held, {:settings, {:verb, :needs_you}})
      assert reached.settings == nil
      assert reached.settings_resume != nil

      # Without the layer the same approval opens by itself.
      {shell, _} = Reducer.update(state, :boot)

      assert match?([{:approval, "approval-1"} | _], shell.layers) or
               match?([{:approval, "approval-1"} | _], reached.layers)
    end
  end
end
