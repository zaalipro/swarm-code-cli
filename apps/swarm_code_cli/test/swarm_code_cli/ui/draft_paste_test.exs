defmodule SwarmCodeCLI.UI.DraftPasteTest do
  @moduledoc """
  cli020 D8 (ux-live-16, decision 4e): a large paste collapses to one
  placeholder; send expands it; a deleted placeholder sends nothing.
  """
  use ExUnit.Case, async: false

  import SwarmCodeCLI.UI.Pass73Helpers

  alias SwarmCodeCLI.UI.{Drafts, Editor, Input, Reducer}
  alias SwarmCodeCLI.UI.Draft.Pastes
  alias SwarmCodeCLI.UI.DataSource.DTO

  defp sixty, do: Enum.map_join(1..60, "\n", &"line #{&1}")
  defp pastes(state), do: Drafts.fetch(state.drafts, key()).pastes
  defp bracketed(state, text), do: press(state, Input.paste(text)) |> elem(0)

  defp assert_refusal(before, after_state, words) do
    assert after_state.notice == {:command_feedback, words}

    assert Map.drop(Map.from_struct(after_state), [:notice, :notice_at, :revision]) ==
             Map.drop(Map.from_struct(before), [:notice, :notice_at, :revision])
  end

  defp replace_fixture(state, text) do
    draft = Drafts.fetch(state.drafts, key())
    {:ok, editor} = Editor.apply(draft.editor, :select_all)
    {:ok, editor} = Editor.apply(editor, {:paste, text})
    %{state | drafts: Drafts.put(state.drafts, %{draft | editor: editor})}
  end

  test "a 60-line paste becomes one placeholder and keeps its text" do
    state = ready() |> type("see ") |> bracketed(sixty())
    assert text(state) == "see [Pasted text #1 · 60 lines]"
    assert pastes(state) == %{1 => sixty()}
  end

  test "send expands every placeholder still present" do
    state = ready() |> type("see ") |> bracketed(sixty()) |> type(" ok")
    {_state, effects} = send(state)
    assert [%{kind: {:dispatch, :send, sent, :main, []}}] = requests(effects)
    assert sent == "see " <> sixty() <> " ok"
  end

  test "Backspace after the placeholder deletes all of it, and nothing is sent of it" do
    state = ready() |> type("a ") |> bracketed(sixty())
    {state, _} = press(state, Input.key(:backspace))
    assert text(state) == "a "
    assert pastes(state) == %{1 => sixty()}
    state = type(state, "b")
    {_state, effects} = send(state)
    assert [%{kind: {:dispatch, :send, "a b", :main, []}}] = requests(effects)
  end

  test "an edited placeholder is sent as typed" do
    state = ready() |> bracketed(sixty())
    {state, _} = press(state, Input.key(:left))
    {state, _} = press(state, Input.key(:backspace))
    {_state, effects} = send(state)

    assert [%{kind: {:dispatch, :send, "[Pasted text #1 · 60 line]", :main, []}}] =
             requests(effects)
  end

  test "small pastes stay inline; 0 lines never collapses; over 4 KiB always does" do
    assert text(ready() |> bracketed("one\ntwo")) == "one\ntwo"
    refute Pastes.collapse?(sixty(), 0)
    assert Pastes.collapse?(String.duplicate("x", 4_097), 8)
    state = %{ready() | paste_collapse_lines: 100} |> bracketed(sixty())
    assert text(state) == sixty()
  end

  test "Ctrl-Z after deleting the placeholder brings it back with its text" do
    state = ready() |> bracketed(sixty())
    {state, _} = Reducer.update(state, {:editor, key(), :select_all})
    {state, _} = Reducer.update(state, {:editor, key(), :delete_backward})
    {state, _} = Reducer.update(state, {:editor, key(), :undo})
    assert text(state) == "[Pasted text #1 · 60 lines]"
    {_state, effects} = send(state)
    assert [%{kind: {:dispatch, :send, sent, :main, []}}] = requests(effects)
    assert sent == sixty()
  end

  test "over 256 KiB after expansion is refused" do
    big = String.duplicate("x\n", 70_000)
    state = ready() |> bracketed(big) |> bracketed(big)
    {state, effects} = send(state)
    assert requests(effects) == []
    assert state.notice == {:command_feedback, "The message is over 256 KiB."}
  end

  test "references and admission retain only exact original markers" do
    marker = Pastes.placeholder(1, 2)

    assert Pastes.references(marker <> " " <> marker <> "x", %{1 => "a\nb", 2 => "other"}) ==
             MapSet.new([1])

    assert {:ok, "[Pasted text #1 · 2 lines]", %{1 => "a\nb"} = admitted} =
             Pastes.admit(%{}, "a\nb")

    assert admitted == %{1 => "a\nb"}
  end

  test "expanded bytes are counted before opaque materialization" do
    payload = String.duplicate("x", 262_144)
    marker = Pastes.placeholder(1, 1)
    assert Pastes.expanded_bytes(String.duplicate("x", 262_144), %{}) == {:ok, 262_144}
    assert Pastes.expanded_bytes(String.duplicate("x", 262_145), %{}) == {:error, :too_large}
    assert Pastes.expanded_bytes(marker, %{1 => payload}) == {:ok, 262_144}
    assert Pastes.expanded_bytes(marker <> marker, %{1 => payload}) == {:error, :too_large}
    assert Pastes.expand(marker <> marker, %{1 => payload}) == {:error, :too_large}
    assert Pastes.expand(marker <> " " <> marker, %{1 => "[$1]"}) == {:ok, "[$1] [$1]"}
  end

  test "external replacement preserves marker payload for undo" do
    state = ready() |> bracketed(sixty())
    {state, _} = Reducer.update(state, {:external_edit_done, key(), {:ok, "replacement"}})
    {state, _} = Reducer.update(state, {:editor, key(), :undo})
    assert text(state) == "[Pasted text #1 · 60 lines]"
    {_state, effects} = send(state)
    assert [%{kind: {:dispatch, :send, sent, :main, []}}] = requests(effects)
    assert sent == sixty()
  end

  test "65th retained paste preserves the entire state except its notice" do
    state = Enum.reduce(1..64, ready(), fn _, state -> bracketed(state, sixty()) end)
    {next, effects} = Reducer.update(state, {:editor, key(), {:paste, sixty()}})
    assert effects == []
    assert_refusal(state, next, "Paste limit reached; send or remove an existing paste first.")
  end

  test "external handoff and return refuse repeated markers atomically" do
    state = ready() |> bracketed(String.duplicate("x", 262_144))
    marker = text(state)
    state = replace_fixture(state, String.duplicate(marker, 8192))
    assert byte_size(text(state)) < 262_144
    {next, effects} = Reducer.update(state, {:external_editor, key()})
    assert effects == []
    assert_refusal(state, next, "The message is over 256 KiB.")
    suspended = %{state | lifecycle: :suspend_requested}
    {next, effects} = Reducer.update(suspended, {:external_edit_done, key(), {:ok, "changed"}})
    assert effects == []
    assert_refusal(state, next, "The message is over 256 KiB.")
  end

  test "count and refusal never materialize and admitted expansion materializes once" do
    payload = String.duplicate("x", 262_144)
    marker = "[Pasted text #1 · 1 line]"
    repeated = String.duplicate(marker, 8192)
    parent = self()

    worker =
      spawn_link(fn ->
        receive do
          :go ->
            result = {
              Pastes.expanded_bytes(repeated, %{1 => payload}),
              Pastes.too_large?(repeated, %{1 => payload}),
              Pastes.expand(repeated, %{1 => payload})
            }

            Kernel.send(parent, {:refused, result})
        end

        receive do
          :admit -> Kernel.send(parent, {:admitted, Pastes.expand(marker, %{1 => payload})})
        end

        receive do
          :stop -> :ok
        end
      end)

    :erlang.trace_pattern({Pastes, :materialize, 2}, true, [:local])
    :erlang.trace(worker, true, [:call, {:tracer, self()}])

    try do
      Kernel.send(worker, :go)
      assert_receive {:refused, {{:error, :too_large}, true, {:error, :too_large}}}
      barrier = :erlang.trace_delivered(worker)
      assert_receive {:trace_delivered, ^worker, ^barrier}
      refute_receive {:trace, ^worker, :call, _}
      Kernel.send(worker, :admit)
      assert_receive {:admitted, {:ok, ^payload}}
      barrier = :erlang.trace_delivered(worker)
      assert_receive {:trace_delivered, ^worker, ^barrier}
      assert_receive {:trace, ^worker, :call, {Pastes, :materialize, _}}
      refute_receive {:trace, ^worker, :call, _}
    after
      :erlang.trace(worker, false, [:call])
      :erlang.trace_pattern({Pastes, :materialize, 2}, false, [:local])
      Kernel.send(worker, :stop)
    end
  end

  test "send reuses admitted expansion and preflights a distinct resolver context" do
    state = ready() |> bracketed(sixty())
    count = materializations(fn -> send(state) end)
    assert count == 1

    large = ready() |> bracketed(String.duplicate("x", 262_144))
    marker = text(large)
    large = replace_fixture(large, marker <> marker)

    count =
      materializations(fn ->
        {next, effects} =
          Reducer.update(large, {:invoke, {:dispatch, :send, "short", :main, []}, "refused"})

        assert effects == []
        assert_refusal(large, next, "The message is over 256 KiB.")
      end)

    assert count == 0
  end

  test "exact duplicate Unicode markers expand but payload marker bytes stay opaque" do
    first = "[Pasted text #1 · 1 line]"
    second = "[Pasted text #2 · 1 line]"
    map = %{1 => "界" <> second, 2 => "é"}
    input = first <> first <> second <> "[Pasted text #1 · 2 lines]"
    expected = "界" <> second <> "界" <> second <> "é[Pasted text #1 · 2 lines]"
    assert Pastes.expand(input, map) == {:ok, expected}
    assert Pastes.expanded_bytes(input, map) == {:ok, byte_size(expected)}
    refute Pastes.too_large?(input, map)
    assert Pastes.expand(String.duplicate("x", 262_145), %{}) == {:error, :too_large}

    assert Pastes.expand(first <> "x", %{1 => String.duplicate("x", 262_144)}) ==
             {:error, :too_large}
  end

  test "Backspace and Delete restore payload through repeated undo and redo" do
    for operation <- [:delete_backward, :delete_forward] do
      state = ready() |> bracketed(sixty())

      state =
        if operation == :delete_forward,
          do: elem(Reducer.update(state, {:editor, key(), {:move, :buffer_start}}), 0),
          else: state

      {deleted, _} = Reducer.update(state, {:editor, key(), operation})
      assert text(deleted) == ""
      assert pastes(deleted) == %{1 => sixty()}
      {restored, _} = Reducer.update(deleted, {:editor, key(), :undo})
      {_sent, effects} = send(restored)
      assert [%{kind: {:dispatch, :send, sent, :main, []}}] = requests(effects)
      assert sent == sixty()
      {deleted, _} = Reducer.update(restored, {:editor, key(), :redo})
      assert text(deleted) == ""
      {restored, _} = Reducer.update(deleted, {:editor, key(), {:times, 1, :undo}})
      assert text(restored) == "[Pasted text #1 · 60 lines]"
    end
  end

  test "one-character marker edit retains the complete before buffer for undo" do
    state = ready() |> bracketed(sixty())
    {state, _} = Reducer.update(state, {:editor, key(), {:move, :left}})
    {state, _} = Reducer.update(state, {:editor, key(), :delete_backward})
    {state, _} = Reducer.update(state, {:editor, key(), :undo})
    {_state, effects} = send(state)
    assert [%{kind: {:dispatch, :send, sent, :main, []}}] = requests(effects)
    assert sent == sixty()
  end

  test "history and register references survive eviction then release their payload" do
    state = ready() |> bracketed(sixty())
    {state, _} = Reducer.update(state, {:editor, key(), :select_all})
    {state, _} = Reducer.update(state, {:editor, key(), {:delete, :selection}})
    assert text(state) == ""

    state =
      Enum.reduce(1..105, state, fn _, state ->
        {state, _} = Reducer.update(state, {:editor, key(), {:paste, "x"}})
        {state, _} = Reducer.update(state, {:editor, key(), :select_all})
        elem(Reducer.update(state, {:editor, key(), :delete_backward}), 0)
      end)

    assert pastes(state) == %{1 => sixty()}
    assert Editor.retained_tags(Drafts.fetch(state.drafts, key()).editor) == MapSet.new()
    retained = state
    {state, _} = Reducer.update(state, {:editor, key(), :put_before})
    assert text(state) == "[Pasted text #1 · 60 lines]"
    {_sent, effects} = send(state)
    assert [%{kind: {:dispatch, :send, sent, :main, []}}] = requests(effects)
    assert sent == sixty()

    # Reset drops text, history and register together.
    draft = Drafts.fetch(state.drafts, key())
    cleared = SwarmCodeCLI.UI.Draft.clear(draft)
    assert cleared.pastes == %{}
    assert Editor.register(cleared.editor) == nil
    assert Editor.retained_tags(cleared.editor) == MapSet.new()

    # Overwriting the register releases its last reference without resetting history.
    {retained, _} = Reducer.update(retained, {:editor, key(), {:paste, "other"}})
    {retained, _} = Reducer.update(retained, {:editor, key(), :select_all})
    {retained, _} = Reducer.update(retained, {:editor, key(), {:yank, :selection}})
    assert pastes(retained) == %{}
  end

  test "history-only capacity releases a slot after the last record expires" do
    state = Enum.reduce(1..64, ready(), fn _, state -> bracketed(state, sixty()) end)
    {state, _} = Reducer.update(state, {:editor, key(), :select_all})
    {state, _} = Reducer.update(state, {:editor, key(), :delete_backward})
    {next, effects} = Reducer.update(state, {:editor, key(), {:paste, sixty()}})
    assert effects == []
    assert_refusal(state, next, "Paste limit reached; send or remove an existing paste first.")

    state =
      Enum.reduce(1..105, state, fn _, state ->
        {state, _} = Reducer.update(state, {:editor, key(), {:paste, "x"}})
        {state, _} = Reducer.update(state, {:editor, key(), :select_all})
        elem(Reducer.update(state, {:editor, key(), :delete_backward}), 0)
      end)

    assert pastes(state) == %{}
    {state, _} = Reducer.update(state, {:editor, key(), {:paste, sixty()}})
    assert pastes(state) == %{1 => sixty()}
  end

  test "failed editor admission does not store the candidate payload" do
    state = ready() |> replace_fixture(String.duplicate("x", 262_144))
    {next, effects} = Reducer.update(state, {:editor, key(), {:paste, sixty()}})
    assert effects == []
    assert next.notice == {:editor_error, :text_too_large}
    assert next.drafts == state.drafts
    assert next.timers == state.timers
    assert next.history_cursor == state.history_cursor
  end

  test "send queue main steer and agent steer refuse repeated markers before requests" do
    base = ready([run("r", :streaming)]) |> bracketed(String.duplicate("x", 262_144))
    repeated = String.duplicate(text(base), 8192)
    base = replace_fixture(base, repeated)

    node = %DTO.TranscriptItem{
      id: "item",
      node_id: "node",
      run_id: "r",
      conversation_id: "c",
      state: :streaming,
      role: :assistant,
      attempt_id: "attempt",
      text: ""
    }

    agent = %DTO.AgentSummary{id: "agent", run_id: "r", state: :running}

    base = %{
      base
      | read_model: %{
          base.read_model
          | transcript: %{"item" => node},
            agents: %{"agent" => agent}
        }
    }

    for intent <- [
          {:dispatch, :send, repeated, :main, []},
          {:dispatch, :queue, repeated, :main, []},
          {:steer, "r", "node", repeated, []}
        ] do
      assert materializations(fn ->
               {next, effects} = Reducer.update(base, {:invoke, intent, "refused"})
               assert effects == []
               assert_refusal(base, next, "The message is over 256 KiB.")
             end) == 0
    end

    agent_key = {"c", {:agent, "agent"}}
    draft = %{Drafts.fetch(base.drafts, key()) | key: agent_key}
    overlay = %{run_id: "r", node_id: "agent", draft_key: agent_key}
    state = %{base | drafts: Drafts.put(base.drafts, draft), overlay: overlay}

    assert materializations(fn ->
             {next, effects} =
               Reducer.update(state, {:invoke, {:steer, "r", "agent", repeated, []}, "refused"})

             assert effects == []
             assert_refusal(state, next, "The message is over 256 KiB.")
           end) == 0
  end

  test "bounded duplicate markers expand for send steer and external editing" do
    state = ready([run("r", :streaming)]) |> bracketed(sixty())
    state = type(state, text(state))
    assert text(state) == "[Pasted text #1 · 60 lines][Pasted text #1 · 60 lines]"
    expected = sixty() <> sixty()
    {_sent, effects} = send(state)
    assert [%{kind: {:dispatch, :send, ^expected, :main, []}}] = requests(effects)
    {suspended, effects} = Reducer.update(state, {:external_editor, key()})
    assert effects == [{:edit_externally, key(), expected}]
    {returned, effects} = Reducer.update(suspended, {:external_edit_done, key(), {:ok, expected}})
    assert effects == []
    assert returned.drafts == state.drafts

    node = %DTO.TranscriptItem{
      id: "item",
      node_id: "node",
      run_id: "r",
      conversation_id: "c",
      state: :streaming,
      role: :assistant,
      attempt_id: "attempt",
      text: ""
    }

    state = %{state | read_model: %{state.read_model | transcript: %{"item" => node}}}

    {_sent, effects} =
      Reducer.update(state, {:invoke, {:steer, "r", "node", text(state), []}, "steer"})

    assert [%{kind: {:steer, "r", "node", ^expected, []}}] = requests(effects)
    agent = %DTO.AgentSummary{id: "agent", run_id: "r", state: :running}
    agent_key = {"c", {:agent, "agent"}}
    draft = %{Drafts.fetch(state.drafts, key()) | key: agent_key}

    state = %{
      state
      | drafts: Drafts.put(state.drafts, draft),
        overlay: %{run_id: "r", node_id: "agent", draft_key: agent_key},
        read_model: %{state.read_model | agents: %{"agent" => agent}}
    }

    {_sent, effects} =
      Reducer.update(state, {:invoke, {:steer, "r", "agent", text(state), []}, "steer"})

    assert [%{kind: {:steer, "r", "agent", ^expected, []}}] = requests(effects)
  end

  test "/queue Enter refuses 262145 expanded bytes without changing the draft or effects" do
    state = ready() |> bracketed(String.duplicate("x", 262_144))
    state = replace_fixture(state, "/queue " <> text(state) <> "x")
    {state, _} = Reducer.update(state, {:editor, key(), :select_all})

    assert materializations(fn ->
             {next, effects} = send(state)
             assert effects == []
             assert_refusal(state, next, "The message is over 256 KiB.")
           end) == 0
  end

  test "/queue Enter admits 262144 expanded bytes and strips only the command prefix" do
    payload = String.duplicate("x\n", 131_072)
    state = ready() |> bracketed(payload)
    marker = text(state)
    state = replace_fixture(state, "  /queue   " <> marker)

    assert materializations(fn ->
             {next, effects} = send(state)
             assert [%{kind: {:dispatch, :queue, ^payload, :main, []}}] = requests(effects)
             assert text(next) == marker
             assert next.steers == state.steers
           end) == 1
  end

  test "overlay Enter repeatedly refuses 262145 bytes without evicting 50 existing steers" do
    state = overlay_fixture(String.duplicate("x\n", 131_072), "x")

    assert materializations(fn ->
             Enum.reduce(1..3, state, fn _, before ->
               {next, effects} = press(before, Input.key(:enter))
               assert effects == []
               assert_refusal(before, next, "The message is over 256 KiB.")
               assert next.steers == state.steers
               next
             end)
           end) == 0
  end

  test "overlay Enter admits 262144 bytes and records exactly one steer after admission" do
    payload = String.duplicate("x", 262_144)
    state = overlay_fixture(payload)
    marker = Editor.text(Drafts.fetch(state.drafts, state.overlay.draft_key).editor)

    assert materializations(fn ->
             {next, effects} = press(state, Input.key(:enter))
             assert [%{kind: {:steer, "r", "agent", ^payload, []}}] = requests(effects)

             assert next.steers ==
                      Enum.take([{"r", marker, "agent", "Worker"} | state.steers], 50)

             assert Editor.text(Drafts.fetch(next.drafts, state.overlay.draft_key).editor) ==
                      marker

             assert text(next) == text(state)
           end) == 1
  end

  defp overlay_fixture(payload, suffix \\ "") do
    state = ready([run("r", :streaming)]) |> bracketed(payload)
    state = replace_fixture(state, text(state) <> suffix)
    {state, _} = Reducer.update(state, {:editor, key(), :select_all})
    agent_key = {"c", {:agent, "agent"}}
    draft = %{Drafts.fetch(state.drafts, key()) | key: agent_key}
    agent = %DTO.AgentSummary{id: "agent", run_id: "r", state: :running, name: "Worker"}

    %{
      state
      | drafts: Drafts.put(state.drafts, draft),
        overlay: %{run_id: "r", node_id: "agent", draft_key: agent_key, focus: :composer},
        read_model: %{state.read_model | agents: %{"agent" => agent}},
        steers: Enum.map(1..50, &{"r", "existing #{&1}", "agent", "Worker"})
    }
  end

  defp materializations(fun) do
    parent = self()

    worker =
      spawn_link(fn ->
        receive do
          :go -> Kernel.send(parent, {:trace_result, fun.()})
        end

        receive do
          :stop -> :ok
        end
      end)

    :erlang.trace_pattern({Pastes, :materialize, 2}, true, [:local])
    :erlang.trace(worker, true, [:call, {:tracer, self()}])

    try do
      Kernel.send(worker, :go)
      assert_receive {:trace_result, _}, 2000
      barrier = :erlang.trace_delivered(worker)
      assert_receive {:trace_delivered, ^worker, ^barrier}
      drain_materializations(worker, 0)
    after
      :erlang.trace(worker, false, [:call])
      :erlang.trace_pattern({Pastes, :materialize, 2}, false, [:local])
      Kernel.send(worker, :stop)
    end
  end

  defp drain_materializations(worker, count) do
    receive do
      {:trace, ^worker, :call, {Pastes, :materialize, _}} ->
        drain_materializations(worker, count + 1)
    after
      0 -> count
    end
  end
end
