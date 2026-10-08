defmodule SwarmCodeCLI.UI.FixRoundUTest do
  @moduledoc """
  cli020 fix round, lane U (U5 to U8): the list dialogs size to their rows
  and count only what a cursor can sit on, the queue list has a cursor whose
  Enter takes a message back into the composer, the resume title has no
  stray colon, Alt-Left goes back from an empty composer, and the queued
  rows of a drained queue leave a run view. Each is checked at 80x24 and
  160x48 as well as the default size. (U1 to U4 are in the d6, d18, tabline
  and e9 tests.)
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.Cli020EHelpers, only: [screen_text: 1, put_workspace: 2]
  import SwarmCodeCLI.UI.Pass73Helpers

  alias SwarmCodeCLI.UI.{Editor, FieldEditors, Input, Keymap, Reducer, Switcher}
  alias SwarmCodeCLI.UI.DataSource.DTO

  @sizes [{80, 24}, {120, 36}, {160, 48}]
  @now 1_789_000_000_000

  defp chat({columns, rows}, extra \\ %{}) do
    state =
      ready([%{run("s", :done) | created_sequence: 1}],
        columns: columns,
        rows: rows,
        snapshot: extra
      )

    %{state | now: @now, capabilities: %{state.capabilities | color_mode: :truecolor}}
  end

  defp layer(state, layer), do: %{state | layers: [layer], focus: "dialog"}

  # The rows of the drawn box, from its top edge to its bottom edge.
  defp box(text) do
    rows = String.split(text, "\n")
    top = Enum.find_index(rows, &(&1 =~ "┌"))
    bottom = Enum.find_index(rows, &(&1 =~ "└"))
    assert top && bottom, text
    Enum.slice(rows, top..bottom)
  end

  @turns for n <- 1..3,
             do: %{
               message_id: "m#{n}",
               position: n,
               turn: n,
               prompt: "prompt #{n}",
               at: @now - n * 3_600_000,
               run_id: "r#{n}",
               files: n
             }

  describe "U5: the rewind list" do
    test "is as tall as its turns and counts only the turns" do
      for size <- @sizes do
        text = size |> chat() |> layer({:rewind, %{turns: @turns, selected: 0}}) |> screen_text()
        rows = box(text)
        # 3 turns, the count line, Cancel and the two borders.
        assert length(rows) <= 3 + 4, "#{inspect(size)}\n#{text}"
        assert text =~ "1 of 3 · ↑↓ choose · Enter rewinds to it · Esc closes", text
        refute text =~ "of 4"
      end
    end

    test "the count follows the cursor" do
      text =
        chat({120, 36}) |> layer({:rewind, %{turns: @turns, selected: 2}}) |> screen_text()

      assert text =~ "3 of 3"
    end
  end

  # cli020 qa2: the rewind dialog's second step (the scope) took the whole
  # height on the release and counted its prompt and fold lines ("2 of 5").
  describe "U5: the rewind scope step" do
    test "is as tall as its rows and counts only the three scopes" do
      turn = hd(@turns)

      for size <- @sizes do
        state = size |> chat() |> layer({:rewind_confirm, turn})
        text = screen_text(%{state | focus: "both"})
        rows = box(text)
        # The prompt, three scopes, the fold note (up to two lines), the
        # count line, Cancel and the two borders.
        assert length(rows) <= 1 + 3 + 2 + 4, "#{inspect(size)}\n#{text}"
        assert text =~ "1 of 3 · Enter chooses · Esc closes", text
        refute text =~ "of 5"
      end
    end

    test "the count follows the focused scope" do
      state = chat({120, 36}) |> layer({:rewind_confirm, hd(@turns)})
      assert screen_text(%{state | focus: "files"}) =~ "3 of 3"
    end
  end

  describe "U5: history search" do
    test "the query and the empty message are not rows" do
      rows = [
        %{text: "Run the test suite", conversation_id: "c", at: 1, detail_ref: nil},
        %{text: "Run the linter", conversation_id: "c", at: 1, detail_ref: nil}
      ]

      for size <- @sizes do
        text =
          size
          |> chat()
          |> layer({:history_search, %{query: "run", rows: rows, selected: 1}})
          |> screen_text()

        assert text =~ "2 of 2 · Enter chooses · Esc closes", text
        assert length(box(text)) <= 2 + 5, text
      end
    end
  end

  describe "U5: the queue list" do
    alias SwarmCodeCLI.Test.Cli020State, as: S

    @rev "0123456789abcdef"
    @conversation S.conversation()

    # A UUID conversation (queue.edit takes only UUIDs), the queue list open.
    defp queued(size, texts \\ ["first thing", "second thing"]) do
      state =
        S.ready(snapshot: %{queued_texts: texts, queued: length(texts)})
        |> SwarmCodeCLI.Cli020EHelpers.sized(size)
        |> put_workspace(queued_count: length(texts), queue_revision: @rev)

      {state, _} = state |> S.type("/queue") |> S.send_draft()
      state
    end

    test "is as tall as its rows, has a cursor and says what Enter and d do" do
      for size <- @sizes do
        state = queued(size)
        assert [{:queue_list} | _] = state.layers
        text = screen_text(state)
        assert text =~ "1 of 2 · Enter edits · d drops · Esc closes", text
        # Two rows, their hint line, the count line, Cancel, two borders.
        assert length(box(text)) <= 2 + 1 + 2 + 2, "#{inspect(size)}\n#{text}"
        refute text =~ "Enter chooses"
      end
    end

    test "the cursor moves and the count follows it" do
      state = queued({120, 36})
      {state, []} = Reducer.update(state, {:queue_move, 1})
      assert screen_text(state) =~ "2 of 2 · Enter edits"
    end

    test "Enter takes the row into the composer through queue.edit" do
      state = queued({120, 36})
      {state, []} = Reducer.update(state, {:queue_move, 1})
      assert {:ok, {:queue_take}} = Keymap.resolve(Input.key(:enter), state, %{})
      {state, effects} = Reducer.update(state, {:queue_take})

      assert [%{kind: {:queue_edit, @conversation, @rev, {:drop, 2}}} = request] =
               requests(effects)

      # Nothing moves until the daemon has removed it from the queue.
      assert S.text(state) == ""
      assert [{:queue_list} | _] = state.layers

      {state, _} = outcome(state, request, :accepted, [])
      assert S.text(state) == "second thing"
      assert state.layers == []
      assert state.queue_take == nil
      assert {:command_feedback, "Message 2 is in the composer" <> _} = state.notice
    end

    test "a message taken into a typed draft follows it on a new line" do
      state = S.ready(snapshot: %{queued_texts: ["first thing"], queued: 1})
      state = put_workspace(state, queued_count: 1, queue_revision: @rev)
      state = S.type(state, "typed")
      state = %{state | layers: [{:queue_list}]}
      {state, effects} = Reducer.update(state, {:queue_take})
      [request] = requests(effects)
      {state, _} = outcome(state, request, :accepted, [])
      assert S.text(state) == "typed\nfirst thing"
    end

    test "a refused edit leaves the queue list and the draft alone" do
      state = queued({120, 36})
      {state, effects} = Reducer.update(state, {:queue_take})
      [request] = requests(effects)
      {state, _} = outcome(state, request, :rejected, [])
      assert S.text(state) == ""
      assert [{:queue_list} | _] = state.layers
      assert state.queue_take == nil
    end

    test "a message that may be cut at 2 KB is not taken" do
      long = String.duplicate("x", 2_040)
      state = queued({120, 36}, [long])
      {state, effects} = Reducer.update(state, {:queue_take})
      assert requests(effects) == []
      assert {:command_feedback, "That message is too long" <> _} = state.notice
    end

    test "an empty queue says so and has no cursor to act on" do
      state = %{chat({120, 36}) | layers: [{:queue_list}], focus: "dialog"}
      text = screen_text(state)
      assert text =~ "Nothing queued."
      assert text =~ "Esc closes"
      assert {_state, []} = Reducer.update(state, {:queue_take})
    end
  end

  describe "U6: the resume picker title" do
    defp resume(size) do
      state = chat(size)
      layer = {:switcher, "resume"}
      {:ok, query} = Editor.apply(Editor.new(max_bytes: 16_384), {:insert, "#"})

      items = [
        %DTO.ConversationSummary{
          id: "c1",
          title: "Fix the router",
          updated_at: @now,
          run_count: 3
        },
        %DTO.ConversationSummary{id: "c2", title: "Read the docs", updated_at: @now, run_count: 1}
      ]

      %{
        state
        | layers: [layer],
          focus: "query",
          conversations: %{items: items},
          field_editors: FieldEditors.put(state.field_editors, Switcher.field_key(layer), query)
      }
    end

    test "reads Conversations, without a colon or trailing spaces" do
      for size <- @sizes do
        text = size |> resume() |> screen_text()
        [top] = text |> String.split("\n") |> Enum.filter(&(&1 =~ "┌"))
        assert top =~ ~r/┌ Conversations ─/, top
        refute top =~ "Conversations:"
      end
    end

    test "a typed filter still follows the name" do
      state = resume({120, 36})
      {:ok, query} = Editor.apply(Editor.new(max_bytes: 16_384), {:insert, "#router"})

      state = %{
        state
        | field_editors:
            FieldEditors.put(
              state.field_editors,
              Switcher.field_key({:switcher, "resume"}),
              query
            )
      }

      assert screen_text(state) =~ "Conversations: router"
    end
  end

  describe "U7: Alt-Left from the composer" do
    test "goes back to the conversation from a run view that was opened first" do
      state = chat({120, 36})
      state = %{state | destination: {:run, "s"}}
      assert {:ok, {:navigate, {:conversation, "c"}}} = Keymap.resolve(alt_left(), state, %{})
    end

    test "goes back through the history when there is some" do
      state = chat({120, 36})
      {state, _} = Reducer.update(state, {:navigate, {:run, "s"}})
      assert state.destination == {:run, "s"}
      assert {:ok, :back} = Keymap.resolve(alt_left(), state, %{})
      {state, _} = Reducer.update(state, :back)
      assert match?({:conversation, "c"}, state.destination)
    end

    test "is a word move while a draft is typed" do
      state = chat({120, 36}) |> type("two words")
      state = %{state | destination: {:run, "s"}}

      assert {:ok, {:editor, {"c", :main}, {:move, :word_left}}} =
               Keymap.resolve(alt_left(), state, %{})
    end

    test "has nowhere to go in a conversation view with no history" do
      state = chat({120, 36})

      assert {:ok, {:editor, {"c", :main}, {:move, :word_left}}} =
               Keymap.resolve(alt_left(), state, %{})
    end

    defp alt_left, do: Input.key(:left, [:alt])
  end

  describe "U8: queued rows of a drained queue" do
    alias SwarmCodeCLI.Test.Pass73Scenes

    @waiting "queued · sends after the running turn"

    defp scene(size \\ {160, 45}), do: Pass73Scenes.screenshot_11(elem(size, 0), elem(size, 1))

    defp with_queue(state, fields) do
      workspace = Map.merge(state.read_model.snapshots.workspace, Map.new(fields))
      put_in(state.read_model.snapshots[:workspace], workspace)
    end

    defp user_item(state, text, at) do
      item =
        struct!(
          %DTO.TranscriptItem{
            id: "u-late",
            run_id: Pass73Scenes.chat_id(),
            conversation_id: "demo-panel",
            node_id: "n-late",
            revision: 1,
            role: :user,
            state: :done,
            text: text,
            reasoning: "",
            attempt_id: "a",
            created_sequence: 99_999,
            at: at
          },
          []
        )

      order = state.read_model.order.workspace ++ [item.id]

      %{
        state
        | read_model: %{
            state.read_model
            | transcript: Map.put(state.read_model.transcript, item.id, item),
              order: %{state.read_model.order | workspace: order}
          }
      }
    end

    test "the queue of this conversation is drawn, and gone once it is empty" do
      for size <- [{160, 45}, {120, 40}] do
        state = size |> scene() |> with_queue(queued_texts: ["wait for me"])
        assert screen_text(state) =~ @waiting, inspect(size)
        refute state |> with_queue(queued_texts: []) |> screen_text() =~ @waiting
      end
    end

    test "a queue another conversation owns draws nothing here" do
      state = scene() |> with_queue(queued_texts: ["stale one"], conversation_id: "other")
      refute screen_text(state) =~ "stale one"
      refute screen_text(state) =~ @waiting
    end

    test "a queued send whose text is already a sent message leaves the fallback rows" do
      delivery = %{
        id: "d1",
        conversation_id: "demo-panel",
        run_id: nil,
        text: "drained prompt",
        status: :queued,
        at: 1_788_436_800_000 - 100,
        reason: nil,
        said?: false,
        turn_id: nil,
        operation: :queue
      }

      state = scene() |> with_queue(queued_texts: nil) |> Map.put(:deliveries, [delivery])
      text = screen_text(state)
      assert text =~ "drained prompt" and text =~ @waiting

      state = user_item(state, "drained prompt", delivery.at + 50)
      refute screen_text(state) =~ @waiting
    end
  end
end
