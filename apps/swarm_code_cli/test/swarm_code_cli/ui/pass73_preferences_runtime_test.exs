defmodule SwarmCodeCLI.UI.Pass73PreferencesRuntimeTest do
  @moduledoc """
  pass73 T2/T9 in the session runtime: `/mouse` and `/theme` tell the
  terminal's owner at once, ask for the frame that shows the change and save
  the choice, and the session keeps running (live check: `/mouse off` closed
  the session, the runtime crashed committing the change).
  """
  use ExUnit.Case, async: false

  alias SwarmCodeCLI.UI.{SessionRuntime, Init, Input, Size, Capabilities}
  alias SwarmCodeCLI.UI.Init.Preferences
  alias SwarmCodeCLI.UI.DataSource.Fake
  alias Fake.{Script, Source}

  @moduletag :tmp_dir

  defp start_runtime(path) do
    {:ok, script} =
      Script.decode(File.read!(Path.expand("../../fixtures/fake/three_run_script.json", __DIR__)))

    source = start_supervised!({Source, script: script, source_epoch: "epoch"})
    client = start_supervised!({Fake, source: source, source_epoch: "epoch", client_id: "p73"})
    size = %Size{columns: 160, rows: 50}
    caps = %Capabilities{size: size}

    init = %Init{
      size: size,
      capabilities: caps,
      source_epoch: "epoch",
      destination: {:conversation, Script.id(:a)},
      now: Script.clock_ms()
    }

    runtime =
      start_supervised!(
        {SessionRuntime,
         init: init, data_source: client, frame_ms: 60_000, preferences_path: path}
      )

    {runtime, caps}
  end

  defp settle(runtime) do
    case :sys.get_state(runtime).prefs.task do
      %Task{pid: pid} ->
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
        _ = :sys.get_state(runtime)
        settle(runtime)

      nil ->
        :ok
    end
  end

  defp running(runtime, n \\ 200)
  defp running(_runtime, 0), do: flunk("runtime did not bind")

  defp running(runtime, n) do
    if SessionRuntime.status(runtime).phase == :running, do: :ok, else: running(runtime, n - 1)
  end

  defp command(runtime, text) do
    for letter <- String.graphemes(text),
        do: :ok = SessionRuntime.input(runtime, Input.text_fragment(:press, letter, []))

    :ok = SessionRuntime.input(runtime, Input.key(:enter))
  end

  test "/mouse off and /theme reach the terminal, and the session keeps running", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "cli.json")
    {runtime, caps} = start_runtime(path)
    settle(runtime)
    watch = Process.monitor(runtime)

    {:ok, _} = SessionRuntime.register_terminal(runtime, self(), 0, caps)
    running(runtime)
    revision = SessionRuntime.snapshot(runtime).revision

    command(runtime, "/mouse off")
    assert_receive {:terminal_preferences, %{mouse?: false}}, 1_000
    refute_received {:DOWN, ^watch, :process, _, _}
    assert SessionRuntime.status(runtime).phase == :running

    ui = SessionRuntime.snapshot(runtime)
    refute ui.mouse?
    assert ui.revision > revision

    command(runtime, "/theme")
    assert_receive {:terminal_preferences, %{theme: :light}}, 1_000
    assert SessionRuntime.status(runtime).phase == :running
    assert SessionRuntime.snapshot(runtime).theme_mode == :light

    settle(runtime)
    assert %{mouse?: false, theme: :light} = Preferences.read(path)
    refute_received {:DOWN, ^watch, :process, _, _}
  end
end
