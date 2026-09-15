defmodule SwarmCodeCLI.UI.ProjectorRunsDashboardTest do
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{Action, Capabilities, Fixtures, Init, Input, Keymap, LayerSpec}
  alias SwarmCodeCLI.UI.{Projector, Reducer, SafeText, Scene, Size, State, Theme, Width}
  alias SwarmCodeCLI.UI.DataSource.DTO
  alias SwarmCodeCLI.UI.Paint.{Blocks, Options}
  alias SwarmCodeCLI.UI.Projector.{RunsDashboard, Support}

  @layer {:runs_dashboard, "dash-1"}

  defp base(columns \\ 150, rows \\ 30),
    do: Fixtures.representative(:chat, %Size{columns: columns, rows: rows}, struct(Capabilities))

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

  defp agent(id, run_id) do
    %DTO.AgentSummary{id: id, run_id: run_id, revision: 1, state: :running, allowed_actions: []}
  end

  # A state with one run of every kind the dashboard groups, plus agents on the
  # swarm and consensus runs so the agent-derived meta has something to count.
  defp populated(columns \\ 150, rows \\ 30) do
    runs = [
      run("swarm-1", :swarm, title: "Swarm auth boundary", created_sequence: 6),
      run("consensus-1", :consensus, title: "Auth review board", created_sequence: 5),
      run("research-1", :research, title: "Auth landscape", created_sequence: 4),
      run("workflow-1", :workflow, title: "Release checklist", created_sequence: 3),
      run("goal-1", :goal, title: "Auth hardening", created_sequence: 2),
      run("chat-1", :chat, title: "Assistant thread", created_sequence: 1)
    ]

    agents = [
      agent("a1", "swarm-1"),
      agent("a2", "swarm-1"),
      agent("a3", "swarm-1"),
      agent("b1", "consensus-1")
    ]

    state = base(columns, rows)

    state = %{
      state
      | layers: [],
        focus: "main",
        read_model: %{
          state.read_model
          | runs: Map.new(runs, &{&1.id, &1}),
            agents: Map.new(agents, &{&1.id, &1})
        }
    }

    # Opened the way a keystroke opens it, so the focus the tests see is a focus
    # the user can actually reach rather than one written by hand.
    {state, _effects} = Reducer.update(state, {:open_layer, @layer})
    state
  end

  defp texts(%SafeText{} = t), do: [SafeText.value(t)]
  defp texts(%{__struct__: _} = t), do: t |> Map.from_struct() |> texts()
  defp texts(m) when is_map(m), do: m |> Map.values() |> texts()
  defp texts(l) when is_list(l), do: Enum.flat_map(l, &texts/1)
  defp texts(t) when is_tuple(t), do: t |> Tuple.to_list() |> texts()
  defp texts(_), do: []

  describe "grouping by kind" do
    test "runs are grouped under their themed kind in display order" do
      order = populated() |> RunsDashboard.groups() |> Enum.map(&elem(&1, 0))

      assert order == [
               :swarm,
               :consensus_judge,
               :research,
               :workflow,
               :goal,
               :assistant
             ]
    end

    test "wire kinds :chat and :consensus map onto the Theme.run_kind vocabulary" do
      grouped = Map.new(RunsDashboard.groups(populated()))

      # :chat and :consensus are not Theme.run_kind/1 keys; they must be
      # translated or the theme lookup would raise.
      refute Map.has_key?(grouped, :chat)
      refute Map.has_key?(grouped, :consensus)
      assert [%{id: "chat-1"}] = grouped[:assistant]
      assert [%{id: "consensus-1"}] = grouped[:consensus_judge]
    end

    test "every group key is accepted by Theme.run_kind/1" do
      for {kind, _runs} <- RunsDashboard.groups(populated()) do
        assert {_mark, role} = SwarmCodeCLI.UI.Theme.run_kind(kind)
        assert role in SwarmCodeCLI.UI.Scene.Style.roles()
      end
    end

    test "each run lands in exactly one group" do
      groups = RunsDashboard.groups(populated())
      ids = Enum.flat_map(groups, fn {_kind, runs} -> Enum.map(runs, & &1.id) end)

      assert Enum.sort(ids) ==
               Enum.sort([
                 "swarm-1",
                 "consensus-1",
                 "research-1",
                 "workflow-1",
                 "goal-1",
                 "chat-1"
               ])

      assert length(ids) == length(Enum.uniq(ids))
    end

    test "superseded runs are left out of every group" do
      state = populated()
      superseded = %{state.read_model.runs["goal-1"] | state: :superseded}
      state = put_in(state.read_model.runs["goal-1"], superseded)

      ids =
        state
        |> RunsDashboard.groups()
        |> Enum.flat_map(fn {_kind, runs} -> Enum.map(runs, & &1.id) end)

      refute "goal-1" in ids
    end

    test "the group heading carries the kind mark and name" do
      rendered = populated() |> RunsDashboard.project(150) |> texts() |> Enum.join(" ")

      assert rendered =~ "SWARMS"
      assert rendered =~ "CONSENSUS"
      assert rendered =~ "DEEP RESEARCH"
      assert rendered =~ "WORKFLOWS"
      assert rendered =~ "GOALS"
    end
  end

  describe "kind-specific meta" do
    test "a swarm reports its agent count from the read model" do
      [{:swarm, [swarm]}] =
        populated() |> RunsDashboard.groups() |> Enum.filter(&(elem(&1, 0) == :swarm))

      assert RunsDashboard.meta(swarm, :swarm) =~ "3 agents"
    end

    test "a consensus run reports its reviewers, not its agents" do
      [{:consensus_judge, [consensus]}] =
        populated() |> RunsDashboard.groups() |> Enum.filter(&(elem(&1, 0) == :consensus_judge))

      meta = RunsDashboard.meta(consensus, :consensus_judge)
      assert meta =~ "1 reviewer"
      refute meta =~ "agent"
    end

    test "agent count is singular for exactly one agent" do
      state = populated()
      state = put_in(state.read_model.agents, %{"a1" => agent("a1", "swarm-1")})

      [{:swarm, [swarm]}] =
        state |> RunsDashboard.groups() |> Enum.filter(&(elem(&1, 0) == :swarm))

      assert RunsDashboard.meta(swarm, :swarm) =~ "1 agent"
      refute RunsDashboard.meta(swarm, :swarm) =~ "1 agents"
    end

    test "a run with no agents omits the agent clause entirely" do
      state = populated()
      state = put_in(state.read_model.agents, %{})

      [{:swarm, [swarm]}] =
        state |> RunsDashboard.groups() |> Enum.filter(&(elem(&1, 0) == :swarm))

      meta = RunsDashboard.meta(swarm, :swarm)
      refute meta =~ "agent"
      refute String.starts_with?(meta, " · ")
    end

    test "every kind produces meta drawn from real run facts" do
      groups = Map.new(RunsDashboard.groups(populated()))

      for {kind, [run]} <- groups do
        meta = RunsDashboard.meta(run, kind)
        assert is_binary(meta)
        # progress is 40 on every fixture run, so each kind must surface it.
        assert meta =~ "40%"
      end
    end

    test "meta reflects each run's own progress rather than a shared constant" do
      state = populated()
      state = put_in(state.read_model.runs["research-1"].progress, 77)

      groups = Map.new(RunsDashboard.groups(state))
      [research] = groups[:research]
      [workflow] = groups[:workflow]

      assert RunsDashboard.meta(research, :research) =~ "77%"
      assert RunsDashboard.meta(workflow, :workflow) =~ "40%"
    end
  end

  describe "layer and scene integration" do
    test "the runs_dashboard layer is a valid layer spec" do
      assert LayerSpec.validate(@layer) == {:ok, @layer}
      assert match?({:error, :invalid_layer_spec}, LayerSpec.validate({:runs_dashboard, ""}))
    end

    test "the dashboard projects a valid full-screen scene with opaque actions" do
      {scene, actions} = populated() |> Projector.project()

      assert Scene.validate(scene) == :ok
      assert scene.overlay
      assert scene.overlay.id == "runs_dashboard"

      assert Enum.all?(actions, fn {id, target} ->
               is_binary(id) and
                 match?({:ok, _}, SwarmCodeCLI.UI.ActionTarget.validate(target))
             end)
    end

    test "the overlay spans the full width and leaves the title and status rows" do
      {scene, _} = populated(150, 30) |> Projector.project()
      rect = scene.overlay.rect

      assert rect.x == 0
      assert rect.width == 150
      assert rect.y == 1
      assert rect.height == 28
    end

    test "rows are clickable and navigate to their own run" do
      {_scene, actions} = populated() |> Projector.project()
      targets = Map.values(actions)

      for id <- ["swarm-1", "consensus-1", "research-1", "workflow-1"] do
        assert {:local, {:navigate, {:run, id}}} in targets
      end
    end

    test "the dashboard still projects a valid scene at small and odd sizes" do
      for {columns, rows} <- [{50, 14}, {72, 20}, {100, 24}, {200, 60}] do
        {scene, _} = populated(columns, rows) |> Projector.project()
        assert Scene.validate(scene) == :ok, "invalid scene at #{columns}x#{rows}"
      end
    end

    test "an empty read model still projects a valid scene" do
      state = populated()
      state = put_in(state.read_model.runs, %{})
      {scene, _} = Projector.project(state)

      assert Scene.validate(scene) == :ok
    end
  end

  describe "row layout" do
    # Paint.Scene.dialog/2 lays the body out in `rect.width - 2`: the two border
    # columns are not the body's to spend. Painting at the projector's own outer
    # width instead would hide a body that is exactly two cells too wide.
    defp body_width(state) do
      {scene, _} = Projector.project(state)
      scene.overlay.rect.width - 2
    end

    defp painted_lines(state) do
      {scene, _} = Projector.project(state)
      base = %{foreground: nil, background: nil, modifiers: []}

      {:ok, lines} =
        Blocks.lines(
          scene.overlay.blocks,
          scene.overlay.rect.width - 2,
          %Options{color_mode: :truecolor},
          base,
          200
        )

      Enum.map(lines, &Enum.map_join(&1.units, fn unit -> unit.text end))
    end

    test "each run occupies exactly one line" do
      state = populated()
      lines = painted_lines(state)
      width = body_width(state)

      # Blocks inside a Surface stack vertically, so a row built from many
      # blocks would print one line per block instead of one line per run.
      for title <- ["Swarm auth boundary", "Auth review board", "Release checklist"] do
        matching = Enum.filter(lines, &String.contains?(&1, title))
        assert length(matching) == 1, "#{title} spanned #{length(matching)} lines"
      end

      # A wrapped row spills its tail onto a line the title is not on, so
      # counting title matches cannot see it. Six kinds with one run each cost a
      # header, a blank, and per group a heading, one row and a closing blank;
      # anything that wrapped shows up as an extra line.
      assert length(lines) == 2 + 6 * 3,
             "the dashboard painted #{length(lines)} lines instead of #{2 + 6 * 3}"

      # And nothing the dashboard draws may spend more than the body it is laid
      # out in: one cell over and Paint wraps the line.
      for line <- lines do
        assert Width.cells(line, :narrow) <= width,
               "a dashboard line spent #{Width.cells(line, :narrow)} of #{width} cells"
      end
    end

    test "a row shows the title, the status word and the meta on that one line" do
      [row] =
        populated()
        |> painted_lines()
        |> Enum.filter(&String.contains?(&1, "Swarm auth boundary"))

      assert row =~ "RUNNING"
      assert row =~ "3 agents"
    end

    test "the gauge is 28 cells wide whatever the progress" do
      for progress <- [0, 40, 100] do
        state = populated()
        state = put_in(state.read_model.runs["research-1"].progress, progress)

        [row] =
          state
          |> painted_lines()
          |> Enum.filter(&String.contains?(&1, "Auth landscape"))

        tick = SafeText.value(SafeText.chrome(:seg_on))
        ticks = row |> String.graphemes() |> Enum.count(&(&1 == tick))

        assert ticks == 28, "progress #{progress} drew #{ticks} ticks"
      end
    end

    test "groups are separated by a blank line" do
      lines = painted_lines(populated())
      swarms = Enum.find_index(lines, &String.contains?(&1, "SWARMS"))
      consensus = Enum.find_index(lines, &String.contains?(&1, "CONSENSUS"))

      assert swarms < consensus
      assert Enum.any?(Enum.slice(lines, swarms..consensus), &(String.trim(&1) == ""))
    end
  end

  describe "windowing" do
    # A screenful of runs, one kind, so the window is easy to reason about.
    defp many(count, columns \\ 100, rows \\ 24) do
      runs =
        for n <- 1..count//1,
            do: run("run-#{n}", :swarm, title: "Run #{n}", created_sequence: count - n)

      state = base(columns, rows)

      state = %{
        state
        | layers: [],
          focus: "main",
          read_model: %{
            state.read_model
            | runs: Map.new(runs, &{&1.id, &1}),
              agents: %{},
              order: %{shell: Enum.map(runs, & &1.id)}
          }
      }

      {state, _} = Reducer.update(state, {:open_layer, @layer})
      state
    end

    defp lines_of(state) do
      {scene, _} = Projector.project(state)
      base = %{foreground: nil, background: nil, modifiers: []}

      {:ok, lines} =
        Blocks.lines(
          scene.overlay.blocks,
          scene.overlay.rect.width - 2,
          %Options{color_mode: :truecolor},
          base,
          200
        )

      Enum.map(lines, &Enum.map_join(&1.units, fn unit -> unit.text end))
    end

    test "the body never paints more lines than the dialog has room for" do
      for count <- [1, 5, 40], {columns, rows} <- [{50, 14}, {72, 20}, {100, 24}, {150, 30}] do
        state = many(count, columns, rows)
        {scene, _} = Projector.project(state)
        # The two border rows and the single footer line are not the body's.
        room = scene.overlay.rect.height - 3

        assert length(lines_of(state)) <= room,
               "#{count} runs painted #{length(lines_of(state))} lines into #{room} at #{columns}x#{rows}"
      end
    end

    test "runs that do not fit are counted rather than painted off the bottom" do
      state = many(40)
      %{first: first, shown: shown, total: total} = RunsDashboard.window(state)

      assert first == 0
      assert total == 40
      assert length(shown) < 40

      lines = lines_of(state)
      assert Enum.any?(lines, &String.contains?(&1, "#{40 - length(shown)} more below"))

      # What is painted is what is offered: no action for a row nobody can see.
      {_scene, actions} = Projector.project(state)
      targets = Map.values(actions)
      drawn = Enum.map(shown, & &1.id)

      for id <- drawn, do: assert({:local, {:navigate, {:run, id}}} in targets)

      for id <- RunsDashboard.ids(state) -- drawn,
          do: refute({:local, {:navigate, {:run, id}}} in targets)
    end

    test "the window follows the focus, so every run can be reached and opened" do
      state = many(40)
      ids = RunsDashboard.ids(state)

      # Walking down with the arrow keys reaches the last run, and the window
      # carries it onto the screen instead of leaving it undrawable.
      walked =
        Enum.reduce(1..(length(ids) - 1), state, fn _, acc ->
          {next, _} = Reducer.update(acc, {:focus_cycle, :next})
          next
        end)

      assert walked.focus == List.last(ids)
      window = RunsDashboard.window(walked)
      assert walked.focus in Enum.map(window.shown, & &1.id)
      assert window.first > 0

      lines = lines_of(walked)
      assert Enum.any?(lines, &String.contains?(&1, "Run 40"))
      assert Enum.any?(lines, &String.contains?(&1, "#{window.first} more above"))

      {_scene, actions} = Projector.project(walked)
      assert {:local, {:navigate, {:run, List.last(ids)}}} in Map.values(actions)
    end

    test "Home, End and the page keys move the window" do
      state = many(40)
      ids = RunsDashboard.ids(state)

      {:ok, action} = special_action(state, :end)
      {ended, _} = Reducer.update(state, action)
      assert ended.focus == List.last(ids)

      {:ok, action} = special_action(ended, :home)
      {homed, _} = Reducer.update(ended, action)
      assert homed.focus == List.first(ids)
      assert RunsDashboard.window(homed).first == 0

      page = length(RunsDashboard.window(homed).shown)
      {:ok, action} = special_action(homed, :page_down)
      {down, _} = Reducer.update(homed, action)
      assert down.focus == Enum.at(ids, page)

      {:ok, action} = special_action(down, :page_up)
      {up, _} = Reducer.update(down, action)
      assert up.focus == List.first(ids)
    end

    test "a dashboard with nothing in it still offers a focusable control" do
      state = many(0)

      assert RunsDashboard.focus_graph(state) == ["cancel"]
      assert state.focus == "cancel"
      assert RunsDashboard.page_focus(state, :end) == nil

      {scene, _} = Projector.project(state)
      assert Scene.validate(scene) == :ok
    end

    defp special_action(state, code), do: Keymap.resolve(Input.key(code), state, %{})
  end

  describe "kind marks" do
    # {themed kind, group label, mark, ASCII twin, run_kind letter, run title}
    @marks [
      {:swarm, "SWARMS", "⋔", "S", "S", "Swarm auth boundary"},
      {:consensus_judge, "CONSENSUS", "⚖", "C", "C", "Auth review board"},
      {:research, "DEEP RESEARCH", "⌕", "/", "R", "Auth landscape"},
      {:workflow, "WORKFLOWS", "⧉", "#", "W", "Release checklist"},
      {:goal, "GOALS", "◉", "*", "G", "Auth hardening"},
      {:assistant, "ASSISTANT", "✳", "*", "A", "Assistant thread"}
    ]

    defp mark_lines(state, opts \\ []) do
      {scene, _} = Projector.project(state)
      base = %{foreground: nil, background: nil, modifiers: []}
      options = %Options{color_mode: :truecolor, ascii?: Keyword.get(opts, :ascii?, false)}

      {:ok, lines} =
        Blocks.lines(
          scene.overlay.blocks,
          scene.overlay.rect.width - 2,
          options,
          base,
          200,
          Keyword.get(opts, :policy, :narrow)
        )

      Enum.map(lines, &Enum.map_join(&1.units, fn unit -> unit.text end))
    end

    defp ascii_mode(state),
      do: %{state | capabilities: %{state.capabilities | ascii?: true}}

    test "run_mark covers every kind the dashboard groups" do
      for {kind, _runs} <- RunsDashboard.groups(populated()) do
        token = Theme.run_mark(kind)
        assert is_atom(token)
        assert Map.has_key?(Support.glyphs(), token)
      end
    end

    test "a group heading leads with the kind mark, not the run_kind letter" do
      lines = mark_lines(populated())

      for {_kind, label, mark, _ascii, letter, _title} <- @marks do
        heading = Enum.find(lines, &String.contains?(&1, label))
        assert heading, "no heading for #{label}"

        assert String.starts_with?(heading, "  " <> mark <> " " <> label),
               "#{label} heading was #{inspect(String.slice(heading, 0, 20))}"

        refute String.starts_with?(heading, "  " <> letter <> " " <> label)
      end
    end

    test "a run row is led by its kind mark, not the run_kind letter" do
      lines = mark_lines(populated())

      for {_kind, _label, mark, _ascii, letter, title} <- @marks do
        [row] = Enum.filter(lines, &String.contains?(&1, title))

        assert String.contains?(row, mark <> " " <> title),
               "#{title} row was #{inspect(String.slice(row, 0, 30))}"

        refute String.contains?(row, letter <> " " <> title)
      end
    end

    test "marks degrade to their ASCII twins in ASCII mode" do
      lines = populated() |> ascii_mode() |> mark_lines(ascii?: true)

      for {_kind, label, mark, ascii, _letter, title} <- @marks do
        heading = Enum.find(lines, &String.contains?(&1, label))
        [row] = Enum.filter(lines, &String.contains?(&1, title))

        assert String.starts_with?(heading, "  " <> ascii <> " " <> label)
        assert String.contains?(row, ascii <> " " <> title)
        refute String.contains?(heading, mark)
        refute String.contains?(row, mark)
      end
    end

    test "the dashboard's own row text degrades in ASCII mode, not just its kind marks" do
      # Asserting the kind mark alone passes over every other glyph the
      # dashboard draws as row text: the header's key hints and the rule that
      # closes a group heading are mojibake on an ASCII-only terminal unless
      # they go through the same registered twins.
      screen = populated() |> ascii_mode() |> mark_lines(ascii?: true) |> Enum.join("\n")

      for token <- [:rule, :enter_key, :seg_on] do
        unicode = SafeText.value(SafeText.chrome(token))
        twin = SafeText.value(Support.glyph(token, ascii_mode(populated())))

        refute twin == unicode, "#{token} has no distinct ASCII twin"

        refute String.contains?(screen, unicode),
               "#{token}'s Unicode form survived into ASCII mode"
      end

      # The box-drawing rule the heading used to hard-code, and the arrows the
      # header used to hard-code, are gone too.
      refute String.contains?(screen, "─")
      refute String.contains?(screen, "⇅")
      assert String.contains?(screen, "Up/Dn move")
      assert String.contains?(screen, "Enter open")
      assert String.contains?(screen, "Ctrl-G close")
    end

    test "the group heading rule stays inside the card under the wide width policy" do
      # Density.safe/4 budgets in cells, so counting rule characters instead of
      # cells would draw twice the budget under :wide, where the rule glyph is
      # two cells, and the heading would end in an ellipsis instead of a rule.
      for policy <- [:narrow, :wide] do
        state = populated()
        state = %{state | capabilities: %{state.capabilities | ambiguous_width: policy}}
        lines = mark_lines(state, policy: policy)
        heading = Enum.find(lines, &String.contains?(&1, "SWARMS"))

        assert heading, "no SWARMS heading under #{policy}"
        refute String.contains?(heading, "…"), "the #{policy} heading rule was elided"

        assert Width.cells(heading, policy) <= 148,
               "the #{policy} heading spent #{Width.cells(heading, policy)} of 148 cells"

        # And it is a rule, not a stub: it reaches most of the way across.
        assert Width.cells(heading, policy) > 100
      end
    end

    test "the header keeps its summary and its controls apart at every width" do
      # A character-counted budget elides "6 runs · 6 live" mid-word under :wide,
      # where U+00B7 MIDDLE DOT is two cells.
      for columns <- [50, 72, 100, 150], policy <- [:narrow, :wide] do
        state = populated(columns, 30)
        state = %{state | capabilities: %{state.capabilities | ambiguous_width: policy}}
        lines = mark_lines(state, policy: policy)
        header = hd(lines)

        assert String.contains?(header, "6 runs · 6 live"),
               "the summary was cut at #{columns} columns under #{policy}: #{inspect(header)}"

        assert Width.cells(header, policy) <= columns - 2
      end
    end

    test "a marked row still occupies exactly one line under both width policies" do
      # A mark that measured two cells under :wide would push the row over the
      # terminal width and wrap it onto a second line.
      for policy <- [:narrow, :wide] do
        lines = mark_lines(populated(), policy: policy)

        for {_kind, _label, mark, _ascii, _letter, title} <- @marks do
          matching = Enum.filter(lines, &String.contains?(&1, title))

          assert length(matching) == 1,
                 "#{title} spanned #{length(matching)} lines under #{policy}"

          assert String.contains?(hd(matching), mark <> " " <> title)
        end
      end
    end
  end

  describe "filter" do
    defp with_filter(state, text),
      do: %{state | selection: Map.put(state.selection, "runs_dashboard_filter", text)}

    test "the filter box starts empty and shows the affordance" do
      rendered = populated() |> RunsDashboard.project(150) |> texts() |> Enum.join(" ")

      assert rendered =~ "/ filter"
    end

    test "a filter narrows the runs to matching titles" do
      ids =
        populated()
        |> with_filter("auth")
        |> RunsDashboard.groups()
        |> Enum.flat_map(fn {_kind, runs} -> Enum.map(runs, & &1.id) end)

      assert Enum.sort(ids) == ["consensus-1", "goal-1", "research-1", "swarm-1"]
      refute "workflow-1" in ids
    end

    test "filtering is case-insensitive" do
      upper = populated() |> with_filter("AUTH") |> RunsDashboard.groups()
      lower = populated() |> with_filter("auth") |> RunsDashboard.groups()

      assert upper == lower
    end

    test "a filter that empties a kind drops the whole group" do
      kinds =
        populated()
        |> with_filter("release")
        |> RunsDashboard.groups()
        |> Enum.map(&elem(&1, 0))

      assert kinds == [:workflow]
    end

    test "the active filter is shown in place of the affordance" do
      rendered =
        populated()
        |> with_filter("auth")
        |> RunsDashboard.project(150)
        |> texts()
        |> Enum.join(" ")

      assert rendered =~ "/auth"
    end

    test "the header counts reflect the filtered set" do
      rendered =
        populated()
        |> with_filter("release")
        |> RunsDashboard.project(150)
        |> texts()
        |> Enum.join(" ")

      assert rendered =~ "1 runs"
    end
  end

  describe "keybindings" do
    # Letter keys reach the keymap as text fragments; only the codes in
    # Input's @special_keys list are valid {:key, ...} inputs.
    defp chord(state, letter, mods),
      do: Keymap.resolve(Input.text_fragment(:press, letter, mods), state, %{})

    defp special(state, code, table \\ %{}),
      do: Keymap.resolve(Input.key(code), state, table)

    # The shell fixture focuses the composer, where a bare letter is typing, not
    # a binding. Focus main so "q" is read as a command.
    defp shell(state), do: %{state | layers: [], focus: "main"}

    # Fixtures.representative/3 carries no watches, and opening a run opens a
    # workspace watch, so a state that is going to be navigated needs the slots
    # Reducer.init/1 creates.
    defp navigable(state) do
      {seeded, _} =
        Reducer.init(%Init{
          size: state.size,
          capabilities: state.capabilities,
          source_epoch: "fixture-epoch",
          destination: state.destination
        })

      %{state | watches: seeded.watches, pages: seeded.pages}
    end

    test "Ctrl-G opens the dashboard from the shell" do
      state = shell(base())

      assert {:ok, {:open_layer, {:runs_dashboard, id}}} = chord(state, "g", [:control])
      assert is_binary(id)
      assert LayerSpec.validate({:runs_dashboard, id}) == {:ok, {:runs_dashboard, id}}
    end

    test "Ctrl-G, Esc and q all close the open dashboard" do
      state = populated()

      assert chord(state, "g", [:control]) == {:ok, :close_top_layer}
      assert special(state, :escape) == {:ok, :close_top_layer}
      assert chord(state, "q", []) == {:ok, :close_top_layer}
    end

    test "q closes the dashboard instead of quitting the session" do
      state = populated()

      # With no layer open, q is the quit binding; the dashboard must shadow it.
      assert {:ok, {:quit_requested, :detach}} = chord(shell(state), "q", [])
      assert chord(state, "q", []) == {:ok, :close_top_layer}
    end

    # The whole keyboard path, driven through the real Keymap and Reducer with
    # the real action table: open, move, open a run. Nothing here hand-writes a
    # focus, because a focus no key sequence can reach proves nothing.
    test "Ctrl-G then Down then Enter opens a run without touching the mouse" do
      start = populated() |> shell() |> navigable()

      assert {:ok, {:open_layer, {:runs_dashboard, _}} = open} = chord(start, "g", [:control])
      {opened, _} = Reducer.update(start, open)
      assert match?([{:runs_dashboard, _}], opened.layers)

      # Focus has to land on a run row, not on the generic dialog graph.
      assert Reducer.focus_graph(opened) ==
               ["swarm-1", "consensus-1", "research-1", "workflow-1", "goal-1", "chat-1"]

      assert opened.focus == "swarm-1"

      {_scene, table} = Projector.project(opened)
      assert {:ok, {:focus_cycle, :next} = down} = Keymap.resolve(Input.key(:down), opened, table)
      {moved, _} = Reducer.update(opened, down)
      assert moved.focus == "consensus-1"

      # Enter opens the run the user moved to, and the dashboard gets out of the
      # way instead of sitting on top of what it just opened.
      {_scene, table} = Projector.project(moved)

      assert {:ok, {:navigate, {:run, "consensus-1"}} = enter} =
               Keymap.resolve(Input.key(:enter), moved, table)

      {navigated, _} = Reducer.update(moved, enter)
      assert navigated.destination == {:run, "consensus-1"}
      assert navigated.layers == []
    end

    test "the focused row is the highlighted one" do
      start = populated() |> shell() |> navigable()
      {:ok, open} = chord(start, "g", [:control])
      {opened, _} = Reducer.update(start, open)

      {scene, _} = Projector.project(opened)
      assert scene.overlay.focused_control_id == "swarm-1"

      {moved, _} = Reducer.update(opened, {:focus_cycle, :next})
      {scene, _} = Projector.project(moved)
      assert scene.overlay.focused_control_id == "consensus-1"
    end

    test "clicking a run card closes the dashboard rather than leaving it on top" do
      state = navigable(populated())
      {_scene, actions} = Projector.project(state)

      {id, _} =
        Enum.find(actions, fn {_id, target} ->
          target == {:local, {:navigate, {:run, "research-1"}}}
        end)

      assert {:ok, action} = Keymap.activate(Map.fetch!(actions, id), state, actions)
      {navigated, _} = Reducer.update(state, action)

      assert navigated.destination == {:run, "research-1"}
      assert navigated.layers == []
    end

    test "Enter opens the focused run" do
      state = %{populated() | focus: "research-1"}
      table = %{"act" => {:local, {:navigate, {:run, "research-1"}}}}

      assert special(state, :enter, table) == {:ok, {:navigate, {:run, "research-1"}}}
    end

    test "Enter is ignored when focus is not a run" do
      state = %{populated() | focus: "not-a-run"}
      table = %{"act" => {:local, {:navigate, {:run, "research-1"}}}}

      assert special(state, :enter, table) == :ignore
    end

    test "the open action validates as an Action" do
      {:ok, action} = chord(shell(base()), "g", [:control])

      assert match?({:ok, _}, Action.validate(action))
    end
  end

  describe "filter typing" do
    @all_ids ["chat-1", "consensus-1", "goal-1", "research-1", "swarm-1", "workflow-1"]

    # One keystroke end to end: the keymap resolves the input, the reducer
    # applies the action it produced.
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

    defp visible_ids(state) do
      state
      |> RunsDashboard.groups()
      |> Enum.flat_map(fn {_kind, runs} -> Enum.map(runs, & &1.id) end)
      |> Enum.sort()
    end

    defp query(state), do: State.runs_filter(state)

    test "a printable character reaches the query and narrows the visible runs" do
      state = populated()
      assert visible_ids(state) == @all_ids

      {typed, action} = press(state, Input.text_fragment(:press, "r", []))
      assert action == {:dashboard_filter, {:append, "r"}}

      typed = type(typed, "el")
      assert query(typed) == "rel"
      assert visible_ids(typed) == ["workflow-1"]
    end

    test "the narrowed dashboard renders the live query and still projects a valid scene" do
      typed = populated() |> type("rel")
      rendered = typed |> RunsDashboard.project(150) |> texts() |> Enum.join(" ")

      assert rendered =~ "/rel"
      refute rendered =~ "/ filter"
      assert rendered =~ "1 runs"

      {scene, _} = Projector.project(typed)
      assert Scene.validate(scene) == :ok
    end

    test "backspace restores the runs the last character hid" do
      typed = populated() |> type("rel")
      assert visible_ids(typed) == ["workflow-1"]

      {back, action} = press(typed, Input.key(:backspace))
      assert action == {:dashboard_filter, :backspace}
      assert query(back) == "re"

      # "Auth review board" and "Assistant thread" match "re" but not "rel".
      assert visible_ids(back) == ["chat-1", "consensus-1", "workflow-1"]

      {back, _} = press(back, Input.key(:backspace))
      {back, _} = press(back, Input.key(:backspace))
      assert query(back) == ""
      assert visible_ids(back) == @all_ids
    end

    test "backspace on an empty query changes nothing" do
      state = populated()
      {next, action} = press(state, Input.key(:backspace))

      assert action == {:dashboard_filter, :backspace}
      assert next == state
      assert next.revision == state.revision
    end

    test "Esc clears a non-empty query and only then closes the layer" do
      typed = populated() |> type("rel")

      {cleared, action} = press(typed, Input.key(:escape))
      assert action == {:dashboard_filter, :clear}
      assert query(cleared) == ""
      assert cleared.layers == [@layer]
      assert visible_ids(cleared) == @all_ids

      {closed, action} = press(cleared, Input.key(:escape))
      assert action == :close_top_layer
      assert closed.layers == []
    end

    test "q types into a non-empty query but closes an empty one" do
      state = populated()

      # Empty query: q is still the dashboard's close key, never the session quit.
      assert Keymap.resolve(Input.text_fragment(:press, "q", []), state, %{}) ==
               {:ok, :close_top_layer}

      typed = type(state, "auth")
      {next, action} = press(typed, Input.text_fragment(:press, "q", []))

      assert action == {:dashboard_filter, {:append, "q"}}
      assert query(next) == "authq"
      assert next.layers == [@layer]
      assert visible_ids(next) == []
    end

    test "the generic b back key behaves like q: close while empty, type once typing" do
      state = populated()

      assert Keymap.resolve(Input.text_fragment(:press, "b", []), state, %{}) ==
               {:ok, :close_top_layer}

      typed = type(state, "auth")
      {next, action} = press(typed, Input.text_fragment(:press, "b", []))

      assert action == {:dashboard_filter, {:append, "b"}}
      assert query(next) == "authb"
      assert next.layers == [@layer]
    end

    test "Ctrl-G closes the dashboard whatever has been typed" do
      typed = populated() |> type("rel")

      {closed, action} = press(typed, Input.text_fragment(:press, "g", [:control]))
      assert action == :close_top_layer
      assert closed.layers == []
    end

    test "closing the dashboard drops the query so the next Ctrl-G opens on every run" do
      typed = populated() |> type("rel")
      {closed, _} = press(typed, Input.text_fragment(:press, "g", [:control]))

      assert query(closed) == ""
      refute Map.has_key?(closed.selection, "runs_dashboard_filter")
    end

    test "modified keystrokes are never typing" do
      state = populated()

      # A dashboard with a filter must not swallow Alt- and Ctrl- chords as text.
      for mods <- [[:alt], [:control]], letter <- ["i", "z", "r"] do
        {next, action} = press(state, Input.text_fragment(:press, letter, mods))

        refute match?({:dashboard_filter, _}, action),
               "#{letter} with #{inspect(mods)} typed into the filter"

        assert query(next) == ""
      end
    end

    test "the filter only moves while the dashboard is the top layer" do
      state = %{populated() | layers: [:help, @layer]}
      {next, _} = Reducer.update(state, {:dashboard_filter, {:append, "r"}})

      assert next == state
      assert query(next) == ""
    end

    test "the query is bounded rather than growing with every keystroke" do
      typed = populated() |> type(String.duplicate("a", 80))

      assert String.length(query(typed)) == 64
    end

    test "every filter action passes Action.validate/1 and the vocabulary stays closed" do
      for action <- [
            {:dashboard_filter, {:append, "r"}},
            {:dashboard_filter, {:append, "Æ"}},
            {:dashboard_filter, :backspace},
            {:dashboard_filter, :clear}
          ] do
        assert {:ok, ^action} = Action.validate(action)
        assert action == Action.validate!(action)
      end

      for action <- [
            {:dashboard_filter, {:append, ""}},
            {:dashboard_filter, {:append, "\n"}},
            {:dashboard_filter, {:append, "\t"}},
            {:dashboard_filter, {:append, "\e"}},
            {:dashboard_filter, {:append, String.duplicate("x", 65)}},
            {:dashboard_filter, {:append, :r}},
            {:dashboard_filter, :insert}
          ] do
        assert {:error, :invalid_action} = Action.validate(action)
        assert_raise ArgumentError, "invalid action", fn -> Action.validate!(action) end
      end
    end
  end
end
