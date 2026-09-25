defmodule SwarmCodeCLI.UI.Settings.C74PreferencesTest do
  @moduledoc """
  cli74 U1-3: cli.json through the core file layer, the runtime's preference
  queue, the legacy saves that write only their key, the settings effects,
  the open-folder words and the redaction of crash reports.
  """
  use ExUnit.Case, async: false

  alias SwarmCode.Settings.CliFile
  alias SwarmCodeCLI.UI.{Capabilities, Effect, Init, Reducer, SessionRuntime, Size}
  alias SwarmCodeCLI.UI.Init.{Preferences, PrefsQueue}
  alias SwarmCodeCLI.UI.DataSource.Fake
  alias SwarmCodeCLI.UI.Settings.{Layer, Paste}
  alias Fake.{Script, Source}

  @moduletag :tmp_dir
  @canary "sk-canary-7Q2X-DO-NOT-SHOW"

  describe "the legacy API" do
    test "read, write and valid? keep their meaning over the core file layer", %{tmp_dir: dir} do
      path = Path.join(dir, "cli.json")
      assert Preferences.read(path) == Preferences.defaults()
      assert Preferences.read(nil) == Preferences.defaults()

      File.write!(path, ~s({"panel":"compact","future_key":1,"mouse":"loud"}))
      assert Preferences.read(path) == %{Preferences.defaults() | panel_mode: :compact}

      assert :ok = Preferences.write(path, %{theme: :light, show_diffs: false})

      assert Preferences.read(path) == %{
               panel_mode: :compact,
               show_diffs: false,
               theme: :light,
               mouse?: true
             }

      # Unknown keys survive, the file is private.
      assert %{"future_key" => 1} = path |> File.read!() |> JSON.decode!()
      assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600

      assert Preferences.valid?(%{panel_mode: :hidden})
      refute Preferences.valid?(%{theme: nil})
      refute Preferences.valid?(%{})
      assert {:error, :invalid} = Preferences.write(path, %{nope: 1})
    end
  end

  describe "the preference queue" do
    test "holds 32 jobs with the running one; a 33rd is busy" do
      queue =
        Enum.reduce(1..31, PrefsQueue.new(), fn n, queue ->
          {:ok, queue} = PrefsQueue.push(queue, {:read, n})
          queue
        end)

      assert PrefsQueue.size(queue) == 31
      assert PrefsQueue.max_jobs() == 32
      assert {:error, :busy} = PrefsQueue.push(queue, {:read, 99})
      assert {:ok, {:read, 1}, queue} = PrefsQueue.pop(queue)
      assert {:ok, _queue} = PrefsQueue.push(queue, {:read, 99})

      # A busy job answers the settings layer at once.
      assert Preferences.unavailable({:write, 3, 7, %{}, %{}}, :busy) ==
               {:cli_result, 3, 7, {:error, :busy}}
    end

    test "legacy saves waiting in a row become one job" do
      {:ok, queue} = PrefsQueue.push(PrefsQueue.new(), {:legacy, %{panel_mode: :compact}})
      {:ok, queue} = PrefsQueue.push(queue, {:legacy, %{theme: :light}})
      assert PrefsQueue.size(queue) == 1

      assert {:ok, {:legacy, %{panel_mode: :compact, theme: :light}}, _} = PrefsQueue.pop(queue)
    end

    test "a legacy save writes only its key, expecting the value last read", %{tmp_dir: dir} do
      path = Path.join(dir, "cli.json")
      {{:boot, snapshot}, known} = Preferences.run(path, :boot, %{})
      assert snapshot.status == :absent and known == %{}

      # Another process (`swarmcode config set terminal.theme light`).
      {:ok, _} = CliFile.write_changes(path, %{"theme" => "light"}, %{"theme" => :any})

      {{:legacy, _, {:ok, after_diff}}, known} =
        Preferences.run(path, {:legacy, %{show_diffs: false}}, known)

      assert after_diff.values == %{"theme" => "light", "show_diffs" => false}
      assert known == after_diff.values

      # The same key changed elsewhere: a conflict, the file keeps its value.
      {:ok, _} = CliFile.write_changes(path, %{"panel" => "hidden"}, %{"panel" => :any})

      assert {{:legacy, _, {:conflict, %{"panel" => "hidden"}}}, known} =
               Preferences.run(path, {:legacy, %{panel_mode: :compact}}, known)

      assert known["panel"] == "hidden"
      assert Preferences.read(path).panel_mode == :hidden
    end

    test "settings reads and writes answer by generation and reference", %{tmp_dir: dir} do
      path = Path.join(dir, "cli.json")

      assert {{:cli_result, 4, 9, {:ok, %{values: %{"wheel_lines" => 5}}}}, _} =
               Preferences.run(
                 path,
                 {:write, 4, 9, %{"wheel_lines" => 5}, %{"wheel_lines" => :absent}},
                 %{}
               )

      assert {{:cli_result, 4, 10, {:conflict, %{"wheel_lines" => 5}}}, _} =
               Preferences.run(
                 path,
                 {:write, 4, 10, %{"wheel_lines" => 7}, %{"wheel_lines" => :absent}},
                 %{}
               )

      assert {{:cli_result, 4, 11, {:error, :invalid, %{"wheel_lines" => _}}}, _} =
               Preferences.run(
                 path,
                 {:write, 4, 11, %{"wheel_lines" => -1}, %{"wheel_lines" => :any}},
                 %{}
               )

      assert {{:cli_snapshot, 4, %{values: %{"wheel_lines" => 5}}}, _} =
               Preferences.run(path, {:read, 4}, %{})

      assert {{:cli_snapshot, 4, {:error, :unavailable}}, %{}} =
               Preferences.run(nil, {:read, 4}, %{})
    end
  end

  describe "in the session runtime" do
    test "/diff after an external change of the theme keeps the external value", %{tmp_dir: dir} do
      path = Path.join(dir, "cli.json")
      File.write!(path, ~s({"theme":"dark"}))
      runtime = start_runtime(path)
      settle(runtime)

      {:ok, _} = CliFile.write_changes(path, %{"theme" => "light"}, %{"theme" => :any})

      :ok = SessionRuntime.action(runtime, {:show_diffs, false})
      settle(runtime)

      assert %{"theme" => "light", "show_diffs" => false} = path |> File.read!() |> JSON.decode!()
      assert SessionRuntime.snapshot(runtime).prefs["theme"] == "light"
    end

    test "a legacy save that meets a change of its own key keeps the file's", %{tmp_dir: dir} do
      path = Path.join(dir, "cli.json")
      runtime = start_runtime(path)
      settle(runtime)

      {:ok, _} = CliFile.write_changes(path, %{"panel" => "hidden"}, %{"panel" => :any})
      :ok = SessionRuntime.action(runtime, {:panel_mode, :compact})
      settle(runtime)

      ui = SessionRuntime.snapshot(runtime)
      assert ui.panel_mode == :hidden
      assert ui.prefs["panel"] == "hidden"
      assert {:command_feedback, "cli.json changed elsewhere; /settings shows it"} = ui.notice
      assert Preferences.read(path).panel_mode == :hidden
    end
  end

  describe "effects and answers" do
    test "the settings effects are bounded" do
      assert {:ok, _} = Effect.validate({:settings_cli_read, 1})

      assert {:ok, _} =
               Effect.validate(
                 {:settings_cli_write, 1, 2, %{"theme" => "light"}, %{"theme" => :absent}}
               )

      too_many = Map.new(1..65, &{"k#{&1}", 1})
      assert {:error, _} = Effect.validate({:settings_cli_write, 1, 2, too_many, %{}})
      assert {:error, _} = Effect.validate({:settings_cli_write, 1, 0, %{}, %{}})

      assert {:error, _} =
               Effect.validate(
                 {:settings_cli_write_text, 1, 2, String.duplicate("a", 65_537), nil}
               )

      assert {:ok, _} =
               Effect.validate({:settings_external_edit, 1, 2, %{content: "{}", suffix: ".json"}})

      assert {:error, _} =
               Effect.validate({:settings_external_edit, 1, 2, %{content: "", suffix: "/x"}})

      assert {:ok, _} = Effect.validate({:settings_open_folder, 1, "/tmp"})
      assert {:error, _} = Effect.validate({:settings_open_folder, 1, "relative/path"})
    end

    test "open folder: no desktop, over SSH, a missing folder, each with its words", %{
      tmp_dir: dir
    } do
      assert SessionRuntime.folder_opener({:unix, :linux}, %{}) == {:error, :no_desktop}

      assert SessionRuntime.folder_opener({:unix, :linux}, %{"DISPLAY" => ":0"}) ==
               {:ok, "xdg-open"}

      assert SessionRuntime.folder_opener({:unix, :darwin}, %{"SSH_CONNECTION" => "1 2 3 4"}) ==
               {:error, :no_desktop}

      assert SessionRuntime.folder_opener({:unix, :darwin}, %{}) == {:ok, "open"}

      missing = Path.join(dir, "not-yet")
      assert SessionRuntime.open_folder(missing, %{}, {:unix, :darwin}) == {:error, :missing}
      refute File.exists?(missing)
      assert SessionRuntime.open_folder(dir, %{}, {:unix, :linux}) == {:error, :no_desktop}

      state = init_state()

      {state, []} = Reducer.update(state, {:settings, {:folder_result, 0, {:error, :no_desktop}}})

      assert state.notice ==
               {:command_feedback, "No desktop to open folders here · y copies the path"}

      state = %{state | settings: Layer.new(1)}
      {state, []} = Reducer.update(state, {:settings, {:folder_result, 1, {:error, :missing}}})

      assert state.settings.status.text ==
               "That folder does not exist yet · n creates the first file in it"
    end

    test "the preferred editor comes first" do
      file = Path.join(System.tmp_dir!(), "c74-editor-#{System.unique_integer([:positive])}")
      File.write!(file, "x")
      assert SessionRuntime.run_editor(file, "true") == :ok
      assert SessionRuntime.run_editor(file, "false") == {:error, {:exit, 1}}
      File.rm!(file)
    end
  end

  describe "secrets in crash reports" do
    test "a crash report of the runtime with a paste in flight has no canary" do
      layer = %{
        Layer.new(1)
        | mode: :paste,
          paste: Paste.put(Paste.new(%{slot: "api_key"}), @canary)
      }

      ui = %{init_state() | settings: layer}

      status = %{
        state: %{phase: :running, ui: ui, draw: :idle, timers: %{}},
        message: {:input, {:paste, @canary}},
        reason: {:badarg, @canary},
        log: [{:in, {:paste, @canary}}],
        queue: [{:"$gen_call", {self(), make_ref()}, {:input, {:paste, @canary}}}]
      }

      report =
        inspect(SessionRuntime.format_status(status),
          limit: :infinity,
          printable_limit: :infinity
        )

      refute report =~ @canary
      refute inspect(ui, limit: :infinity, printable_limit: :infinity) =~ @canary

      owner = SwarmCodeCLI.UI.Renderer.RatatuiPort.Owner

      owner_report =
        inspect(owner.format_status(%{status | state: %{ui: ui}}),
          limit: :infinity,
          printable_limit: :infinity
        )

      refute owner_report =~ @canary
    end
  end

  # ------------------------------------------------------------------ helpers

  defp init_state do
    size = %Size{columns: 120, rows: 40}

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

  defp start_runtime(path) do
    {:ok, script} =
      Script.decode(
        File.read!(Path.expand("../../../fixtures/fake/three_run_script.json", __DIR__))
      )

    source = start_supervised!({Source, script: script, source_epoch: "epoch"})
    client = start_supervised!({Fake, source: source, source_epoch: "epoch", client_id: "c74"})
    size = %Size{columns: 160, rows: 50}

    init = %Init{
      size: size,
      capabilities: %Capabilities{size: size},
      source_epoch: "epoch",
      destination: {:conversation, Script.id(:a)},
      now: Script.clock_ms()
    }

    runtime =
      start_supervised!(
        {SessionRuntime,
         init: init, data_source: client, frame_ms: 60_000, preferences_path: path}
      )

    {:ok, _} = SessionRuntime.register_terminal(runtime, self(), 0, %Capabilities{size: size})
    running(runtime)
    runtime
  end

  defp running(runtime, n \\ 5_000)
  defp running(_runtime, 0), do: flunk("runtime did not bind")

  defp running(runtime, n) do
    if SessionRuntime.status(runtime).phase == :running, do: :ok, else: running(runtime, n - 1)
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
end
