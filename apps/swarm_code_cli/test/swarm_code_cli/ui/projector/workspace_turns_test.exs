defmodule SwarmCodeCLI.UI.Projector.WorkspaceTurnsTest do
  @moduledoc """
  Painted-grid proof of the main transcript's shape: speaker lines with the
  streaming caret, tool one-liners collapsed and expanded, the thinking line,
  the error item, the run card's word-boundary title and plain-words state,
  the "Waiting for you" line, and the narrow 100-column layout.
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

  test "a streaming turn paints its speaker line with the agent's step and the caret" do
    {rows, _, _, _} = fixture(:swarm, {100, 30}) |> painted()
    at = index_of(rows, "  lead")

    # Text starts at column 2: no gutter, the name at cell 2, the prose under it.
    assert Enum.at(rows, at) == "  lead · planning ▮"
    assert Enum.at(rows, at - 1) == ""

    assert String.starts_with?(
             Enum.at(rows, at + 1),
             "  Five numbered lanes share a bounded view."
           )

    # The finished turns carry the local time of `at` instead of a step.
    you = fixture(:swarm, {100, 30}).read_model.transcript["001"]
    assert Enum.at(rows, index_of(rows, "  you")) == "  you · " <> Turns.clock(you.at)
    refute Enum.at(rows, index_of(rows, "  you")) =~ "▮"
  end

  test "tool calls collapse to one-liners in a burst, two cells under the speaker lines" do
    {rows, _, _, _} = fixture(:swarm, {100, 30}) |> painted()
    at = index_of(rows, "    ▸ scout-1")

    assert Enum.slice(rows, at, 4) == [
             "    ▸ scout-1  grep \"Repo\\.\"  lib/ test/ · 41 hits  0.4s ✓",
             "    ▸ scout-2  read test/session_test.exs  218 lines  0.1s ✓",
             "    ▸ lead  thinking",
             "    ▸ builder-4  edit lib/swarm_code/repo.ex  +42 −7 ▮"
           ]

    # One blank row on either side of the burst and none inside it.
    assert Enum.at(rows, at - 1) == ""
    assert Enum.at(rows, at + 4) == ""
    assert Enum.all?(rows, &(String.length(&1) <= 100))
  end

  test "an expanded tool shows the first five result lines and counts the rest" do
    state =
      fixture(:swarm, {100, 30})
      |> replace_item("005", &%{&1 | text: lines(8)})
      |> Map.put(:expansions, MapSet.new(["005"]))

    {rows, _, _, _} = painted(state)
    at = index_of(rows, "    ▾ scout-1")

    assert Enum.slice(rows, at, 7) == [
             "    ▾ scout-1  grep \"Repo\\.\"  lib/ test/ · 41 hits  0.4s ✓",
             "      result line 1",
             "      result line 2",
             "      result line 3",
             "      result line 4",
             "      result line 5",
             "      … 3 more  (Enter opens)"
           ]

    # Collapsing again through the same expansion set restores the one-liner.
    {collapsed, _, _, _} = painted(%{state | expansions: MapSet.new()})
    assert index_of(collapsed, "    ▸ scout-1")
    refute Enum.any?(collapsed, &(&1 =~ "result line"))
  end

  test "a thinking item is one dim line with its duration and expands to the thought" do
    tool = %DTO.ToolCall{name: "llm", title: "thinking", status: :done, duration_ms: 12_000}

    state =
      fixture(:swarm, {100, 30})
      |> replace_item("007", &%{&1 | tool: tool})

    {rows, _, _, _} = painted(state)
    assert Enum.at(rows, index_of(rows, "    ▸ lead")) == "    ▸ lead  thinking · 12s"

    {rows, scene, _, _} = painted(%{state | expansions: MapSet.new(["007"])})
    at = index_of(rows, "    ▾ lead")
    assert Enum.at(rows, at) == "    ▾ lead  thinking · 12s"

    assert String.starts_with?(
             Enum.at(rows, at + 1),
             "      The refresh path and the session tests"
           )

    # The line is faint: the theme's text_faint colour, no prefix cue.
    list = scene.regions |> Enum.find(&(&1.role == :main)) |> Map.fetch!(:blocks)
    list = Enum.find(list, &is_struct(&1, Block.VirtualList))
    faint = Theme.style(:text_faint, state.capabilities).foreground

    thinking =
      Enum.find(list.items, fn block ->
        Enum.any?(block.spans, &(SwarmCodeCLI.UI.SafeText.value(&1.text) =~ "thinking"))
      end)

    span = Enum.find(thinking.spans, &(SwarmCodeCLI.UI.SafeText.value(&1.text) =~ "thinking"))
    assert span.style.foreground == faint
    assert span.style.prefix == nil
  end

  test "an error item paints in the error role with its message" do
    state = fixture(:swarm, {100, 30})
    error = state.read_model.transcript["009"]
    {rows, scene, _, _} = painted(state)
    at = index_of(rows, "  ✕ builder-4")

    assert Enum.at(rows, at) == "  ✕ builder-4 · " <> Turns.clock(error.at)

    assert Enum.at(rows, at + 1) ==
             "  run_command failed: mix test exited with status 1 (2 failures)."

    assert Enum.at(rows, at - 1) == ""

    list = scene.regions |> Enum.find(&(&1.role == :main)) |> Map.fetch!(:blocks)
    list = Enum.find(list, &is_struct(&1, Block.VirtualList))
    red = Theme.style(:error, state.capabilities).foreground

    block =
      Enum.find(list.items, fn block ->
        Enum.any?(block.spans, &(SwarmCodeCLI.UI.SafeText.value(&1.text) =~ "run_command"))
      end)

    # The name and the message are red; only the time between them is faint.
    for needle <- ["builder-4", "run_command failed"] do
      span = Enum.find(block.spans, &(SwarmCodeCLI.UI.SafeText.value(&1.text) =~ needle))
      assert span.style.foreground == red
      assert span.style.prefix == nil
    end
  end

  test "the run headline cuts a long title on a word boundary and says its state in plain words" do
    title =
      "Read only application analysis of the authentication, session and billing layers " <>
        "for the quarterly architecture review"

    state = fixture(:swarm, {100, 30})
    state = put_in(state.read_model.runs["fixture-run"].title, title)
    {rows, _, _, _} = painted(state)

    row = Enum.find(rows, &String.contains?(&1, "running · 5 agents"))
    assert row, "no headline row"
    [_, shown] = Regex.run(~r/^\S (.*?) {2,}running · 5 agents\s*$/u, row)
    assert String.ends_with?(shown, "…")
    kept = String.trim_trailing(shown, "…")
    assert String.starts_with?(title, kept)
    assert String.at(title, String.length(kept)) == " "
    refute String.ends_with?(kept, " ")

    # The state follows the title on the same row, in plain words.
    for {run_state, words} <- [
          {:stopped, "stopped by you"},
          {:waiting_question, "waiting for you"},
          {:waiting_approval, "waiting for you"},
          {:done, "done · 02:14"}
        ] do
      run = state.read_model.runs["fixture-run"]
      run = %{run | state: run_state, finished_at: run.started_at + 134_000, agents_total: 3}
      {rows, _, _, _} = painted(put_in(state.read_model.runs["fixture-run"], run))
      assert Enum.any?(rows, &String.contains?(&1, "  " <> words)), "#{run_state} lacks #{words}"
    end

    short = put_in(state.read_model.runs["fixture-run"].title, "Short title")
    {rows, _, _, _} = painted(short)
    assert Enum.any?(rows, &(&1 =~ ~r/^\S Short title {2,}running · 5 agents\s*$/u))
    refute Enum.any?(rows, &String.contains?(&1, "STREAMING"))
  end

  test "full-text actions are labelled by what they open, one per kind" do
    ref = %DTO.DetailRef{id: "detail", total_bytes: 40_000}

    state =
      fixture(:chat, {100, 30})
      |> replace_item("001", &%{&1 | detail_ref: ref})
      |> replace_item("002", &%{&1 | detail_ref: ref})

    {rows, _, table, _} = painted(state)
    deck = Enum.find(rows, &(&1 =~ "Full "))
    assert deck =~ "Full reply"
    refute deck =~ "Full text"
    refute deck =~ "Full prompt"
    assert length(String.split(deck, "Full ")) - 1 == 1
    assert {:local, {:open_detail, "fixture-run", "detail"}} in Map.values(table)

    # With only the prompt carrying a detail, the one action says so.
    prompt_only = replace_item(state, "002", &%{&1 | detail_ref: nil})
    {rows, _, _, _} = painted(prompt_only)
    assert Enum.any?(rows, &(&1 =~ "Full prompt"))
    refute Enum.any?(rows, &(&1 =~ "Full reply"))
  end

  test "waiting for you is counted in plain words above the composer facts, or absent" do
    state = fixture(:chat, {100, 30})
    {rows, _, _, _} = painted(state)
    refute Enum.any?(rows, &(&1 =~ "NEEDS"))
    refute Enum.any?(rows, &(&1 =~ "Waiting for you"))

    pending = %DTO.PendingInteraction{
      id: "pending",
      run_id: "fixture-run",
      node_id: "node",
      conversation_id: "fixture-conversation",
      allowed_actions: []
    }

    {rows, _, _, _} = painted(put_in(state.read_model.interactions[pending.id], pending))
    assert hd(rows) == "Waiting for you · 1"
    refute Enum.any?(rows, &(&1 =~ "NEEDS 1"))
  end

  test "the narrow 100-column layout keeps every row inside the rect at both width policies" do
    for policy <- [:narrow, :wide] do
      {rows, scene, _, _} = fixture(:swarm, {100, 30}, policy: policy) |> painted()
      main = Enum.find(scene.regions, &(&1.role == :main))
      assert main.rect.width == 100
      assert Enum.all?(rows, &(SwarmCodeCLI.UI.Width.cells(&1, policy) <= 100))
      assert index_of(rows, "  you · ")
      assert index_of(rows, "    ▸ scout-1  grep")
      assert index_of(rows, "  lead · planning")
    end
  end

  test "at 170 columns the transcript still starts two cells into its own rect" do
    {scene, _, plan} = fixture(:swarm, {170, 40}) |> paint()
    main = Enum.find(scene.regions, &(&1.role == :main))
    rows = main_rows(plan, scene)
    at = index_of(rows, "  lead · planning")
    assert String.slice(Enum.at(rows, at), 0, 2) == "  "
    assert row(plan, main.rect.y + at, main.rect.x + 2, 4) == "lead"
  end

  test "scroll metrics count exactly the rows the transcript paints" do
    state = fixture(:swarm, {100, 40})
    {scene, _, _} = paint(state)
    main = Enum.find(scene.regions, &(&1.role == :main))
    list = Enum.find(main.blocks, &is_struct(&1, Block.VirtualList))
    ids = state.read_model.order.workspace
    assert list.total_count == length(ids)

    metric = ids |> Enum.map(&ScrollMetrics.height(state, :main, &1)) |> Enum.sum()
    assert Metrics.height(list, main.rect.width) == {:ok, metric}

    # An expansion changes both sides by the same rows.
    expanded = %{state | expansions: MapSet.new(["005"])}
    expanded = replace_item(expanded, "005", &%{&1 | text: lines(8)})
    {scene, _, _} = paint(expanded)
    main = Enum.find(scene.regions, &(&1.role == :main))
    list = Enum.find(main.blocks, &is_struct(&1, Block.VirtualList))

    assert ScrollMetrics.height(expanded, :main, "005") ==
             ScrollMetrics.height(state, :main, "005") + 6

    assert Metrics.height(list, main.rect.width) == {:ok, metric + 6}
  end

  test "ASCII terminals get the one-cell twins of every transcript glyph" do
    {rows, _, _, _} = fixture(:swarm, {100, 30}, ascii: true) |> painted()
    assert Enum.at(rows, index_of(rows, "  lead")) == "  lead · planning |"

    assert Enum.at(rows, index_of(rows, "    > scout-1")) ==
             "    > scout-1  grep \"Repo\\.\"  lib/ test/ · 41 hits  0.4s +"

    assert index_of(rows, "  x builder-4 · ")
    assert Enum.at(rows, index_of(rows, "    > builder-4")) =~ "+42 −7 |"

    expanded =
      fixture(:swarm, {100, 30}, ascii: true)
      |> replace_item("005", &%{&1 | text: lines(8)})
      |> Map.put(:expansions, MapSet.new(["005"]))

    {rows, _, _, _} = painted(expanded)
    assert index_of(rows, "    v scout-1")
    assert Enum.any?(rows, &(&1 == "      ... 3 more  (Enter opens)"))
  end

  test "durations and byte counts read as people write them" do
    assert Turns.duration_text(400) == "0.4s"
    assert Turns.duration_text(1_200) == "1.2s"
    assert Turns.duration_text(12_000) == "12s"
    assert Turns.duration_text(62_000) == "1m 02s"
    assert Turns.duration_text(3_720_000) == "1h 02m"

    # A tool with no detail falls back to the size of its result.
    tool = %DTO.ToolCall{
      name: "read_file",
      title: "read big.log",
      detail: "",
      result_bytes: 2_100,
      duration_ms: 400
    }

    state = fixture(:swarm, {100, 30}) |> replace_item("005", &%{&1 | tool: tool})
    {rows, _, _, _} = painted(state)

    assert Enum.at(rows, index_of(rows, "    ▸ scout-1")) ==
             "    ▸ scout-1  read big.log  2.1 kB  0.4s ✓"

    assert @clock_ms > 0
  end
end
