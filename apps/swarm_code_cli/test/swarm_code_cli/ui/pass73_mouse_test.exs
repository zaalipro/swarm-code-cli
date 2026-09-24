defmodule SwarmCodeCLI.UI.Pass73MouseTest do
  @moduledoc """
  pass73 T9: wheel reports are on by default and a notch scrolls three lines
  of the pane under the pointer: the transcript, the side panel, the agent
  overlay or the pager. `/mouse` and the launcher's precedence are in
  `Pass73KeysTest` and below.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers

  alias SwarmCodeCLI.UI.{Keymap, Layout, Reducer}
  alias SwarmCodeCLI.UI.DataSource.DTO
  alias SwarmCodeCLI.Release.PersistedSession

  defp wheel(kind, column, row), do: {:mouse, kind, nil, column, row, []}

  defp agent(id, opts \\ []) do
    %DTO.AgentSummary{
      id: id,
      run_id: "r1",
      revision: 1,
      state: :running,
      panel_state: :working,
      name: id,
      role: Keyword.get(opts, :role, :worker),
      parent_id: Keyword.get(opts, :parent, "lead"),
      depth: if(Keyword.get(opts, :role) == :lead, do: 0, else: 1),
      started_at: 2_000,
      allowed_actions: [:stop_agent]
    }
  end

  defp swarm do
    ready([run("r1", :running, kind: :swarm)],
      columns: 160,
      rows: 45,
      snapshot: %{agents: [agent("lead", role: :lead, parent: nil), agent("engine")]}
    )
  end

  test "the state starts with wheel reports on" do
    assert ready().mouse?
  end

  test "over the transcript a notch scrolls it three lines" do
    state = swarm()
    %{main: main} = Layout.for_state(state).rects

    assert {:ok, {:scroll, "main", {:line, 3}}} =
             Keymap.resolve(wheel(:wheel_down, main.x + 2, main.y + 1), state, %{})

    assert {:ok, {:scroll, "main", {:line, -3}}} =
             Keymap.resolve(wheel(:wheel_up, main.x + 2, main.y + 1), state, %{})
  end

  test "over the side panel a notch scrolls the panel, never below its top" do
    state = swarm()
    %{inspector: panel} = Layout.for_state(state).rects

    assert {:ok, {:scroll, "panel", {:line, 3}} = down} =
             Keymap.resolve(wheel(:wheel_down, panel.x + 1, panel.y + 2), state, %{})

    {state, []} = Reducer.update(state, down)
    assert state.panel_scroll == 3
    {state, []} = Reducer.update(state, {:scroll, "panel", {:line, -3}})
    {state, []} = Reducer.update(state, {:scroll, "panel", {:line, -3}})
    assert state.panel_scroll == 0
  end

  test "with the overlay open a notch moves its activity, and the focus stays" do
    {state, _} = Reducer.update(swarm(), {:overlay_open, "r1", "engine"})
    steers = for n <- 1..10, do: {"r1", "steer #{n}", "engine", "engine"}
    state = %{state | steers: steers}
    focus = state.overlay.focus

    assert {:ok, {:overlay, {:scroll, 3}} = down} =
             Keymap.resolve(wheel(:wheel_down, 10, 10), state, %{})

    {state, []} = Reducer.update(state, down)
    assert state.overlay.cursor == 3
    assert state.overlay.focus == focus

    {state, []} = Reducer.update(state, {:overlay, {:scroll, -3}})
    {state, []} = Reducer.update(state, {:overlay, {:scroll, -3}})
    assert state.overlay.cursor == 0
  end

  test "the pager scrolls by lines, clamped to its body" do
    state = swarm()
    ref = %DTO.DetailRef{id: "detail", total_bytes: 100_000}

    item = %DTO.TranscriptItem{
      id: "item",
      node_id: "node",
      conversation_id: "c",
      run_id: "r1",
      attempt_id: "attempt",
      text: "preview",
      detail_ref: ref
    }

    state = %{state | read_model: %{state.read_model | transcript: %{"item" => item}}}
    {state, [_watch, {:query, request}]} = Reducer.update(state, {:open_detail, "r1", "detail"})

    body = Enum.map_join(1..200, "\n", &"line #{&1}")

    window = %DTO.DetailWindow{
      detail_ref: ref,
      request_id: request.request_id,
      text: body,
      next_offset: byte_size(body)
    }

    {state, _} =
      Reducer.update(
        state,
        {:data,
         %SwarmCodeCLI.UI.DataSource.Delivery{
           kind: :response,
           request_id: request.request_id,
           watch_ref: nil,
           scope: request.scope,
           generation: request.generation,
           revision: nil,
           sequence: nil,
           body: window
         }}
      )

    assert {:ok, {:scroll, "detail", {:line, 3}} = down} =
             Keymap.resolve(wheel(:wheel_down, 5, 5), state, %{})

    first = fn state ->
      %{body_visible_range: {first, _}} =
        SwarmCodeCLI.UI.Projector.Dialog.project(state, Layout.classify(state.size))

      first
    end

    before = first.(state)
    {state, []} = Reducer.update(state, down)
    assert first.(state) == before + 3

    {state, []} = Reducer.update(state, {:scroll, "detail", {:line, -300}})
    assert first.(state) == 0
    {state, []} = Reducer.update(state, {:scroll, "detail", {:line, 5_000}})
    bottom = first.(state)
    {state, []} = Reducer.update(state, {:scroll, "detail", {:line, -3}})
    assert first.(state) == bottom - 3
  end

  describe "the first notch from the bottom of the chat (live check)" do
    alias SwarmCodeCLI.UI.Projector.Workspace.Turns

    defp chat do
      items =
        for n <- 1..30 do
          %DTO.TranscriptItem{
            id: "i#{n}",
            node_id: "i#{n}",
            run_id: "r1",
            conversation_id: "c",
            attempt_id: "attempt",
            role: :user,
            text: "prompt number #{n}\nsecond line of #{n}"
          }
        end

      ready([run("r1", :done)],
        columns: 100,
        rows: 24,
        snapshot: %{transcript: %DTO.TranscriptWindow{items: items}}
      )
    end

    defp lines(state) do
      # The height the reducer pages by is the one drawn.
      height = SwarmCodeCLI.UI.ScrollMetrics.content_height(state, :main)
      width = SwarmCodeCLI.UI.ScrollMetrics.viewport(state, :main).width
      {blocks, _first, _total} = Turns.viewport(state, width, height)

      blocks
      |> Enum.map_join("\n", fn block ->
        Enum.map_join(block.spans, &SwarmCodeCLI.UI.SafeText.value(&1.text))
      end)
      |> String.split("\n")
    end

    defp notch(state, kind) do
      %{main: main} = Layout.for_state(state).rects
      {:ok, action} = Keymap.resolve(wheel(kind, main.x + 2, main.y + 2), state, %{})
      elem(Reducer.update(state, action), 0)
    end

    test "moves the view three rows, and back" do
      state = chat()
      following = lines(state)
      up = notch(state, :wheel_up)

      # Before, the move started from the last row and the view, drawn from
      # the end while the anchor's rows do not fill it, did not move at all.
      assert Enum.drop(lines(up), 3) == Enum.drop(following, -3)
      assert lines(notch(up, :wheel_down)) == following
      assert Enum.drop(lines(notch(up, :wheel_up)), 6) == Enum.drop(following, -6)
    end

    test "PgUp from the bottom shows the page above" do
      state = chat()
      following = lines(state)
      {:ok, action} = Keymap.resolve(SwarmCodeCLI.UI.Input.key(:page_up), state, %{})
      up = elem(Reducer.update(state, action), 0)
      refute Enum.any?(lines(up), &(&1 in following and String.trim(&1) != ""))
    end
  end

  test "the launcher: SWARM_THEME > cli.json > desktop > dark; SWARM_MOUSE > cli.json > on" do
    defaults = SwarmCodeCLI.UI.Init.Preferences.defaults()

    assert %{theme: :dark, theme_env: nil, mouse?: true} =
             PersistedSession.start_preferences(%{}, defaults, nil)

    assert %{theme: :light} = PersistedSession.start_preferences(%{}, defaults, "light")

    assert %{theme: :dark, theme_env: nil} =
             PersistedSession.start_preferences(%{}, %{defaults | theme: :dark}, "light")

    assert %{theme: :light, theme_env: :light} =
             PersistedSession.start_preferences(
               %{"SWARM_THEME" => " Light "},
               %{defaults | theme: :dark},
               "dark"
             )

    assert %{mouse?: false} =
             PersistedSession.start_preferences(%{}, %{defaults | mouse?: false}, nil)

    assert %{mouse?: true} =
             PersistedSession.start_preferences(
               %{"SWARM_MOUSE" => "1"},
               %{defaults | mouse?: false},
               nil
             )

    assert %{mouse?: false} =
             PersistedSession.start_preferences(%{"SWARM_MOUSE" => "0"}, defaults, nil)
  end
end
