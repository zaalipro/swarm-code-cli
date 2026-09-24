defmodule SwarmCodeCLI.UI.Projector.SignalsTest do
  @moduledoc """
  pass70 D6: what the daemon's new facts look like once drawn — an edit's
  `+N −M` and its diff in place, a command's exit code and background chip,
  why a turn stopped and when it retries, the untrusted-project banner, the
  rate-limit countdown and background command on the status row, daemon
  toasts, the diff detail's title and colours, and the status row keeping its
  most useful facts when it is short.
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.Demo.Conversation
  alias SwarmCodeCLI.UI.{Capabilities, Paint, Projector, Size}
  alias SwarmCodeCLI.UI.DataSource.DTO
  alias SwarmCodeCLI.UI.Paint.{Options, Plan}

  defp scene(name, {columns, rows}, opts \\ []) do
    size = %Size{columns: columns, rows: rows}

    caps = %Capabilities{
      size: size,
      color_mode: Keyword.get(opts, :color, :truecolor),
      ascii?: Keyword.get(opts, :ascii, false)
    }

    Conversation.state(name, size, caps)
  end

  defp paint(state) do
    {scene, table} = Projector.project(state)

    options = %Options{
      color_mode: state.capabilities.color_mode,
      ascii?: state.capabilities.ascii?
    }

    assert {:ok, plan} = Paint.build(scene, options)
    assert :ok = Plan.validate(plan)
    {scene, table, plan}
  end

  defp text(plan, y, x, width) do
    for column <- x..(x + width - 1), reduce: "" do
      acc ->
        case Plan.cell(plan, column, y) do
          {:glyph, glyph, _, _} -> acc <> glyph
          _ -> acc
        end
    end
  end

  defp foreground(plan, x, y) do
    case Plan.cell(plan, x, y) do
      {:glyph, _, _, style} -> elem(plan.palette, style).foreground
      _ -> nil
    end
  end

  defp screen(state) do
    {scene, table, plan} = paint(state)

    rows =
      for y <- 0..(state.size.rows - 1),
          do: String.trim_trailing(text(plan, y, 0, state.size.columns))

    {rows, scene, table, plan}
  end

  defp find(rows, pattern), do: Enum.find_index(rows, &(&1 =~ pattern))

  defp expand(state, ids), do: %{state | expansions: MapSet.new(ids)}

  describe "the transcript" do
    test "an edit says +5 −1 and opens to its hunks in the diff colours" do
      state = scene(:trouble, {120, 60}) |> expand(["demo-run-2-item-004"])
      {rows, _scene, _table, plan} = screen(state)

      edit = find(rows, ~r/edit +lib\/tickets\/guard\.ex +\+5 −1 +14ms$/)
      assert edit, Enum.join(rows, "\n")

      hunk = Enum.at(rows, edit + 1)
      assert hunk =~ ~r/^ +@@ -12,9 \+12,13 @@/
      refute Enum.any?(rows, &(&1 =~ "diff --git"))

      removed = find(rows, ~r/^ +-  def check\(actor, ticket\) do/)
      added = find(rows, ~r/^ +\+  def authorize\(actor, ticket\) do/)
      assert removed && added

      x = rows |> Enum.at(removed) |> String.length() |> Kernel.-(1)
      assert foreground(plan, x, removed) != foreground(plan, x, added)
    end

    # pass71 V3 (R5): the first hunk is in place without expanding the row.
    test "an edit shows its first hunk inline, unexpanded" do
      {rows, _scene, _table, _plan} = scene(:trouble, {120, 60}) |> screen()

      edit = find(rows, ~r/edit +lib\/tickets\/guard\.ex +\+5 −1 +14ms$/)
      assert edit, Enum.join(rows, "\n")
      assert Enum.at(rows, edit + 1) =~ ~r/^ +@@ -12,9 \+12,13 @@/
      assert find(rows, ~r/^ +\+  def authorize\(actor, ticket\) do/)
    end

    test "a long diff stops after twelve lines and says how many more and how to open it" do
      state = scene(:trouble, {120, 60})
      id = "demo-run-2-item-004"
      item = state.read_model.transcript[id]

      body = Enum.map_join(1..30, "\n", &"+line #{&1}")
      second = "@@ -80,2 +94,3 @@\n context\n+more\n context"

      long =
        "--- a/lib/tickets/guard.ex\n+++ b/lib/tickets/guard.ex\n@@ -1,0 +1,30 @@\n" <>
          body <> "\n" <> second

      state = put_in(state.read_model.transcript[id], %{item | text: long})
      {rows, _scene, _table, _plan} = screen(state)

      edit = find(rows, ~r/edit +lib\/tickets\/guard\.ex/)
      assert Enum.at(rows, edit + 1) =~ ~r/^ +@@ -1,0 \+1,30 @@/
      assert Enum.at(rows, edit + 12) =~ ~r/^ +\+line 11$/
      # 35 diff lines, 12 shown.
      assert Enum.at(rows, edit + 13) =~ ~r/^ +… 23 more lines · Enter opens$/
      refute Enum.any?(rows, &(&1 =~ "+line 12"))
    end

    test "the daemon's first hunk and line count are read from the tool call" do
      state = scene(:trouble, {120, 60})
      id = "demo-run-2-item-004"
      item = state.read_model.transcript[id]
      hunk = "@@ -3,2 +3,2 @@\n-old\n+new\n keep"
      # Until the daemon puts the fields on the wire the struct carries them as extra keys.
      tool = Map.merge(item.tool, %{hunk: hunk, diff_lines: 40})
      state = put_in(state.read_model.transcript[id], %{item | text: "Edited", tool: tool})
      {rows, _scene, _table, _plan} = screen(state)

      edit = find(rows, ~r/edit +lib\/tickets\/guard\.ex/)
      assert Enum.at(rows, edit + 1) =~ ~r/^ +@@ -3,2 \+3,2 @@/
      assert Enum.at(rows, edit + 2) =~ ~r/^ +-old$/
      assert Enum.at(rows, edit + 5) =~ ~r/^ +… 36 more lines · Enter opens$/
    end

    test "a command that exited non-zero is a failed row with its code and last line" do
      {rows, _scene, _table, _plan} = scene(:trouble, {120, 60}) |> screen()

      row = Enum.find(rows, &(&1 =~ "mix test test/tickets"))
      assert row =~ "11 tests, 1 failure"
      assert row =~ ~r/exit 2 +6\.2s$/
      assert row =~ ~r/^ +✕ run/
    end

    test "a command handed to the background says so" do
      {rows, _scene, _table, _plan} = scene(:trouble, {120, 60}) |> screen()
      assert Enum.find(rows, &(&1 =~ "mix phx.server")) =~ ~r/background +10s$/
    end

    test "a rate-limited turn says why it stopped and when it retries" do
      {rows, _scene, _table, _plan} = scene(:trouble, {120, 60}) |> screen()

      header = find(rows, ~r/Assistant .* failed +rate limit +4\.0s/)
      assert header

      assert find(rows, ~r/Failed · 429 Too Many Requests/)
      assert find(rows, ~r/retrying in 42s · llmotions/)
    end

    test "once the retry time has passed the card says what to do instead" do
      state = scene(:trouble, {120, 60})
      state = %{state | now: state.now + 60_000}
      {rows, _scene, _table, _plan} = screen(state)

      assert find(rows, ~r/rate limited by llmotions · retry in a moment · \/model to switch/)
    end

    test "ASCII terminals get a hyphen, not a minus sign" do
      {rows, _scene, _table, _plan} = scene(:trouble, {120, 60}, ascii: true) |> screen()
      assert Enum.find(rows, &(&1 =~ ~r/edit +lib\/tickets\/guard\.ex/)) =~ "+5 -1"
    end
  end

  describe "the chrome" do
    test "an untrusted project gets one banner row with the command that trusts it" do
      {rows, _scene, _table, _plan} = scene(:trouble, {120, 40}) |> screen()

      assert Enum.count(rows, &(&1 =~ "This project is not trusted")) == 1
      assert Enum.find(rows, &(&1 =~ "not trusted")) =~ "/trust trusts it."
    end

    test "a trusted project has no banner" do
      {rows, _scene, _table, _plan} = scene(:first_reply, {120, 40}) |> screen()
      refute Enum.any?(rows, &(&1 =~ "not trusted"))
    end

    test "the status row counts down a provider's rate limit and keeps the hints" do
      {rows, _scene, _table, _plan} = scene(:trouble, {120, 40}) |> screen()
      status = List.last(rows)

      assert status =~ "Build · read-only · untrusted"
      assert status =~ "llmotions limited · 42s"
      # pass73 T6: no turn streams and the composer is empty, so neither
      # Esc nor Enter is hinted; the keys that work now are.
      assert status =~ ~r/Ctrl-P palette +Ctrl-F hints$/
      refute status =~ "Esc"
      refute status =~ "Enter"
    end

    test "on a wide row the background command and the spend are there too" do
      {rows, _scene, _table, _plan} = scene(:trouble, {200, 40}) |> screen()
      status = List.last(rows)

      assert status =~ "bg mix phx.server"
      assert status =~ "$0.04"
      assert status =~ "ctx"
    end

    test "a short row drops the least useful facts whole, never mid-word" do
      {rows, _scene, _table, _plan} = scene(:trouble, {90, 30}) |> screen()
      status = List.last(rows)

      assert status =~ "Build"
      assert status =~ "llmotions limited · 42s"
      refute status =~ "bg mix"
      refute status =~ "…"
    end

    test "a window that is nearly spent is a warning, without a countdown" do
      state = scene(:trouble, {120, 40})

      limit = %DTO.RateLimit{provider_id: "p1", provider: "llmotions", used_percent: 86.4}
      state = put_in(state.read_model.snapshots.shell.rate_limits, [limit])
      {rows, _scene, _table, _plan} = screen(state)

      assert List.last(rows) =~ "llmotions 86%"
    end

    test "the daemon's newest toast shows for a few seconds, in words" do
      state = scene(:first_reply, {120, 40})

      toast = %DTO.Toast{
        id: "t1",
        level: :success,
        title: "Run finished",
        text: "Rename the ticket guard",
        at: state.now - 1_000
      }

      fresh = %{state | read_model: Map.put(state.read_model, :toasts, [toast])}
      {rows, _scene, _table, _plan} = screen(fresh)
      assert List.last(rows) =~ "Run finished · Rename the ticket guard"

      stale = %{fresh | now: state.now + 30_000}
      {rows, _scene, _table, _plan} = screen(stale)
      refute List.last(rows) =~ "Run finished"
    end
  end

  describe "diffs" do
    test "the newest edit's diff is a keyboard action, and the ledger row opens it" do
      state = scene(:trouble, {160, 45})
      {_scene, table} = Projector.project(state)

      targets = Enum.map(table, &elem(&1, 1))
      assert {:local, {:open_detail, "demo-run-2", "demo-run-2-node-4:diff"}} in targets
    end

    test "a diff detail is titled Diff and its lines carry the diff colours" do
      state = scene(:trouble, {120, 40})
      ref = "demo-run-2-node-4:diff"
      text = "@@ -1,2 +1,2 @@\n-old line\n+new line\n context"

      detail = %{
        status: :idle,
        history: [],
        window: %{text: text, offset: 0, next_offset: nil}
      }

      state = %{state | layers: [{:detail, "demo-run-2", ref}], detail: detail, focus: "dialog"}
      {rows, scene, _table, plan} = screen(state)

      assert SwarmCodeCLI.UI.SafeText.value(scene.overlay.title) =~ "Diff"
      old = find(rows, ~r/-old line/)
      new = find(rows, ~r/\+new line/)
      assert old && new

      old_x = rows |> Enum.at(old) |> :binary.match("-old") |> elem(0)
      new_x = rows |> Enum.at(new) |> :binary.match("+new") |> elem(0)
      assert foreground(plan, old_x, old) != foreground(plan, new_x, new)
    end
  end
end
