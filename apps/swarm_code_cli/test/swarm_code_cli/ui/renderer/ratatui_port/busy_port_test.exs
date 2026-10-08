defmodule SwarmCodeCLI.UI.Renderer.RatatuiPort.BusyPortTest do
  # cli020 R1/R2: a busy port (a slow terminal behind the native helper, or
  # macOS's small pipes) never stops the owner. Controls wait for the port and
  # go in order; a frame the port cannot take is answered stale and the next
  # request draws the newest state; every draw request is answered well before
  # the runtime's own deadline.
  use ExUnit.Case, async: false
  alias SwarmCodeCLI.UI.{Capabilities, Fixtures, Projector, SceneSlot, Size}
  alias SwarmCodeCLI.UI.Renderer.RatatuiPort.Owner

  @moduletag :tmp_dir
  @big %Size{columns: 500, rows: 200}

  defmodule Runtime do
    use GenServer
    def start_link(test), do: GenServer.start_link(__MODULE__, test)
    def init(test), do: {:ok, %{test: test, slot: SceneSlot.new()}}

    def handle_call({:terminal, owner, generation, caps}, _, state) do
      send(state.test, {:registered, owner, generation, caps})
      {:reply, {:ok, state.slot}, state}
    end

    def handle_call({:put, scene}, _, state),
      do: {:reply, SceneSlot.put(state.slot, scene), state}

    def handle_call(request, _, state) do
      send(state.test, request)
      {:reply, :ok, state}
    end

    def handle_info(message, state) do
      send(state.test, message)
      {:noreply, state}
    end
  end

  # A helper that reads nothing until the gate file exists, then drains the
  # protocol descriptor: the port is busy until the test opens the gate.
  defp gated_helper(dir) do
    gate = Path.join(dir, "gate")
    helper = Path.join(dir, "gated_helper.sh")

    File.write!(helper, """
    #!/bin/sh
    while [ ! -e #{shell_quote(gate)} ]; do /bin/sleep 0.01; done
    exec /bin/cat <&3 > /dev/null
    """)

    File.chmod!(helper, 0o755)
    {helper, gate}
  end

  # Test names (and so tmp_dir paths) may hold an apostrophe.
  defp shell_quote(path), do: "'" <> String.replace(path, "'", "'\\''") <> "'"

  defp owner(executable) do
    runtime = start_supervised!({Runtime, self()})

    owner =
      start_supervised!(
        {Owner,
         runtime: runtime,
         capabilities: %Capabilities{size: @big},
         flags: %{alternate?: false, focus?: true, paste?: true},
         executable: executable,
         observer: self()}
      )

    {:os_pid, os_pid} = Port.info(:sys.get_state(owner).port, :os_pid)

    on_exit(fn ->
      System.cmd("/bin/kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end)

    record(owner, <<1, 16, 1::64, 500::16, 200::16, 6>>)
    assert_receive {:terminal_owner, ^owner, :ready}
    {owner, runtime}
  end

  defp record(owner, body) do
    port = :sys.get_state(owner).port
    send(owner, {port, {:data, <<byte_size(body)::32, body::binary>>}})
    :sys.get_state(owner)
  end

  defp scene(runtime, revision) do
    {scene, _} =
      Projector.project(Fixtures.representative(:chat, @big, %Capabilities{size: @big}))

    :ok = GenServer.call(runtime, {:put, %{scene | revision: revision}})
  end

  # A full 500x200 frame is far over the pipe and the port's busy limit, so
  # the port stays busy until the helper reads it.
  defp busy!(owner, runtime) do
    scene(runtime, 1)
    send(owner, {:draw, "big", 1})
    state = :sys.get_state(owner)
    assert {1, 1, "big"} = state.pending
    {:queue_size, queued} = :erlang.port_info(state.port, :queue_size)
    assert queued > 8192
    state
  end

  test "controls on a busy port wait for it, keep their order and change the modes", %{
    tmp_dir: dir
  } do
    {helper, gate} = gated_helper(dir)
    {owner, runtime} = owner(helper)
    busy!(owner, runtime)

    send(owner, {:terminal_control, :redraw, 1})
    send(owner, {:terminal_preferences, %{mouse?: true}})
    state = :sys.get_state(owner)
    assert Process.alive?(owner)
    assert state.outbox == [:redraw, {:mouse, true}]
    refute Map.get(state.flags, :mouse?, false)
    refute_received {:terminal_owner, ^owner, {:sent, _}}

    File.touch!(gate)
    assert_receive {:terminal_owner, ^owner, {:sent, :redraw}}, 3000
    assert_receive {:terminal_owner, ^owner, {:sent, {:mouse, true}}}, 3000
    state = :sys.get_state(owner)
    assert state.outbox == []
    assert state.flags.mouse?
    assert state.caps.mouse == :best_effort
  end

  test "a newer mode change replaces the one still waiting for the port", %{tmp_dir: dir} do
    {helper, gate} = gated_helper(dir)
    {owner, runtime} = owner(helper)
    busy!(owner, runtime)

    send(owner, {:terminal_preferences, %{mouse?: true}})
    assert :sys.get_state(owner).outbox == [{:mouse, true}]
    # Back to what the terminal has: nothing is left to send.
    send(owner, {:terminal_preferences, %{mouse?: false}})
    assert :sys.get_state(owner).outbox == []
    send(owner, {:terminal_preferences, %{mouse?: true}})
    send(owner, {:terminal_control, :redraw, 1})
    assert :sys.get_state(owner).outbox == [{:mouse, true}, :redraw]
    File.touch!(gate)
    assert_receive {:terminal_owner, ^owner, {:sent, {:mouse, true}}}, 3000
    assert_receive {:terminal_owner, ^owner, {:sent, :redraw}}, 3000
    refute_received {:terminal_owner, ^owner, {:sent, {:mouse, false}}}
    assert :sys.get_state(owner).flags.mouse?
  end

  test "a shutdown on a busy port is delivered once the port drains", %{tmp_dir: dir} do
    {helper, gate} = gated_helper(dir)
    {owner, runtime} = owner(helper)
    busy!(owner, runtime)

    send(owner, {:terminal_control, :shutdown, "close"})
    state = :sys.get_state(owner)
    assert state.phase == :closing
    assert state.control == {:shutdown, nil, "close"}
    assert state.outbox == [:shutdown]

    File.touch!(gate)
    assert_receive {:terminal_owner, ^owner, {:sent, :shutdown}}, 3000
    %{control: {:shutdown, token, "close"}} = :sys.get_state(owner)
    assert is_integer(token)
    record(owner, <<1, 19, 1::64, token::64, 0>>)
    assert_receive {:terminal_shutdown, "close", :ok}
    assert Process.alive?(owner)
  end

  test "a suspend on a busy port is delivered once the port drains", %{tmp_dir: dir} do
    {helper, gate} = gated_helper(dir)
    {owner, runtime} = owner(helper)
    busy!(owner, runtime)

    send(owner, {:terminal_control, :suspend, 1})
    assert :sys.get_state(owner).control == {:suspend, nil}
    File.touch!(gate)
    assert_receive {:terminal_owner, ^owner, {:sent, :suspend}}, 3000
    %{control: {:suspend, token}} = :sys.get_state(owner)
    record(owner, <<1, 19, 1::64, token::64, 1>>)
    assert_receive {:action, {:terminal_lifecycle, :suspended, 1, :runtime}}
  end

  test "a frame the busy port cannot take is answered stale; the next draws the newest", %{
    tmp_dir: dir
  } do
    {helper, gate} = gated_helper(dir)
    {owner, runtime} = owner(helper)
    busy!(owner, runtime)
    # The helper confirmed the big frame, but the port still holds its bytes.
    record(owner, <<1, 18, 1::64, 1::64, 1::64>>)
    assert_receive {:draw_result, "big", 1, :ok}

    scene(runtime, 2)
    send(owner, {:draw, "busy", 2})
    assert_receive {:draw_result, "busy", 2, {:error, :stale_revision}}, 3000
    state = :sys.get_state(owner)
    assert state.pending == nil
    assert state.sequence == 1

    File.touch!(gate)
    assert_receive {:terminal_owner, ^owner, {:sent, :credit}}, 3000
    scene(runtime, 3)
    send(owner, {:draw, "newest", 3})
    assert {2, 3, "newest"} = :sys.get_state(owner).pending
  end

  test "every draw request is answered before the runtime's one-second deadline", %{
    tmp_dir: dir
  } do
    {helper, _gate} = gated_helper(dir)
    {owner, runtime} = owner(helper)
    scene(runtime, 1)
    # From the request, as the runtime counts (the frame is built after it).
    started = System.monotonic_time(:millisecond)
    send(owner, {:draw, "big", 1})
    assert {1, 1, "big"} = :sys.get_state(owner).pending
    # The paint in flight is answered early...
    assert_receive {:draw_result, "big", 1, {:error, :stale_revision}}, 900
    assert System.monotonic_time(:millisecond) - started < 900
    # ...and so is the request queued behind it, while the terminal is slow.
    scene(runtime, 2)
    queued_at = System.monotonic_time(:millisecond)
    send(owner, {:draw, "queued", 2})
    assert :sys.get_state(owner).queued == {"queued", 2}
    assert_receive {:draw_result, "queued", 2, {:error, :stale_revision}}, 900
    assert System.monotonic_time(:millisecond) - queued_at < 900
    state = :sys.get_state(owner)
    assert state.queued == nil
    assert {1, 1, "big"} = state.pending
    assert Process.alive?(owner)
  end
end
