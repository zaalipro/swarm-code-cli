defmodule SwarmCodeCLI.UI.Pass70QaClockTest do
  @moduledoc """
  pass70 Q2, found driving the release: the saved session's clock stopped at
  launch (it inferred "wall clock" from a zero `init.now`), so a daemon toast
  ("Finished · Swarm finished …") stayed on the status line for the rest of
  the session, a running run's elapsed time never moved, and command
  feedback ("Project trusted; approval mode auto") never left either, hiding
  the key hints for good.
  """
  use ExUnit.Case, async: false

  alias SwarmCodeCLI.UI.{Capabilities, Init, Reducer, SessionRuntime, Size, State}
  alias SwarmCodeCLI.UI.Projector.Status
  alias SwarmCodeCLI.UI.DataSource.Fake
  alias Fake.{Script, Source}

  describe "status-line feedback" do
    defp ready do
      size = %Size{columns: 120, rows: 30}

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

    test "fades after a few seconds instead of staying until the next notice" do
      state = %{ready() | now: 1_000_000}
      {state, _effects} = Reducer.update(state, {:slash_local, :queue})
      assert {:command_feedback, _} = notice = state.notice
      assert state.notice_at == 1_000_000

      assert State.shown_notice(%{state | now: 1_000_000 + 500}) == notice
      assert State.shown_notice(%{state | now: 1_000_000 + State.notice_ms()}) == nil

      # And the status line gives the key hints back.
      later = %{state | now: 1_000_000 + State.notice_ms()}
      assert status_text(state) =~ "Type the message after /queue."
      refute status_text(later) =~ "Type the message after /queue."
      assert status_text(later) =~ "send"
    end

    test "a rejected command fades too, without any effect from the reducer" do
      state = %{ready() | now: 5_000, notice: nil}
      {state, effects} = Reducer.update(state, {:invoke, {:run_control, :stop, "gone"}, "x"})
      assert effects == []
      assert {:command_rejected, _} = state.notice
      assert State.shown_notice(%{state | now: 5_000 + State.notice_ms()}) == nil
    end

    test "the quit hint is not a fading toast" do
      state = %{
        ready()
        | now: 0,
          notice: {:command_feedback, "Press Ctrl-C again to quit."},
          notice_at: 0
      }

      assert State.shown_notice(%{state | now: 60_000}) == state.notice
    end

    defp status_text(state) do
      state
      |> Status.project(:medium, 120)
      |> List.wrap()
      |> Enum.flat_map(& &1.spans)
      |> Enum.map_join(&SwarmCodeCLI.UI.SafeText.value(&1.text))
    end
  end

  describe "a wall-clock session" do
    defp runtime(opts) do
      {:ok, script} =
        Script.decode(
          File.read!(Path.expand("../../fixtures/fake/three_run_script.json", __DIR__))
        )

      source = start_supervised!({Source, script: script, source_epoch: "epoch"})

      client =
        start_supervised!({Fake, source: source, source_epoch: "epoch", client_id: "clock"})

      size = %Size{columns: 160, rows: 50}
      caps = %Capabilities{size: size}

      init = %Init{
        size: size,
        capabilities: caps,
        source_epoch: "epoch",
        destination: {:conversation, Script.id(:a)},
        # The release starts from the real time, not from zero.
        now: System.system_time(:millisecond) - 600_000
      }

      runtime =
        start_supervised!(
          {SessionRuntime, [init: init, data_source: client, frame_ms: 60_000] ++ opts}
        )

      {:ok, _} = SessionRuntime.register_terminal(runtime, self(), 0, caps)
      wait(fn -> SessionRuntime.status(runtime).phase == :running end)
      runtime
    end

    defp wait(check, attempts \\ 400)
    defp wait(_check, 0), do: flunk("condition never held")

    defp wait(check, attempts) do
      if check.() do
        :ok
      else
        receive do
        after
          5 -> wait(check, attempts - 1)
        end
      end
    end

    test "reads the clock at every commit although init.now is not zero" do
      runtime = runtime(wall_clock: true)
      before = System.system_time(:millisecond)
      SessionRuntime.action(runtime, {:editor, {Script.id(:a), :main}, {:insert, "x"}})
      assert SessionRuntime.snapshot(runtime).now >= before
    end

    test "keeps a one-second repaint while a run on screen is live, and only then" do
      runtime = runtime(wall_clock: true)

      wait(fn ->
        SessionRuntime.action(runtime, {:editor, {Script.id(:a), :main}, {:insert, "x"}})
        :sys.get_state(runtime).clock_timer != nil
      end)

      ui = SessionRuntime.snapshot(runtime)
      assert SessionRuntime.time_dependent?(ui)

      idle = %{ui | read_model: %{ui.read_model | runs: %{}, toasts: []}}
      refute SessionRuntime.time_dependent?(idle)
    end

    test "a scripted session keeps its fixed clock" do
      runtime = runtime([])
      ui = SessionRuntime.snapshot(runtime)
      SessionRuntime.action(runtime, {:editor, {Script.id(:a), :main}, {:insert, "x"}})
      assert SessionRuntime.snapshot(runtime).now == ui.now
      assert :sys.get_state(runtime).clock_timer == nil
    end
  end
end
