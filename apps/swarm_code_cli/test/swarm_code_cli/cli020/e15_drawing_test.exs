defmodule SwarmCodeCLI.Cli020.E15DrawingTest do
  # cli020 E15 (decisions 4c, 4e, 4h, 4i): drawing the new features. The
  # composer's `$ shell` chip, paste placeholders and image chips; the `:shell`
  # transcript item; the rewind list and its confirm; history search; the
  # queue list.
  use ExUnit.Case, async: true

  import SwarmCodeCLI.Cli020EHelpers

  alias SwarmCodeCLI.Test.Pass73Scenes
  alias SwarmCodeCLI.UI.{Drafts, SafeText, State, Theme}
  alias SwarmCodeCLI.UI.Draft.AttachmentRef
  alias SwarmCodeCLI.UI.Pass73Helpers, as: H

  defp chat do
    state = H.ready([%{H.run("s", :done) | created_sequence: 1}], columns: 110, rows: 30)
    %{state | capabilities: %{state.capabilities | color_mode: :truecolor}}
  end

  # --- the composer ---------------------------------------------------------------------

  test "a ! draft puts a $ shell chip on the composer's rule" do
    text = chat() |> Pass73Scenes.put_draft("!mix test --failed") |> screen_text()
    assert text =~ "$ shell"
    refute chat() |> Pass73Scenes.put_draft("! ") |> screen_text() =~ "$ shell"
    refute chat() |> Pass73Scenes.put_draft("mix test") |> screen_text() =~ "$ shell"
  end

  test "a paste placeholder is drawn dim, as one chip" do
    state = chat() |> Pass73Scenes.put_draft("fix [Pasted text #1 · 60 lines] now")
    assert screen_text(state) =~ "[Pasted text #1 · 60 lines]"
    {x, y} = locate(state, "[Pasted text #1")
    faint = Theme.style(:text_faint, state.capabilities).foreground.value
    assert cell_style(plan(state), x, y).foreground == faint
    {x2, _} = locate(state, "now")
    refute cell_style(plan(state), x2, y).foreground == faint
  end

  test "a staged image is a chip with its size" do
    state = chat()
    key = State.current_draft_key(state)
    draft = Drafts.fetch(state.drafts, key)

    image =
      AttachmentRef.new!(
        id: "att-1",
        name: elem(SafeText.external("shot.png", SafeText.Limits.content()), 1),
        media_type: "image/png",
        byte_size: 412 * 1024,
        status: :ready,
        reference: "ref-1"
      )

    state = %{state | drafts: Drafts.put(state.drafts, %{draft | attachments: [image]})}
    assert screen_text(state) =~ "[Image #1 · 412 KB]"
  end

  # --- the transcript -------------------------------------------------------------------

  defp with_shell(fields) do
    shell =
      item(
        "sh",
        Keyword.merge([kind: :shell, run_id: "shell-1", node_id: "sh", role: :assistant], fields)
      )

    state = chat()

    put_in(state.read_model.transcript["sh"], shell)
    |> then(
      &put_in(
        &1.read_model.order[:workspace],
        Map.get(&1.read_model.order, :workspace, []) ++ ["sh"]
      )
    )
  end

  test "a finished shell command: $ command, its output, exit 0 muted" do
    text =
      with_shell(text: "$ echo hi\nhi\n[exit 0]", state: :done)
      |> Map.put(:exit, 0)
      |> screen_text()

    assert text =~ "$ echo hi"
    assert text =~ "exit 0"
    assert text =~ ~r/^\s+hi$/m
    refute text =~ "[exit 0]"
  end

  test "a failing command says its exit in the error colour" do
    state = with_shell(text: "$ false\n[exit 1]", state: :done)
    assert screen_text(state) =~ "exit 1"
    {x, y} = locate(state, "exit 1")

    assert cell_style(plan(state), x, y).foreground ==
             Theme.style(:error, state.capabilities).foreground.value
  end

  test "a running command says so" do
    text = with_shell(text: "$ sleep 30", state: :running) |> screen_text()
    assert text =~ "$ sleep 30"
    assert text =~ "running…"
  end

  test "a stopped command" do
    assert with_shell(text: "$ sleep 30\n[exit stopped]", state: :stopped) |> screen_text() =~
             "stopped"
  end

  # --- layers ---------------------------------------------------------------------------

  defp layer(state, layer), do: %{state | layers: [layer], focus: "dialog"}

  @turns [
    %{
      message_id: "m3",
      position: 3,
      turn: 7,
      prompt: "Add the retry test",
      at: 1_789_000_000_000 - 2 * 3_600_000,
      run_id: "r7",
      files: 3
    },
    %{
      message_id: "m2",
      position: 2,
      turn: 6,
      prompt: "Read the router",
      at: 1_789_000_000_000 - 3 * 3_600_000,
      run_id: "r6",
      files: 0
    }
  ]

  test "the rewind list: Turn 7 · prompt · 3 files · 2 h ago" do
    state =
      chat()
      |> Map.put(:now, 1_789_000_000_000)
      |> layer({:rewind, %{turns: @turns, selected: 0}})

    text = screen_text(state)
    assert text =~ "Rewind"
    assert text =~ "Turn 7 · Add the retry test · 3 files · 2 h ago"
    assert text =~ "Turn 6 · Read the router · 3 h ago"
  end

  test "an empty rewind list" do
    assert chat() |> layer({:rewind, %{turns: [], selected: 0}}) |> screen_text() =~
             "Nothing to rewind yet."
  end

  test "the rewind confirm: three choices and the fold sentence" do
    text = chat() |> layer({:rewind_confirm, hd(@turns)}) |> screen_text()
    assert text =~ "Conversation and files"
    assert text =~ "Conversation only"
    assert text =~ "Files only"
    # The sentence word-wraps inside the dialog: read the box's rows as prose.
    prose =
      text
      |> String.split("\n")
      |> Enum.flat_map(&(Regex.run(~r/│(.*)│/u, &1, capture: :all_but_first) || []))
      |> Enum.map_join(" ", &String.trim/1)
      |> String.replace(~r/\s+/u, " ")

    assert prose =~
             "Later turns are folded (kept, not deleted); files come back from checkpoints."
  end

  test "history search: the query and the matching prompts" do
    rows = [%{text: "Run the test suite", conversation_id: "c", at: 1, detail_ref: nil}]

    text =
      chat()
      |> layer({:history_search, %{query: "test", rows: rows, selected: 0}})
      |> screen_text()

    assert text =~ "History"
    assert text =~ "test"
    assert text =~ "Run the test suite"

    assert chat()
           |> layer({:history_search, %{query: "zz", rows: [], selected: 0}})
           |> screen_text() =~ "No earlier prompt matches"
  end

  test "the queue list numbers what waits" do
    state =
      chat()
      |> put_workspace(queued_texts: ["first thing", "second thing"], queued_count: 2)
      |> layer({:queue_list})

    text = screen_text(state)
    assert text =~ "Queue"
    assert text =~ ~r/1\s+first thing/
    assert text =~ ~r/2\s+second thing/
    assert chat() |> layer({:queue_list}) |> screen_text() =~ "Nothing queued."
  end
end
