defmodule SwarmCodeCLI.UI.Pass71SendRaceTest do
  @moduledoc """
  Pass 71 R2 and I3: an Enter typed before the workspace watch is ready is
  kept and sent once it is, and a Ctrl-C (or Esc) pressed right after Enter
  stops the turn that Enter started, even before that turn is on screen.
  Every key goes through `Keymap.resolve/3` and `Reducer.update/2`.
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{Capabilities, Drafts, Editor, Init, Input, Keymap, Reducer, Size}
  alias SwarmCodeCLI.UI.DataSource.{AdmissionError, DTO, Delivery, Delta}

  @key {"c", :main}

  defp run(id, state, opts \\ []) do
    %DTO.RunSummary{
      id: id,
      conversation_id: "c",
      state: state,
      revision: 3,
      kind: :chat,
      started_at: Keyword.get(opts, :started_at, 1),
      allowed_actions: Keyword.get(opts, :actions, [:stop, :pause])
    }
  end

  defp booting do
    size = %Size{columns: 150, rows: 40}

    {state, _} =
      Reducer.init(%Init{
        size: size,
        capabilities: %Capabilities{size: size},
        source_epoch: "e",
        destination: {:conversation, "c"},
        focus: "composer"
      })

    state
  end

  defp snapshot(runs) do
    %DTO.WorkspaceSnapshot{
      conversation_id: "c",
      allowed_actions: [:send, :queue],
      runs: runs,
      interactions: [],
      transcript: %DTO.TranscriptWindow{items: []},
      runs_page: %DTO.PageInfo{},
      interactions_page: %DTO.PageInfo{}
    }
  end

  defp watch_ready(state, runs \\ []) do
    watch = state.watches.workspace

    Reducer.update(
      state,
      {:data,
       %Delivery{
         kind: :watch_ready,
         watch_ref: watch.watch_ref,
         request_id: nil,
         scope: watch.scope,
         generation: watch.generation,
         revision: 0,
         sequence: nil,
         body: snapshot(runs)
       }}
    )
  end

  defp watch_failed(state) do
    watch = state.watches.workspace

    Reducer.update(
      state,
      {:data,
       %Delivery{
         kind: :error,
         watch_ref: watch.watch_ref,
         request_id: nil,
         scope: watch.scope,
         generation: watch.generation,
         revision: nil,
         sequence: nil,
         body: AdmissionError.new(:source_unavailable)
       }}
    )
  end

  defp ready(runs \\ []), do: booting() |> watch_ready(runs) |> elem(0)

  defp run_update(state, body) do
    watch = state.watches.workspace

    delivery = %Delivery{
      kind: :delta,
      watch_ref: watch.watch_ref,
      request_id: nil,
      scope: watch.scope,
      generation: watch.generation,
      revision: 1,
      sequence: watch.sequence + 1,
      body: %Delta{
        kind: :run_update,
        entity_id: body.id,
        run_id: body.id,
        conversation_id: "c",
        body: body,
        revision: 1,
        sequence: watch.sequence + 1
      }
    }

    Reducer.update(state, {:data, delivery})
  end

  defp outcome(state, request, status, ids) do
    Reducer.update(
      state,
      {:data,
       %Delivery{
         kind: :response,
         request_id: request.request_id,
         watch_ref: nil,
         scope: request.scope,
         generation: request.generation,
         revision: nil,
         sequence: nil,
         body: %DTO.Outcome{
           request_id: request.request_id,
           status: status,
           identifiers: ids,
           error: if(status == :accepted, do: nil, else: AdmissionError.new(:not_allowed))
         }
       }}
    )
  end

  defp press(state, input) do
    case Keymap.resolve(input, state, %{}) do
      {:ok, action} -> Reducer.update(state, action)
      :ignore -> {state, []}
    end
  end

  defp press!(state, input), do: elem(press(state, input), 0)
  defp letter(text), do: Input.text_fragment(:press, text, [])
  defp ctrl(text), do: Input.text_fragment(:press, text, [:control])
  defp text(state), do: Editor.text(Drafts.fetch(state.drafts, @key).editor)

  defp type(state, text),
    do: text |> String.graphemes() |> Enum.reduce(state, &press!(&2, letter(&1)))

  defp requests(effects), do: for({:command, request} <- effects, do: request)

  # Enter with the drawn Send target, the way the session resolves it once
  # the projector has drawn the composer.
  defp send(state) do
    {:ok, action} = Keymap.draft_send(state)
    {state, effects} = Reducer.update(state, action)
    [request] = requests(effects)
    {state, request}
  end

  describe "Enter before the workspace is ready (R2)" do
    test "is kept, said, and sent once the watch is ready" do
      state = booting() |> type("hello")
      assert state.watches.workspace.status == :frozen

      {state, effects} = press(state, Input.key(:enter))
      assert requests(effects) == []
      assert state.deferred_send == {@key, "hello"}
      assert state.notice == {:command_feedback, "Sends once the conversation has loaded."}

      {state, effects} = watch_ready(state)
      assert [%{kind: {:dispatch, :send, "hello", :main, []}}] = requests(effects)
      assert state.deferred_send == nil
    end

    test "a second Enter keeps one deferred send, the latest draft" do
      state = booting() |> type("one") |> press!(Input.key(:enter))
      state = state |> type(" two") |> press!(Input.key(:enter))
      assert state.deferred_send == {@key, "one two"}

      {_state, effects} = watch_ready(state)
      assert [%{kind: {:dispatch, :send, "one two", _, _}}] = requests(effects)
    end

    test "a draft changed after Enter is not sent, and that is said" do
      state = booting() |> type("hello") |> press!(Input.key(:enter)) |> type("!")
      {state, effects} = watch_ready(state)
      assert requests(effects) == []
      assert state.deferred_send == nil
      assert state.notice == {:command_feedback, "Not sent: the draft changed after Enter."}
      assert text(state) == "hello!"
    end

    test "a watch that fails drops it with a notice" do
      state = booting() |> type("hello") |> press!(Input.key(:enter))
      {state, effects} = watch_failed(state)
      assert requests(effects) == []
      assert state.deferred_send == nil
      assert state.notice == {:command_feedback, "Not sent: the conversation did not load."}
    end

    test "a local command typed ahead runs as the session's own" do
      state = booting() |> type("/help") |> press!(Input.key(:enter))
      {state, _} = watch_ready(state)
      assert state.layers == [:help]
    end

    test "Enter on a blank draft, or once the watch is ready, is not deferred" do
      assert booting() |> press!(Input.key(:enter)) |> Map.get(:deferred_send) == nil
      assert ready() |> type("x") |> press!(Input.key(:enter)) |> Map.get(:deferred_send) == nil
    end
  end

  describe "Ctrl-C right after Enter (I3)" do
    test "while the send is pending: the draft stays, and the turn stops once it appears" do
      {state, request} = ready() |> type("go") |> send()

      {state, effects} = press(state, ctrl("c"))
      assert requests(effects) == []
      assert text(state) == "go"
      assert state.quit_armed == nil
      assert state.notice == {:command_feedback, "Stopping the turn."}

      {state, effects} = outcome(state, request, :accepted, ["r1"])
      assert requests(effects) == []
      assert text(state) == ""

      {state, effects} = run_update(state, run("r1", :queued))
      assert [%{kind: {:run_control, :stop, "r1"}}] = requests(effects)
      assert state.stop_on_arrival == nil
    end

    test "after the send was accepted but before its run is on screen" do
      {state, request} = ready() |> type("go") |> send()
      {state, _} = outcome(state, request, :accepted, ["r1"])
      assert state.sent_turn == {"c", "r1"}

      {state, effects} = press(state, ctrl("c"))
      assert requests(effects) == []
      assert state.quit_armed == nil

      {state, effects} = run_update(state, run("r1", :streaming))
      assert [%{kind: {:run_control, :stop, "r1"}}] = requests(effects)
      assert state.sent_turn == nil
    end

    test "Esc right after Enter stops that turn too" do
      {state, request} = ready() |> type("go") |> send()
      {state, _} = outcome(state, request, :accepted, ["r1"])
      state = press!(state, Input.key(:escape))

      {_state, effects} = run_update(state, run("r1", :running))
      assert [%{kind: {:run_control, :stop, "r1"}}] = requests(effects)
    end

    test "a refused send, or a run that ended first, drops the stop" do
      {state, request} = ready() |> type("go") |> send()
      state = press!(state, ctrl("c"))
      {state, _} = outcome(state, request, :rejected, [])
      assert state.stop_on_arrival == nil

      {state, request} = ready() |> type("go") |> send()
      state = press!(state, ctrl("c"))
      {state, _} = outcome(state, request, :accepted, ["r1"])
      {state, effects} = run_update(state, run("r1", :done, actions: []))
      assert requests(effects) == []
      assert state.stop_on_arrival == nil
    end

    test "mashing Ctrl-C after Enter stops once, then arms and quits" do
      {state, request} = ready() |> type("go") |> send()
      state = press!(state, ctrl("c"))
      assert state.quit_armed == nil
      {state, _} = outcome(state, request, :accepted, ["r1"])

      state = press!(state, ctrl("c"))
      assert is_binary(state.quit_armed)

      {state, effects} = press(state, ctrl("c"))
      assert state.lifecycle == :closing
      assert {:detach, 0} in effects
    end
  end
end
