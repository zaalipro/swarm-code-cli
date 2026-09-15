defmodule SwarmCodeCLI.UI.ProjectorRunPaletteTest do
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{Action, Capabilities, Init, Input, Keymap, LayerSpec}
  alias SwarmCodeCLI.UI.{Projector, Reducer, SafeText, Scene, Size, State, Width}
  alias SwarmCodeCLI.UI.DataSource.DTO
  alias SwarmCodeCLI.UI.Paint.{Blocks, Options}
  alias SwarmCodeCLI.UI.Projector.{RunPalette, RunRow}

  @layer {:run_palette, "pal-1"}
  @gauge_width 16
  @now 10_000_000

  # A reducer-initialised state rather than a fixture: the palette's Enter opens
  # a run, and navigating needs the watch bookkeeping `Reducer.init/1` sets up.
  # Colour is on because the row tells its lit gauge from its track by role.
  defp base(columns, rows) do
    size = %Size{columns: columns, rows: rows}

    {state, _effects} =
      Reducer.init(%Init{
        size: size,
        capabilities: %Capabilities{size: size, color_mode: :truecolor},
        source_epoch: "palette-epoch"
      })

    state
  end

  defp run(id, kind, opts) do
    %DTO.RunSummary{
      id: id,
      conversation_id: "conversation-#{id}",
      kind: kind,
      title: Keyword.get(opts, :title, "Run #{id}"),
      revision: 1,
      state: Keyword.get(opts, :state, :running),
      allowed_actions: [],
      progress: Keyword.get(opts, :progress, 40),
      created_sequence: Keyword.get(opts, :created_sequence, 0)
    }
  end

  defp agent(id, run_id),
    do: %DTO.AgentSummary{
      id: id,
      run_id: run_id,
      revision: 1,
      state: :running,
      allowed_actions: []
    }

  defp activity(id, run_id, created_at) do
    %DTO.ActivityItem{
      id: id,
      run_id: run_id,
      conversation_id: "conversation-#{run_id}",
      kind: :running,
      state: :running,
      title: "activity #{id}",
      revision: 1,
      allowed_actions: [],
      created_at: created_at
    }
  end

  # One run of every kind the palette lists, created oldest (goal) to newest
  # (swarm), with agents on the swarm and consensus runs so the agent-derived
  # meta has something real to count.
  defp populated(columns \\ 150, rows \\ 40) do
    runs = [
      run("swarm-1", :swarm, title: "Swarm auth boundary", created_sequence: 6),
      run("consensus-1", :consensus, title: "Auth review board", created_sequence: 5),
      run("research-1", :research, title: "Auth landscape", created_sequence: 4, progress: 12),
      run("workflow-1", :workflow, title: "Release checklist", created_sequence: 3, progress: 100),
      run("goal-1", :goal, title: "Auth hardening", created_sequence: 2, progress: 0),
      run("chat-1", :chat, title: "Assistant thread", created_sequence: 1, state: :done)
    ]

    agents = [
      agent("a1", "swarm-1"),
      agent("a2", "swarm-1"),
      agent("a3", "swarm-1"),
      agent("b1", "consensus-1")
    ]

    activity = [
      activity("act-1", "swarm-1", @now - 90_000),
      activity("act-2", "research-1", @now - 7_200_000)
    ]

    state = base(columns, rows)

    %{
      state
      | layers: [@layer],
        focus: "swarm-1",
        now: @now,
        destination: :activity,
        read_model: %{
          state.read_model
          | runs: Map.new(runs, &{&1.id, &1}),
            agents: Map.new(agents, &{&1.id, &1}),
            activity: Map.new(activity, &{&1.id, &1})
        }
    }
  end

  defp with_filter(state, text), do: State.put_runs_filter(state, text)

  defp texts(%SafeText{} = t), do: [SafeText.value(t)]
  defp texts(%{__struct__: _} = t), do: t |> Map.from_struct() |> texts()
  defp texts(m) when is_map(m), do: m |> Map.values() |> texts()
  defp texts(l) when is_list(l), do: Enum.flat_map(l, &texts/1)
  defp texts(t) when is_tuple(t), do: t |> Tuple.to_list() |> texts()
  defp texts(_), do: []

  # The blocks painted at the width the dialog border actually leaves them.
  defp painted_lines(state, opts \\ []) do
    {scene, _} = Projector.project(state)
    base_style = %{foreground: nil, background: nil, modifiers: []}
    options = %Options{color_mode: :truecolor, ascii?: Keyword.get(opts, :ascii?, false)}

    {:ok, lines} =
      Blocks.lines(
        scene.overlay.blocks,
        scene.overlay.rect.width - 2,
        options,
        base_style,
        200,
        Keyword.get(opts, :policy, :narrow)
      )

    Enum.map(lines, &Enum.map_join(&1.units, fn unit -> unit.text end))
  end

  defp row_for(state, title, opts \\ []) do
    state
    |> painted_lines(opts)
    |> Enum.filter(&String.contains?(&1, title))
  end

  describe "recency" do
    test "runs are listed newest first, whatever order the read model holds them in" do
      assert RunPalette.ids(populated()) == [
               "swarm-1",
               "consensus-1",
               "research-1",
               "workflow-1",
               "goal-1",
               "chat-1"
             ]
    end

    test "a newer run moves to the top of the list" do
      state = populated()
      state = put_in(state.read_model.runs["goal-1"].created_sequence, 99)

      assert ["goal-1" | _] = RunPalette.ids(state)
    end

    test "the palette lists by recency where the dashboard groups by kind" do
      state = populated()

      # The dashboard's first group is the swarms; the palette's first row is
      # simply the newest run, which here belongs to no particular kind order.
      state = put_in(state.read_model.runs["chat-1"].created_sequence, 42)

      assert ["chat-1" | _] = RunPalette.ids(state)
    end

    test "superseded runs are never listed" do
      state = populated()
      state = put_in(state.read_model.runs["goal-1"].state, :superseded)

      refute "goal-1" in RunPalette.ids(state)
    end

    test "the painted rows follow the listed order" do
      lines = painted_lines(populated())

      order =
        for title <- ["Swarm auth boundary", "Auth review board", "Auth landscape"],
            do: Enum.find_index(lines, &String.contains?(&1, title))

      assert order == Enum.sort(order)
      refute nil in order
    end
  end

  describe "filtering" do
    test "a query narrows the listed runs to matching titles" do
      ids = populated() |> with_filter("auth") |> RunPalette.ids()

      assert ids == ["swarm-1", "consensus-1", "research-1", "goal-1"]
      refute "workflow-1" in ids
    end

    test "filtering keeps the recency order of what is left" do
      assert populated() |> with_filter("auth") |> RunPalette.ids() ==
               populated()
               |> RunPalette.ids()
               |> Enum.filter(&(&1 in ["swarm-1", "consensus-1", "research-1", "goal-1"]))
    end

    test "filtering is case-insensitive" do
      assert populated() |> with_filter("AUTH") |> RunPalette.ids() ==
               populated() |> with_filter("auth") |> RunPalette.ids()
    end

    test "the filter line shows the query and the match count" do
      rendered =
        populated()
        |> with_filter("auth")
        |> RunPalette.dialog(:wide)
        |> texts()
        |> Enum.join(" ")

      assert rendered =~ "auth"
      assert rendered =~ "4 of 6"
    end

    test "the filter line shows the affordance and the full count while empty" do
      rendered = populated() |> RunPalette.dialog(:wide) |> texts() |> Enum.join(" ")

      assert rendered =~ "filter runs"
      assert rendered =~ "6 of 6"
    end

    test "typing narrows the palette through the dashboard's own filter action" do
      state = populated()

      {:ok, action} = Keymap.resolve(Input.text_fragment(:press, "r", []), state, %{})
      assert action == {:dashboard_filter, {:append, "r"}}

      {typed, _} = Reducer.update(state, action)
      typed = type(typed, "elease")

      assert State.runs_filter(typed) == "release"
      assert RunPalette.ids(typed) == ["workflow-1"]
    end

    test "backspace widens the palette again" do
      typed = populated() |> type("release")

      {:ok, action} = Keymap.resolve(Input.key(:backspace), typed, %{})
      assert action == {:dashboard_filter, :backspace}

      {back, _} = Reducer.update(typed, action)
      assert State.runs_filter(back) == "releas"
    end

    test "a query that hides the selected run re-anchors the selection" do
      state = %{populated() | focus: "workflow-1"}
      {typed, _} = Reducer.update(state, {:dashboard_filter, {:append, "auth"}})

      # "Release checklist" does not match "auth", so the selection cannot stay
      # on a row that is no longer listed.
      refute "workflow-1" in RunPalette.ids(typed)
      assert typed.focus == List.first(RunPalette.ids(typed))
    end

    test "a query matching nothing still projects a valid scene and a focusable control" do
      state = populated() |> with_filter("zzz")

      assert RunPalette.ids(state) == []
      assert RunPalette.focus_graph(state) == ["cancel"]

      {scene, _} = Projector.project(state)
      assert Scene.validate(scene) == :ok
      assert scene.overlay.blocks |> texts() |> Enum.join(" ") =~ "No runs match"
    end

    test "closing the palette drops the query" do
      typed = populated() |> type("release")
      {closed, _} = Reducer.update(typed, :close_top_layer)

      assert State.runs_filter(closed) == ""
      assert closed.layers == []
    end
  end

  describe "selection" do
    test "the palette opens on the run you are looking at" do
      state = %{populated() | layers: [], focus: "main", destination: {:run, "research-1"}}

      {:ok, action} = Keymap.resolve(Input.text_fragment(:press, "r", [:control]), state, %{})
      {opened, _} = Reducer.update(state, action)

      assert match?([{:run_palette, _} | _], opened.layers)
      assert opened.focus == "research-1"
    end

    test "the palette opens on the newest run when the current one is not listed" do
      state = %{populated() | layers: [], focus: "main", destination: :activity}

      {:ok, action} = Keymap.resolve(Input.text_fragment(:press, "r", [:control]), state, %{})
      {opened, _} = Reducer.update(state, action)

      assert opened.focus == "swarm-1"
    end

    test "the palette finds the current run behind a conversation destination" do
      state = %{
        populated()
        | layers: [],
          focus: "main",
          destination: {:conversation, "conversation-goal-1"}
      }

      {:ok, action} = Keymap.resolve(Input.text_fragment(:press, "r", [:control]), state, %{})
      {opened, _} = Reducer.update(state, action)

      assert opened.focus == "goal-1"
    end

    test "Down moves to the next run and Up moves back" do
      state = populated()

      {down, action} = press(state, Input.key(:down))
      assert action == {:focus_cycle, :next}
      assert down.focus == "consensus-1"

      {up, _} = press(down, Input.key(:up))
      assert up.focus == "swarm-1"
    end

    test "the selection wraps at both ends rather than clamping" do
      state = %{populated() | focus: "chat-1"}

      # "chat-1" is the oldest run, so it is the last row.
      assert List.last(RunPalette.ids(state)) == "chat-1"

      {down, _} = press(state, Input.key(:down))
      assert down.focus == "swarm-1"

      {up, _} = press(down, Input.key(:up))
      assert up.focus == "chat-1"
    end

    test "the selection only walks the listed runs, never the footer" do
      state = populated()
      ids = RunPalette.ids(state)

      walked =
        Enum.reduce(1..length(ids), {state, []}, fn _, {current, seen} ->
          {next, _} = press(current, Input.key(:down))
          {next, [next.focus | seen]}
        end)
        |> elem(1)
        |> Enum.reverse()

      assert Enum.sort(walked) == Enum.sort(ids)
    end

    test "a filtered palette moves only through the runs still listed" do
      state = %{populated() | focus: "swarm-1"} |> with_filter("auth")

      {down, _} = press(state, Input.key(:down))
      assert down.focus == "consensus-1"

      {last, _} = press(%{state | focus: "goal-1"}, Input.key(:down))
      assert last.focus == "swarm-1"
    end

    test "the focused row carries the selection stripe and the others do not" do
      state = %{populated() | focus: "consensus-1"}
      state = %{state | capabilities: %{state.capabilities | ascii?: true}}

      [focused] = row_for(state, "Auth review board", ascii?: true)
      [other] = row_for(state, "Swarm auth boundary", ascii?: true)

      # The stripe pair degrades to "#" lit and "-" unlit, so the selection is
      # legible without colour.
      assert String.starts_with?(focused, " #")
      assert String.starts_with?(other, " -")
    end
  end

  describe "opening a run" do
    test "Enter opens the focused run" do
      state = %{populated() | focus: "research-1"}
      {_scene, actions} = Projector.project(state)

      assert Keymap.resolve(Input.key(:enter), state, actions) ==
               {:ok, {:navigate, {:run, "research-1"}}}
    end

    test "Enter follows the selection" do
      state = %{populated() | focus: "goal-1"}
      {_scene, actions} = Projector.project(state)

      assert Keymap.resolve(Input.key(:enter), state, actions) ==
               {:ok, {:navigate, {:run, "goal-1"}}}
    end

    test "opening a run switches the destination and closes the palette" do
      state = %{populated() | focus: "research-1", destination: {:run, "swarm-1"}}
      {_scene, actions} = Projector.project(state)
      {:ok, action} = Keymap.resolve(Input.key(:enter), state, actions)
      {opened, _} = Reducer.update(state, action)

      assert opened.destination == {:run, "research-1"}
      assert opened.layers == []
    end

    test "every row is clickable and navigates to its own run" do
      {_scene, actions} = Projector.project(populated())
      targets = Map.values(actions)

      for id <- RunPalette.ids(populated()) do
        assert {:local, {:navigate, {:run, id}}} in targets
      end
    end

    test "Enter is ignored when the selection is not a run" do
      state = %{populated() | focus: "not-a-run"}
      table = %{"act" => {:local, {:navigate, {:run, "research-1"}}}}

      assert Keymap.resolve(Input.key(:enter), state, table) == :ignore
    end
  end

  describe "keybindings" do
    test "Ctrl-R opens the palette from the shell" do
      state = %{populated() | layers: [], focus: "main"}

      assert {:ok, {:open_layer, {:run_palette, id}}} =
               Keymap.resolve(Input.text_fragment(:press, "r", [:control]), state, %{})

      assert LayerSpec.validate({:run_palette, id}) == {:ok, {:run_palette, id}}
    end

    test "Ctrl-R closes the open palette" do
      state = populated()

      assert Keymap.resolve(Input.text_fragment(:press, "r", [:control]), state, %{}) ==
               {:ok, :close_top_layer}
    end

    test "Ctrl-R closes the palette whatever has been typed" do
      typed = populated() |> type("auth")

      {closed, action} = press(typed, Input.text_fragment(:press, "r", [:control]))
      assert action == :close_top_layer
      assert closed.layers == []
    end

    test "Esc closes the palette" do
      state = populated()
      {closed, action} = press(state, Input.key(:escape))

      assert action == :close_top_layer
      assert closed.layers == []
    end

    test "bare letters are query characters, not bindings" do
      state = populated()

      # "q" quits and "b" goes back outside the palette; inside it they type.
      for letter <- ["q", "b", "g"] do
        {next, action} = press(state, Input.text_fragment(:press, letter, []))

        assert action == {:dashboard_filter, {:append, letter}}
        assert State.runs_filter(next) == letter
      end
    end

    test "modified keystrokes are never typing" do
      state = populated()

      for mods <- [[:alt], [:control]], letter <- ["i", "z", "k"] do
        {next, action} = press(state, Input.text_fragment(:press, letter, mods))

        refute match?({:dashboard_filter, _}, action),
               "#{letter} with #{inspect(mods)} typed into the filter"

        assert State.runs_filter(next) == ""
      end
    end

    test "the open action validates as an Action" do
      state = %{populated() | layers: [], focus: "main"}
      {:ok, action} = Keymap.resolve(Input.text_fragment(:press, "r", [:control]), state, %{})

      assert match?({:ok, _}, Action.validate(action))
    end
  end

  describe "layer and scene" do
    test "the run_palette layer is a valid layer spec" do
      assert LayerSpec.validate(@layer) == {:ok, @layer}
      assert match?({:error, :invalid_layer_spec}, LayerSpec.validate({:run_palette, ""}))
    end

    test "the palette is a centred overlay of about 92 by 20" do
      {scene, _} = Projector.project(populated(200, 60))
      rect = scene.overlay.rect

      assert scene.overlay.id == "run_palette"
      assert rect.width == 92
      assert rect.height == 20
      assert rect.x == div(200 - 92, 2)
      assert rect.y == div(60 - 20, 2)
    end

    test "the palette never spills out of a terminal smaller than its own size" do
      for {columns, rows} <- [{50, 14}, {60, 16}, {80, 24}] do
        {scene, _} = Projector.project(populated(columns, rows))
        rect = scene.overlay.rect

        assert rect.x + rect.width <= columns
        assert rect.y + rect.height <= rows
      end
    end

    test "scenes validate at 50x14, 80x24 and 200x60" do
      for {columns, rows} <- [{50, 14}, {80, 24}, {200, 60}] do
        {scene, actions} = Projector.project(populated(columns, rows))

        assert Scene.validate(scene) == :ok, "invalid scene at #{columns}x#{rows}"

        assert Enum.all?(actions, fn {id, target} ->
                 is_binary(id) and match?({:ok, _}, SwarmCodeCLI.UI.ActionTarget.validate(target))
               end)
      end
    end

    test "an empty read model still projects a valid scene" do
      state = populated()
      state = put_in(state.read_model.runs, %{})
      {scene, _} = Projector.project(state)

      assert Scene.validate(scene) == :ok
      assert scene.overlay.blocks |> texts() |> Enum.join(" ") =~ "No runs yet"
    end

    test "the body reports its own window and keeps the selection inside it" do
      runs =
        for i <- 1..24,
            do:
              run("run-" <> Integer.to_string(i), :goal,
                title: "Goal " <> Integer.to_string(i),
                created_sequence: i
              )

      state = populated(150, 30)
      state = put_in(state.read_model.runs, Map.new(runs, &{&1.id, &1}))
      oldest = List.last(RunPalette.ids(state))
      state = %{state | focus: oldest}

      {scene, _} = Projector.project(state)
      overlay = scene.overlay

      assert overlay.body_total_count == 24
      {first, last} = overlay.body_visible_range
      assert overlay.body_scroll == first
      assert last <= overlay.body_total_count
      assert first > 0, "a list longer than the window never scrolled"

      # The selection is inside the window the body reports, and it is painted.
      index = Enum.find_index(RunPalette.ids(state), &(&1 == oldest))
      assert index >= first and index < last
      assert length(row_for(state, "Goal 1 ")) == 1
    end
  end

  describe "row layout" do
    test "each run occupies exactly one painted line" do
      lines = painted_lines(populated())

      for title <- [
            "Swarm auth boundary",
            "Auth review board",
            "Auth landscape",
            "Release checklist",
            "Auth hardening",
            "Assistant thread"
          ] do
        matching = Enum.filter(lines, &String.contains?(&1, title))
        assert length(matching) == 1, "#{title} spanned #{length(matching)} lines"
      end
    end

    test "a row still occupies one line under both width policies and in ASCII" do
      for policy <- [:narrow, :wide], ascii? <- [false, true] do
        state = populated()
        state = %{state | capabilities: %{state.capabilities | ascii?: ascii?}}

        assert length(row_for(state, "Release checklist", policy: policy, ascii?: ascii?)) == 1,
               "wrapped under #{policy} ascii=#{ascii?}"
      end
    end

    test "a row fills the dialog body exactly, never overflowing it" do
      state = populated()
      {scene, _} = Projector.project(state)
      inner = scene.overlay.rect.width - 2

      for line <- painted_lines(state) do
        assert Width.cells(line, :narrow) == inner
      end
    end

    test "a row carries the kind mark, the title, the status word and the meta" do
      [row] = row_for(populated(), "Swarm auth boundary")

      assert row =~ "⋔"
      assert row =~ "RUNNING"
      assert row =~ "3 agents"
      assert row =~ "40%"
    end

    test "the gauge is exactly 16 cells whatever the progress" do
      tick = SafeText.value(SafeText.chrome(:seg_on))

      for progress <- [0, 12, 50, 100] do
        state = populated()
        state = put_in(state.read_model.runs["research-1"].progress, progress)

        [row] = row_for(state, "Auth landscape")
        ticks = row |> String.graphemes() |> Enum.count(&(&1 == tick))

        assert ticks == @gauge_width, "progress #{progress} drew #{ticks} ticks"
      end
    end

    test "the gauge tracks the run's own progress, not a shared constant" do
      state = populated()

      spans = fn title ->
        RunRow.spans(run_by_title(state, title), :swarm, state,
          title_width: 10,
          gauge_width: @gauge_width
        )
      end

      # 0% lights nothing and 100% lights every cell, measured on the spans the
      # row is built from rather than on colourless painted text.
      assert gauge_split(spans.("Auth hardening"), state) == {0, @gauge_width}
      assert gauge_split(spans.("Release checklist"), state) == {@gauge_width, 0}

      assert gauge_split(spans.("Swarm auth boundary"), state) ==
               {round(0.4 * @gauge_width), @gauge_width - round(0.4 * @gauge_width)}
    end

    test "narrow terminals drop the trailing columns but keep the gauge" do
      tick = SafeText.value(SafeText.chrome(:seg_on))

      [row] = row_for(populated(50, 14), "Swarm")
      ticks = row |> String.graphemes() |> Enum.count(&(&1 == tick))

      assert ticks == @gauge_width
      assert row =~ "RUNNING"
    end
  end

  describe "meta and timestamp" do
    test "a swarm reports the agent count the read model actually holds" do
      [row] = row_for(populated(), "Swarm auth boundary")
      assert row =~ "3 agents"

      state = put_in(populated().read_model.agents, %{})
      [without] = row_for(state, "Swarm auth boundary")
      refute without =~ "agent"
    end

    test "a consensus run reports reviewers rather than agents" do
      [row] = row_for(populated(), "Auth review board")

      assert row =~ "1 reviewer"
      refute row =~ "agent"
    end

    test "research and workflow fall back to real progress, inventing no counts" do
      [research] = row_for(populated(), "Auth landscape")
      [workflow] = row_for(populated(), "Release checklist")

      assert research =~ "12%"
      refute research =~ "source"

      assert workflow =~ "100%"
      refute workflow =~ "stage"
      refute workflow =~ "step"
    end

    test "the timestamp is the age of the newest activity the read model holds" do
      state = populated()

      [swarm] = row_for(state, "Swarm auth boundary")
      [research] = row_for(state, "Auth landscape")

      # 90 seconds and two hours before state.now.
      assert String.ends_with?(String.trim_trailing(swarm), "1m")
      assert String.ends_with?(String.trim_trailing(research), "2h")
    end

    test "a run the read model holds no clock fact for shows no age" do
      state = populated()

      assert RunRow.age(state.read_model.runs["workflow-1"], state) == nil

      [workflow] = row_for(state, "Release checklist")
      refute workflow =~ ~r/\d+[smhd]\s*$/
    end

    test "the newest activity item wins when a run has several" do
      state = populated()

      state =
        put_in(
          state.read_model.activity,
          Map.merge(state.read_model.activity, %{
            "act-3" => activity("act-3", "swarm-1", @now - 86_400_000)
          })
        )

      assert RunRow.age(state.read_model.runs["swarm-1"], state) == "1m"
    end
  end

  describe "shared row builder" do
    test "the palette and the dashboard draw the same row through one builder" do
      state = populated()
      run = state.read_model.runs["swarm-1"] |> RunRow.enrich(state)

      wide = RunRow.spans(run, :swarm, state, title_width: 20, gauge_width: 28)
      narrow = RunRow.spans(run, :swarm, state, title_width: 20, gauge_width: 16)

      assert gauge_split(wide, state) |> Tuple.to_list() |> Enum.sum() == 28
      assert gauge_split(narrow, state) |> Tuple.to_list() |> Enum.sum() == 16
    end

    test "a column given no width is dropped along with its gap" do
      state = populated()
      run = state.read_model.runs["swarm-1"] |> RunRow.enrich(state)

      full = RunRow.spans(run, :swarm, state, title_width: 20)
      bare = RunRow.spans(run, :swarm, state, title_width: 20, status_width: 0, meta_width: 0)

      assert span_cells(full) - span_cells(bare) == 12 + 1 + 30 + 2
    end

    test "the wire kinds :chat and :consensus are translated before a theme lookup" do
      assert RunRow.theme_kind(:chat) == :assistant
      assert RunRow.theme_kind(:consensus) == :consensus_judge

      state = populated()

      for run <- RunPalette.rows(state) do
        kind = RunRow.theme_kind(run.kind)
        assert {_mark, role} = SwarmCodeCLI.UI.Theme.run_kind(kind)
        assert role in SwarmCodeCLI.UI.Scene.Style.roles()
      end
    end
  end

  # --- helpers ---

  defp press(state, input) do
    case Keymap.resolve(input, state, %{}) do
      {:ok, action} ->
        {next, _effects} = Reducer.update(state, action)
        {next, action}

      :ignore ->
        {state, :ignore}
    end
  end

  defp type(state, text) do
    text
    |> String.graphemes()
    |> Enum.reduce(state, fn grapheme, acc ->
      {next, _action} = press(acc, Input.text_fragment(:press, grapheme, []))
      next
    end)
  end

  defp run_by_title(state, title),
    do:
      state.read_model.runs
      |> Map.values()
      |> Enum.find(&(&1.title == title))
      |> RunRow.enrich(state)

  # The lit run and the muted track are separate spans of the same glyph, so
  # they are told apart by the track's own style rather than by their text: at
  # 0% and at 100% one of the two spans is empty.
  defp gauge_split(spans, state) do
    track = RunRow.tinted(:ticks_track, state)
    index = Enum.find_index(spans, &(&1.style == track))

    lit = spans |> Enum.at(index - 1) |> cells_of()
    unlit = spans |> Enum.at(index) |> cells_of()

    {lit, unlit}
  end

  defp cells_of(span), do: Width.cells(SafeText.value(span.text), :narrow)

  defp span_cells(spans),
    do: spans |> Enum.map(&Width.cells(SafeText.value(&1.text), :narrow)) |> Enum.sum()
end
