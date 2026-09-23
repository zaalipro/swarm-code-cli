defmodule SwarmCodeCLI.UI.ExternalEditorTest do
  @moduledoc """
  Pass 70 E6: Ctrl-X edits the draft in $VISUAL/$EDITOR. The terminal steps
  aside (the same suspend/resume the port does for Ctrl-Z), the editor runs on
  a private copy, the edited text replaces the draft as one undoable edit, and
  a failure leaves the draft as it was and says why. The test process is the
  terminal; the editor is a function the runtime is given.
  """
  use ExUnit.Case, async: false

  alias SwarmCodeCLI.UI.{Action, Capabilities, Drafts, Editor, Init, Keymap, Reducer}
  alias SwarmCodeCLI.UI.{SessionRuntime, Size}
  alias SwarmCodeCLI.UI.DataSource.Fake
  alias Fake.{Script, Source}

  defp runtime(editor) do
    {:ok, script} =
      Script.decode(File.read!(Path.expand("../../fixtures/fake/three_run_script.json", __DIR__)))

    source = start_supervised!({Source, script: script, source_epoch: "epoch"})

    client =
      start_supervised!({Fake, source: source, source_epoch: "epoch", client_id: "editor-client"})

    size = %Size{columns: 160, rows: 50}
    caps = %Capabilities{size: size}

    init = %Init{
      size: size,
      capabilities: caps,
      source_epoch: "epoch",
      destination: {:conversation, Script.id(:a)},
      focus: "composer",
      now: Script.clock_ms()
    }

    runtime =
      start_supervised!(
        {SessionRuntime, init: init, data_source: client, frame_ms: 60_000, editor: editor}
      )

    {:ok, _} = SessionRuntime.register_terminal(runtime, self(), 0, caps)
    ready(runtime, 200)
    runtime
  end

  defp ready(_, 0), do: flunk("runtime did not bind")

  defp ready(runtime, n) do
    if SessionRuntime.status(runtime).phase == :running, do: :ok, else: ready(runtime, n - 1)
  end

  defp key, do: {Script.id(:a), :main}

  defp draft(runtime),
    do: Editor.text(Drafts.fetch(SessionRuntime.snapshot(runtime).drafts, key()).editor)

  defp ctrl_x(runtime),
    do: SessionRuntime.input(runtime, {:text_fragment, :press, "x", [:control]})

  # The terminal's side of Ctrl-Z, which Ctrl-X reuses.
  defp step_aside(runtime) do
    assert_receive {:terminal_control, :suspend, 0}, 2_000
    assert SessionRuntime.snapshot(runtime).lifecycle == :suspend_requested
    SessionRuntime.action(runtime, {:terminal_lifecycle, :suspended, 0, :runtime})
  end

  defp come_back(runtime) do
    assert_receive {:terminal_control, :resume, 0}, 2_000
    SessionRuntime.action(runtime, {:terminal_lifecycle, :resumed, 0, :runtime})
    assert SessionRuntime.snapshot(runtime).lifecycle == :running
  end

  test "Ctrl-X is bound in the composer" do
    size = %Size{columns: 120, rows: 40}

    {state, _} =
      Reducer.init(%Init{
        size: size,
        capabilities: %Capabilities{size: size},
        source_epoch: "e",
        destination: {:conversation, "c"},
        focus: "composer"
      })

    assert {:ok, {:external_editor, {"c", :main}}} =
             Keymap.resolve({:text_fragment, :press, "x", [:control]}, state, %{})

    assert {:error, :invalid_action} =
             Action.validate({:external_edit_done, {"c", :main}, {:error, :whatever}})
  end

  test "the edited text replaces the draft, the terminal comes back, one undo restores it" do
    parent = self()

    runtime =
      runtime(fn file ->
        send(parent, {:editing, File.read!(file), File.stat!(file).mode})
        File.write!(file, "a better prompt\nwith two lines\n")
        :ok
      end)

    SessionRuntime.action(runtime, {:editor, key(), {:insert, "a rough prompt"}})
    ctrl_x(runtime)
    step_aside(runtime)

    assert_receive {:editing, "a rough prompt", mode}, 2_000
    assert Bitwise.band(mode, 0o777) == 0o600
    come_back(runtime)

    assert draft(runtime) == "a better prompt\nwith two lines"
    SessionRuntime.action(runtime, {:editor, key(), :undo})
    assert draft(runtime) == "a rough prompt"
  end

  test "an editor that fails leaves the draft and says why" do
    runtime = runtime(fn _file -> {:error, {:exit, 2}} end)
    SessionRuntime.action(runtime, {:editor, key(), {:insert, "keep me"}})
    ctrl_x(runtime)
    step_aside(runtime)
    come_back(runtime)

    ui = SessionRuntime.snapshot(runtime)
    assert draft(runtime) == "keep me"

    assert ui.notice ==
             {:command_feedback, "The editor exited with status 2; the draft is unchanged."}
  end

  test "the private copy is gone afterwards" do
    parent = self()
    runtime = runtime(fn file -> send(parent, {:file, file}) && :ok end)
    ctrl_x(runtime)
    step_aside(runtime)
    assert_receive {:file, file}, 2_000
    come_back(runtime)
    refute File.exists?(file)
    refute File.exists?(Path.dirname(file))
  end

  test "outside callers cannot hand the draft a result" do
    runtime = runtime(fn _ -> :ok end)
    SessionRuntime.action(runtime, {:external_edit_done, key(), {:ok, "injected"}})
    assert draft(runtime) == ""
  end
end
