defmodule SwarmCodeCLI.UI.Pass72PreferencesRuntimeTest do
  @moduledoc """
  Pass 72 (P6): the session runtime reads the preferences file at start and
  writes the panel's mode when it changes, in tasks it owns.
  """
  use ExUnit.Case, async: false

  alias SwarmCodeCLI.UI.{SessionRuntime, Init, Size, Capabilities}
  alias SwarmCodeCLI.UI.Init.Preferences
  alias SwarmCodeCLI.UI.DataSource.Fake
  alias Fake.{Script, Source}

  @moduletag :tmp_dir

  defp start_runtime(path) do
    {:ok, script} =
      Script.decode(File.read!(Path.expand("../../fixtures/fake/three_run_script.json", __DIR__)))

    source = start_supervised!({Source, script: script, source_epoch: "epoch"})
    client = start_supervised!({Fake, source: source, source_epoch: "epoch", client_id: "prefs"})
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

  # Waits for the runtime's preferences task (if any) to finish and for the
  # runtime to have handled its answer.
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

  test "the mode is read at start and written, privately, when Ctrl-B changes it", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "cli.json")
    :ok = Preferences.write(path, %{panel_mode: :compact})
    {runtime, caps} = start_runtime(path)
    settle(runtime)
    assert SessionRuntime.snapshot(runtime).panel_mode == :compact

    {:ok, _} = SessionRuntime.register_terminal(runtime, self(), 0, caps)
    running(runtime)

    :ok = SessionRuntime.input(runtime, {:text_fragment, :press, "b", [:control]})
    assert SessionRuntime.snapshot(runtime).panel_mode == :hidden

    settle(runtime)
    assert Preferences.read(path) == %{Preferences.defaults() | panel_mode: :hidden}

    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
  end

  test "without a path nothing is read or written", %{tmp_dir: dir} do
    {runtime, _caps} = start_runtime(nil)
    # cli74: the preference queue (`Init.PrefsQueue`) is empty and idle.
    assert %{path: nil, task: nil, job: nil, known: known, queue: queue} =
             :sys.get_state(runtime).prefs

    assert known == %{} and SwarmCodeCLI.UI.Init.PrefsQueue.size(queue) == 0
    assert File.ls!(dir) == []
  end
end
