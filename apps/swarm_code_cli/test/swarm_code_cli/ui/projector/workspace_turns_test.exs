defmodule SwarmCodeCLI.UI.Projector.WorkspaceTurnsTest do
  @moduledoc """
  Painted-grid proof of the main transcript's shape (ux M1): the prompt on a
  card, one header row per turn saying what it is doing, a worker per lane
  line that expands in place, model steps that take no row until opened,
  tool rows with their summary and duration, the answer after the work, the
  failed run's error card, and the narrow layouts at both width policies.
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{Capabilities, Fixtures, Paint, Projector, ScrollMetrics, Size, Theme}
  alias SwarmCodeCLI.UI.DataSource.DTO
  alias SwarmCodeCLI.UI.Paint.{Metrics, Options, Plan}
  alias SwarmCodeCLI.UI.Projector.Workspace.Turns
  alias SwarmCodeCLI.UI.Scene.Block

  @clock_ms 1_789_000_000_000

  defp fixture(kind, {columns, rows}, opts \\ []) do
    size = %Size{columns: columns, rows: rows}

    caps = %Capabilities{
      size: size,
      ambiguous_width: Keyword.get(opts, :policy, :narrow),
      color_mode: Keyword.get(opts, :color, :truecolor),
      ascii?: Keyword.get(opts, :ascii, false)
    }

    Fixtures.representative(kind, size, caps)
  end

  defp paint(state) do
    {scene, table} = Projector.project(state)

    options = %Options{
      color_mode: state.capabilities.color_mode,
      ascii?: state.capabilities.ascii?
    }

    assert {:ok, plan} = Paint.build(scene, options)
    assert :ok = Plan.validate(plan)
    assert plan.diagnostics == []
    {scene, table, plan}
  end

  defp row(plan, y, x, width) do
    for column <- x..(x + width - 1), reduce: "" do
      text ->
        case Plan.cell(plan, column, y) do
          {:glyph, glyph, _, _} -> text <> glyph
          _ -> text
        end
    end
  end

  # The main region's rows, trailing blanks trimmed.
  defp main_rows(plan, scene) do
    main = Enum.find(scene.regions, &(&1.role == :main))

    for y <- main.rect.y..(main.rect.y + main.rect.height - 1),
        do: String.trim_trailing(row(plan, y, main.rect.x, main.rect.width))
  end

  defp painted(state) do
    {scene, table, plan} = paint(state)
    {main_rows(plan, scene), scene, table, plan}
  end

  defp index_of(rows, text), do: Enum.find_index(rows, &String.starts_with?(&1, text))

  defp replace_item(state, id, fun) do
    put_in(state.read_model.transcript[id], fun.(state.read_model.transcript[id]))
  end

  defp lines(n), do: Enum.map_join(1..n, "\n", &"result line #{&1}")

  defp glyph(token, state),
    do: SwarmCodeCLI.UI.SafeText.value(SwarmCodeCLI.UI.Projector.Support.glyph(token, state))

  test "the prompt is a card with its time, then the turn's one header row" do
    state = fixture(:swarm, {100, 30})
    {rows, _, _, _} = painted(state)
    you = state.read_model.transcript["001"]

    prompt = Enum.at(rows, 0)

    assert String.starts_with?(
             prompt,
             "    Review this synthetic project and explain the next step."
           )

    assert String.ends_with?(prompt, Turns.clock(you.at))

    assert Enum.at(rows, 1) == ""

    header = Enum.at(rows, 2)
    assert String.starts_with?(header, "  ⋔ lead  kimi-k2-thinking")
    assert String.ends_with?(header, "writing ▮  23k tok")
  end

  test "workers collapse to one lane line each, and a failure shows on its lane" do
    {rows, _, _, _} = fixture(:swarm, {100, 30}) |> painted()
    at = index_of(rows, "    ✦ scout-1")

    assert Enum.slice(rows, at, 4) == [
             "    ✦ scout-1  ▮ 1 tool",
             "    ✦ scout-2  ▮ 1 tool",
             "    ✦ builder-4  ▮ 1 tool  run_command failed: mix test exited with status 1 (2 failures).",
             "    ⬡ judge  needs answer"
           ]

    # The lead's words follow its workers, after one blank row.
    assert Enum.at(rows, at + 4) == ""

    assert String.starts_with?(
             Enum.at(rows, at + 5),
             "    Five numbered lanes share a bounded view."
           )

    assert Enum.all?(rows, &(String.length(&1) <= 100))
  end

  # pass71 F2: an expanded row shows twenty lines; the count of the rest
  # names no key when the whole text is on the client (Enter folds it).
  test "an expanded lane shows its calls, the first twenty result lines and counts the rest" do
    state =
      fixture(:swarm, {100, 60})
      |> replace_item("005", &%{&1 | text: lines(23)})
      |> Map.put(:expansions, MapSet.new(["005"]))

    {rows, _, _, _} = painted(state)
    at = index_of(rows, "    ✦ scout-1")

    assert Enum.at(rows, at + 1) =~ ~r/^      ✓ grep  "Repo\\\."\s+lib\/ test\/ · 41 hits  0\.4s$/

    assert Enum.slice(rows, at + 2, 21) ==
             Enum.map(1..20, &"        result line #{&1}") ++ ["        … 3 more lines"]

    # Collapsing again through the same expansion set restores the lane line.
    {collapsed, _, _, _} = painted(%{state | expansions: MapSet.new()})
    assert index_of(collapsed, "    ✦ scout-1")
    refute Enum.any?(collapsed, &(&1 =~ "result line"))
  end

  # pass71 F1/F2 (review R1/R2): a text the daemon sent only in part says
  # how much is left and Enter opens it whole; a reply cut past 8 KB says so
  # under its last row instead of ending mid-word.
  test "an output sent in part counts what is left in bytes and Enter opens it" do
    ref = %DTO.DetailRef{id: "005:text", total_bytes: 9_000}

    state =
      fixture(:swarm, {100, 60})
      |> replace_item("005", &%{&1 | text: lines(23), detail_ref: ref})
      |> Map.put(:expansions, MapSet.new(["005"]))
      |> Map.put(:focus, "main")
      |> Map.put(:selection, %{"main" => "005"})

    {rows, _, table, _} = painted(state)
    assert Enum.any?(rows, &(&1 =~ ~r/^        … 3\+ more lines, \d+\.\d kB more · Enter opens$/))
    run = state.read_model.transcript["005"].run_id
    assert {:local, {:open_detail, run, "005:text"}} in Map.values(table)

    assert {:ok, {:open_detail, ^run, "005:text"}} =
             SwarmCodeCLI.UI.Keymap.content_activate(state, table)
  end

  # pass71 F12 (review R4): "✓ run mix format … exit code pending" and four
  # "✓ poll background process" rows for one command that had not finished.
  test "a background command and a poll that found it running show no check" do
    state = fixture(:swarm, {100, 60}) |> Map.put(:expansions, MapSet.new())
    clock = glyph(:clock_mark, state)
    check = glyph(:check, state)

    background = %DTO.ToolCall{
      name: "run_command",
      title: "run: mix format",
      status: :done,
      background: true
    }

    poll = %DTO.ToolCall{
      name: "run_command",
      title: "poll background process 3313",
      status: :done
    }

    state =
      state
      |> replace_item("005", &%{&1 | tool: background, text: "exit code pending\nformatting"})
      |> replace_item("006", &%{&1 | tool: poll, text: "exit code pending\n[SwarmCode: …]"})
      |> Map.put(:expansions, MapSet.new(["scout-1", "005", "006"]))

    {rows, _, _, _} = painted(state)
    format_row = Enum.find(rows, &(&1 =~ "mix format"))
    poll_row = Enum.find(rows, &(&1 =~ "3313"))
    assert format_row && poll_row, inspect(rows)
    assert format_row =~ clock and not (format_row =~ check)
    assert poll_row =~ clock and poll_row =~ "still running"

    done = %{poll | title: "poll background process 3313"}

    {rows, _, _, _} =
      state
      |> replace_item("006", &%{&1 | tool: %{done | exit_code: 0}, text: "exit code 0\nok"})
      |> painted()

    assert Enum.find(rows, &(&1 =~ "3313")) =~ check
  end

  test "a reply cut past what the daemon sends inline says so under its last row" do
    state = fixture(:swarm, {100, 60})
    answer = state.read_model.transcript["002"]
    total = byte_size(answer.text) + 4_000
    ref = %DTO.DetailRef{id: "002:text", total_bytes: total}

    state =
      replace_item(state, "002", &%{&1 | state: :done, detail_ref: ref})

    {rows, _, _, _} = painted(state)
    assert Enum.any?(rows, &(&1 == "    … 4.0 kB more · Ctrl-T, Enter opens it all"))
  end

  test "a model step takes no row until it is opened, then says it thought and for how long" do
    tool = %DTO.ToolCall{name: "llm", title: "thinking", status: :done, duration_ms: 12_000}
    state = fixture(:swarm, {100, 30}) |> replace_item("007", &%{&1 | tool: tool})

    {rows, _, _, _} = painted(state)
    refute Enum.any?(rows, &(&1 =~ "thought"))
    refute Enum.any?(rows, &(&1 =~ "The refresh path"))

    {rows, scene, _, _} = painted(%{state | expansions: MapSet.new(["007"])})
    at = index_of(rows, "    " <> glyph(:expanded, state) <> " thought")
    assert Enum.at(rows, at) == "    ▾ thought · 12s"

    assert String.starts_with?(
             Enum.at(rows, at + 1),
             "      The refresh path and the session tests"
           )

    # The line is faint: the theme's text_faint colour, no prefix cue.
    faint = Theme.style(:text_faint, state.capabilities).foreground
    span = find_span(scene, "thought")
    assert span.style.foreground == faint
    assert span.style.prefix == nil
  end

  test "a failed run ends in an error card that says what to do next" do
    state = fixture(:swarm, {100, 30})
    run = state.read_model.runs["fixture-run"]
    run = %{run | state: :failed, error: "mix test failed", finished_at: run.started_at + 134_000}
    state = put_in(state.read_model.runs["fixture-run"], run)
    {rows, scene, _, _} = painted(state)

    at = index_of(rows, "    ✕ Failed")
    assert Enum.at(rows, at) == "    ✕ Failed · mix test failed"
    assert Enum.at(rows, at + 1) == "      retry from the palette · /model to switch model"
    assert Enum.at(rows, at - 1) == ""

    red = Theme.style(:error, state.capabilities).foreground
    span = find_span(scene, "Failed · mix test failed")
    assert span.style.foreground == red
    assert span.style.prefix == nil

    # With no reason from the daemon the card does not invent one.
    {rows, _, _, _} = painted(put_in(state.read_model.runs["fixture-run"].error, nil))
    assert Enum.any?(rows, &(&1 == "    ✕ Failed"))
  end

  test "a stopped answer says stopped once below its words, not twice (pass70 Q6)" do
    state = fixture(:swarm, {100, 30})
    run = state.read_model.runs["fixture-run"]

    state =
      put_in(state.read_model.runs["fixture-run"], %{
        run
        | state: :stopped,
          finished_at: run.started_at + 1_000
      })

    # The engine appends this to an answer it stopped (run_server.ex).
    state = replace_item(state, "002", &%{&1 | text: "Half an answer.\n\n_(stopped)_"})
    {rows, _, _, _} = painted(state)

    assert Enum.any?(rows, &(String.trim(&1) == "(stopped)"))
    refute Enum.any?(rows, &(String.trim(&1) == "stopped"))
  end

  test "the header says what the turn came to in plain words" do
    state = fixture(:swarm, {100, 30})

    for {run_state, words} <- [
          {:stopped, "stopped  2m 14s · 23k tok"},
          {:waiting_question, "waiting for you"},
          {:waiting_approval, "waiting for you"},
          {:done, "2m 14s · 23k tok"},
          {:failed, "failed  2m 14s · 23k tok"}
        ] do
      run = state.read_model.runs["fixture-run"]
      run = %{run | state: run_state, finished_at: run.started_at + 134_000}
      {rows, _, _, _} = painted(put_in(state.read_model.runs["fixture-run"], run))
      header = Enum.find(rows, &String.starts_with?(&1, "  ⋔ lead"))
      assert String.ends_with?(header, "  " <> words), "#{run_state}: #{header}"
    end

    refute Enum.any?(elem(painted(state), 0), &String.contains?(&1, "STREAMING"))
  end

  test "full-text actions stay on the keyboard, labelled by what they open" do
    ref = %DTO.DetailRef{id: "detail", total_bytes: 40_000}

    state =
      fixture(:chat, {100, 30})
      |> replace_item("001", &%{&1 | detail_ref: ref})
      |> replace_item("002", &%{&1 | detail_ref: ref})

    {rows, _, table, _} = painted(state)
    refute Enum.any?(rows, &(&1 =~ "Full "))
    assert {:local, {:open_detail, "fixture-run", "detail"}} in Map.values(table)
  end

  test "what waits on you is counted on the status row, never above the transcript" do
    state = fixture(:chat, {100, 30})
    {rows, _, _, plan} = painted(state)
    refute Enum.any?(rows, &(&1 =~ "Waiting for you"))
    refute row(plan, 29, 0, 100) =~ "waiting"

    pending = %DTO.PendingInteraction{
      id: "pending",
      run_id: "fixture-run",
      node_id: "node",
      conversation_id: "fixture-conversation",
      allowed_actions: []
    }

    {rows, _, _, plan} = painted(put_in(state.read_model.interactions[pending.id], pending))
    refute Enum.any?(rows, &(&1 =~ "Waiting for you"))
    assert row(plan, 29, 0, 100) =~ "1 waiting"
  end

  test "the narrow 100-column layout keeps every row inside the rect at both width policies" do
    for policy <- [:narrow, :wide] do
      {rows, scene, _, _} = fixture(:swarm, {100, 30}, policy: policy) |> painted()
      main = Enum.find(scene.regions, &(&1.role == :main))
      assert main.rect.width == 100
      assert Enum.all?(rows, &(SwarmCodeCLI.UI.Width.cells(&1, policy) <= 100))
      assert Enum.any?(rows, &(&1 =~ "Review this synthetic project"))
      assert index_of(rows, "    ✦ scout-1")
      assert index_of(rows, "  ⋔ lead")
    end
  end

  test "at 170 columns the transcript still starts two cells into its own rect" do
    {scene, _, plan} = fixture(:swarm, {170, 40}) |> paint()
    main = Enum.find(scene.regions, &(&1.role == :main))
    rows = main_rows(plan, scene)
    at = index_of(rows, "  ⋔ lead")
    assert row(plan, main.rect.y + at, main.rect.x, 2) == "  "
    assert row(plan, main.rect.y + at, main.rect.x + 4, 4) == "lead"
  end

  test "scroll metrics count exactly the rows the transcript paints" do
    state = fixture(:swarm, {100, 40})

    expanded =
      %{state | expansions: MapSet.new(["005", "007"])}
      |> replace_item("005", &%{&1 | text: lines(23)})

    for state <- [state, expanded] do
      {scene, _, _} = paint(state)
      main = Enum.find(scene.regions, &(&1.role == :main))
      list = Enum.find(main.blocks, &is_struct(&1, Block.VirtualList))
      ids = state.read_model.order.workspace
      assert list.total_count == length(ids)

      metric = ids |> Enum.map(&ScrollMetrics.height(state, :main, &1)) |> Enum.sum()
      assert Metrics.height(list, main.rect.width) == {:ok, metric}
    end

    # An expansion grows the lane it opens, and nothing else.
    assert ScrollMetrics.height(expanded, :main, "005") ==
             ScrollMetrics.height(state, :main, "005") + 22

    assert ScrollMetrics.height(expanded, :main, "006") ==
             ScrollMetrics.height(state, :main, "006")
  end

  test "ASCII terminals get the one-cell twins of every transcript glyph" do
    {rows, _, _, _} = fixture(:swarm, {100, 30}, ascii: true) |> painted()
    assert String.starts_with?(Enum.at(rows, 0), "  | Review this synthetic project")
    header = Enum.find(rows, &String.starts_with?(&1, "  S lead"))
    assert String.ends_with?(header, "writing |  23k tok")
    assert index_of(rows, "    + scout-1  | 1 tool")
    assert index_of(rows, "    o judge  needs answer")

    expanded =
      fixture(:swarm, {100, 30}, ascii: true)
      |> replace_item("005", &%{&1 | text: lines(23)})
      |> Map.put(:expansions, MapSet.new(["005"]))

    {rows, _, _, _} = painted(expanded)
    assert Enum.any?(rows, &(&1 == "        ... 3 more lines"))

    for row <- rows, glyph <- ["▐", "✦", "▮", "✓", "⋔"] do
      refute row =~ glyph, "#{glyph} in ASCII row #{row}"
    end
  end

  test "a run reads as prompt, work, then words, whatever order the daemon created them in" do
    state = fixture(:chat, {170, 40})
    run = SwarmCodeCLI.UI.Projector.Support.run(state)
    root = "root-" <> run.id

    item = fn id, fields ->
      struct(
        %DTO.TranscriptItem{id: id, run_id: run.id, node_id: root, state: :done, text: "t"},
        fields
      )
    end

    grep = %DTO.ToolCall{name: "grep", title: "grep Repo", detail: "3 hits", status: :done}

    # A chat turn creates the answer before the model steps and calls, and
    # each step's text is what that step said: the start of the answer.
    items = [
      item.("m-user", role: :user, kind: :text, created_sequence: 1, text: "the prompt"),
      item.("m-answer",
        role: :assistant,
        kind: :text,
        created_sequence: 2,
        state: :streaming,
        text: "Let me look.\n\nthe answer"
      ),
      item.("op-think", role: :tool, kind: :thinking, created_sequence: 3, text: "Let me look."),
      item.("op-grep", role: :tool, kind: :tool, created_sequence: 4, tool: grep)
    ]

    state = put_in(state.read_model.transcript, Map.new(items, &{&1.id, &1}))
    state = put_in(state.read_model.order[:workspace], Enum.map(items, & &1.id))

    # The order is the daemon's; the rows put the words where they were said.
    assert Turns.order(state) == ["m-user", "m-answer", "op-think", "op-grep"]

    # A second run keeps its place after the first, whatever its items rank.
    later = item.("m-later", run_id: "run-later", role: :user, kind: :text, created_sequence: 0)
    ordered = put_in(state.read_model.transcript["m-later"], later)
    ordered = put_in(ordered.read_model.order[:workspace], ["m-later" | Enum.map(items, & &1.id)])
    assert hd(Turns.order(ordered)) == "m-later"

    {rows, _, _, _} = painted(state)
    prompt = index_of(rows, "    the prompt")
    step = index_of(rows, "    Let me look.")
    work = index_of(rows, "    ✓ grep")
    words = index_of(rows, "    the answer")
    assert prompt && step && work && words, "rows: " <> inspect(Enum.take(rows, 14))
    assert prompt < step and step < work and work < words, inspect(Enum.take(rows, 14))

    # Nothing is said twice.
    assert Enum.count(rows, &(&1 =~ "Let me look.")) == 1
  end

  test "durations and byte counts read as people write them" do
    assert Turns.duration_text(400) == "0.4s"
    assert Turns.duration_text(1_200) == "1.2s"
    assert Turns.duration_text(12_000) == "12s"
    assert Turns.duration_text(62_000) == "1m 02s"
    assert Turns.duration_text(3_720_000) == "1h 02m"
    assert Turns.compact(940) == "940"
    assert Turns.compact(19_400) == "19k"
    assert Turns.compact(1_200_000) == "1.2M"

    # A tool with no detail falls back to the size of its result.
    tool = %DTO.ToolCall{
      name: "read_file",
      title: "read big.log",
      detail: "",
      result_bytes: 2_100,
      duration_ms: 400
    }

    state =
      fixture(:swarm, {100, 30})
      |> replace_item("005", &%{&1 | tool: tool, agent_id: "agent-1"})

    {rows, _, _, _} = painted(state)
    row = Enum.at(rows, index_of(rows, "    ✓ read"))
    assert row =~ ~r/^    ✓ read  big\.log\s+2\.1 kB  0\.4s$/
    assert @clock_ms > 0
  end

  defp find_span(scene, needle) do
    list = scene.regions |> Enum.find(&(&1.role == :main)) |> Map.fetch!(:blocks)
    list = Enum.find(list, &is_struct(&1, Block.VirtualList))

    list.items
    |> Enum.flat_map(& &1.spans)
    |> Enum.find(&(SwarmCodeCLI.UI.SafeText.value(&1.text) =~ needle))
  end
end
