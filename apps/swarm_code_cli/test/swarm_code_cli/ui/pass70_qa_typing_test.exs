defmodule SwarmCodeCLI.UI.Pass70QaTypingTest do
  @moduledoc """
  pass70 Q4, measured in the release: 40 characters typed without bracketed
  paste took ~5 s, because every key re-projected the whole scene before the
  terminal was given the next one. Plain typing is now applied at once and
  projected with the next frame; any other key projects first, so the action
  table it resolves against is never behind the screen.
  """
  use ExUnit.Case, async: false

  alias SwarmCodeCLI.UI.{
    Capabilities,
    Drafts,
    Editor,
    Init,
    Keymap,
    SceneSlot,
    SessionRuntime,
    Size
  }

  alias SwarmCodeCLI.UI.DataSource.Fake
  alias Fake.{Script, Source}

  defp runtime do
    {:ok, script} =
      Script.decode(File.read!(Path.expand("../../fixtures/fake/three_run_script.json", __DIR__)))

    source = start_supervised!({Source, script: script, source_epoch: "epoch"})
    client = start_supervised!({Fake, source: source, source_epoch: "epoch", client_id: "typing"})
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
      start_supervised!({SessionRuntime, init: init, data_source: client, frame_ms: 60_000})

    {:ok, tid} = SessionRuntime.register_terminal(runtime, self(), 0, caps)
    wait(fn -> SessionRuntime.status(runtime).phase == :running end)
    wait(fn -> SessionRuntime.snapshot(runtime).watches.workspace.status == :ready end)
    {runtime, tid}
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

  defp type(runtime, text) do
    for grapheme <- String.graphemes(text),
        do: :ok = SessionRuntime.input(runtime, {:text_fragment, :press, grapheme, []})
  end

  defp draft(runtime) do
    ui = SessionRuntime.snapshot(runtime)
    Editor.text(Drafts.fetch(ui.drafts, {Script.id(:a), :main}).editor)
  end

  test "typed keys are applied at once and projected once, with the next frame" do
    {runtime, tid} = runtime()
    refute :sys.get_state(runtime).dirty?

    type(runtime, "hello world")
    assert draft(runtime) == "hello world"
    # Eleven keys, no projection yet: the scene is behind the state.
    state = :sys.get_state(runtime)
    assert state.dirty?
    assert {:error, :stale_revision} = SceneSlot.fetch(tid, state.ui.revision)

    # The frame projects the latest state and asks for exactly that revision.
    %{draw: {:timer, id}} = SessionRuntime.status(runtime)
    send(runtime, {:frame, id})
    assert_receive {:draw, _token, revision}
    assert revision == :sys.get_state(runtime).ui.revision
    assert {:ok, _scene} = SceneSlot.fetch(tid, revision)
    refute :sys.get_state(runtime).dirty?
  end

  test "a key that needs the action table projects the typed text first" do
    {runtime, _tid} = runtime()
    type(runtime, "abc")
    assert :sys.get_state(runtime).dirty?

    # Ctrl-A is a composer binding: it resolves against a fresh table.
    :ok = SessionRuntime.input(runtime, {:text_fragment, :press, "a", [:control]})
    refute :sys.get_state(runtime).dirty?
    assert draft(runtime) == "abc"
  end

  test "only plain composer typing takes the short path" do
    ui = %{SwarmCodeCLI.UI.State.__struct__() | focus: "composer"}
    assert Keymap.typing?({:text_fragment, :press, "x", []}, ui)
    assert Keymap.typing?({:text_fragment, :press, "X", [:shift]}, ui)
    assert Keymap.typing?({:key, :press, :backspace, []}, ui)
    refute Keymap.typing?({:text_fragment, :press, "a", [:control]}, ui)
    refute Keymap.typing?({:key, :press, :enter, []}, ui)
    refute Keymap.typing?({:text_fragment, :release, "x", []}, ui)
    refute Keymap.typing?({:text_fragment, :press, "j", []}, %{ui | focus: "main"})
    refute Keymap.typing?({:text_fragment, :press, "y", []}, %{ui | layers: [{:approval, "i"}]})
  end
end
