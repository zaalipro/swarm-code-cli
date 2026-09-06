defmodule SwarmCodeCLI.UI.Renderer.RatatuiPort.OwnerTest do
  use ExUnit.Case, async: false
  alias SwarmCodeCLI.UI.{Capabilities, Fixtures, Projector, SceneSlot, Size}
  alias SwarmCodeCLI.UI.Renderer.RatatuiPort.Owner

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

  defp owner do
    runtime = start_supervised!({Runtime, self()})
    caps = %Capabilities{size: %Size{columns: 80, rows: 24}}

    owner =
      start_supervised!(
        {Owner,
         runtime: runtime,
         capabilities: caps,
         flags: %{alternate?: false, focus?: true, paste?: true},
         executable: Path.expand("../../../../support/terminal_wire_sink.sh", __DIR__)}
      )

    {owner, runtime}
  end

  defp record(owner, body) do
    port = :sys.get_state(owner).port
    send(owner, {port, {:data, <<byte_size(body)::32, body::binary>>}})
    :sys.get_state(owner)
  end

  defp ready(owner), do: record(owner, <<1, 16, 1::64, 80::16, 24::16, 6>>)

  defp scene(runtime, revision) do
    size = %Size{columns: 80, rows: 24}

    {scene, _} =
      Projector.project(Fixtures.representative(:chat, size, %Capabilities{size: size}))

    :ok = GenServer.call(runtime, {:put, %{scene | revision: revision}})
  end

  test "readiness registers actual capabilities and input waits for the first draw" do
    {owner, runtime} = owner()
    state = ready(owner)
    assert state.credit == nil
    assert_receive {:registered, ^owner, 1, caps}
    assert caps.full_screen? and caps.paste_preallocation_bound?
    assert caps.alternate_screen == :unavailable
    assert caps.paste == :best_effort
    scene(runtime, 7)
    send(owner, {:draw, "opaque", 7})
    state = :sys.get_state(owner)
    assert state.pending == {1, 7, "opaque"}
    assert state.credit == nil
    refute_receive {:draw_result, _, _, _}, 30
    assert not Map.has_key?(state, :scene)
    assert not Map.has_key?(state, :plan)
    status = inspect(:sys.get_status(owner))
    assert status =~ "redacted"
    refute status =~ "opaque"
    record(owner, <<1, 18, 1::64, 1::64, 7::64>>)
    assert_receive {:draw_result, "opaque", 7, :ok}
    assert :sys.get_state(owner).credit == 1
    record(owner, <<1, 17, 1::64, 1::64, 0, 0, 10, 0>>)
    assert_receive {:input, {:key, :press, :tab, []}}
    assert :sys.get_state(owner).credit == 2
  end

  test "consumed input credit is replenished only after the current draw flushes" do
    {owner, runtime} = owner()
    ready(owner)
    scene(runtime, 1)
    send(owner, {:draw, "first", 1})
    :sys.get_state(owner)
    record(owner, <<1, 18, 1::64, 1::64, 1::64>>)
    scene(runtime, 2)
    send(owner, {:draw, "second", 2})
    assert :sys.get_state(owner).credit == 1
    record(owner, <<1, 17, 1::64, 1::64, 0, 0, 10, 0>>)
    assert_receive {:input, {:key, :press, :tab, []}}
    assert :sys.get_state(owner).credit == nil
    record(owner, <<1, 18, 1::64, 2::64, 2::64>>)
    assert :sys.get_state(owner).credit == 2
  end

  test "skipped revision retries without claiming paint and stale slot also retries" do
    {owner, runtime} = owner()
    ready(owner)
    scene(runtime, 2)
    send(owner, {:draw, "old", 1})
    assert_receive {:draw_result, "old", 1, {:error, :stale_revision}}
    send(owner, {:draw, "new", 2})
    :sys.get_state(owner)
    record(owner, <<1, 23, 1::64, 1::64, 2::64>>)
    assert_receive {:draw_result, "new", 2, {:error, :stale_revision}}
    refute_receive {:draw_result, _, _, :ok}, 30
    assert :sys.get_state(owner).pending == nil
  end

  test "shutdown acknowledges only the correlated restoration, remains alive for runtime" do
    {owner, _runtime} = owner()
    ready(owner)
    send(owner, {:terminal_control, :shutdown, "shutdown"})
    state = :sys.get_state(owner)
    assert state.control == {:shutdown, 1, "shutdown"}
    refute_receive {:terminal_shutdown, _, _}, 30
    record(owner, <<1, 19, 1::64, 1::64, 0>>)
    assert_receive {:terminal_shutdown, "shutdown", :ok}
    assert Process.alive?(owner)
  end

  @tag capture_log: true
  test "uncorrelated native input terminates with a fixed redacted failure" do
    {owner, _} = owner()
    ready(owner)
    monitor = Process.monitor(owner)
    port = :sys.get_state(owner).port
    body = <<1, 17, 1::64, 99::64, 0, 0, 10, 0>>
    send(owner, {port, {:data, <<byte_size(body)::32, body::binary>>}})
    assert_receive {:DOWN, ^monitor, :process, ^owner, :terminal_protocol_failed}, 4000
  end

  test "in-flight paint and credit can settle after shutdown without reviving input" do
    {owner, runtime} = owner()
    ready(owner)
    scene(runtime, 1)
    send(owner, {:draw, "initial", 1})
    :sys.get_state(owner)
    record(owner, <<1, 18, 1::64, 1::64, 1::64>>)
    scene(runtime, 9)
    send(owner, {:draw, "paint", 9})
    :sys.get_state(owner)
    send(owner, {:terminal_control, :shutdown, "close"})
    state = :sys.get_state(owner)
    assert state.control == {:shutdown, 2, "close"}
    state = record(owner, <<1, 18, 1::64, 2::64, 9::64>>)
    assert state.phase == :closing
    assert state.timer != nil
    record(owner, <<1, 17, 1::64, 1::64, 0, 0, 10, 0>>)
    refute_receive {:input, _}, 30
    assert :sys.get_state(owner).counter == 2
    record(owner, <<1, 19, 1::64, 2::64, 0>>)
    assert_receive {:terminal_shutdown, "close", :ok}
  end

  test "protocol suspend and resume advance UI generation while wire generation stays one" do
    {owner, runtime} = owner()
    ready(owner)
    scene(runtime, 1)
    send(owner, {:draw, "draw", 1})
    :sys.get_state(owner)
    record(owner, <<1, 18, 1::64, 1::64, 1::64>>)
    send(owner, {:terminal_control, :suspend, 1})
    assert :sys.get_state(owner).control == {:suspend, 2}
    record(owner, <<1, 19, 1::64, 2::64, 1>>)
    assert_receive {:action, {:terminal_lifecycle, :suspended, 1, :runtime}}
    send(owner, {:terminal_control, :resume, 1})
    assert :sys.get_state(owner).control == {:resume, 3}
    ready(owner)
    assert_receive {:action, {:terminal_capabilities, 2, _}}
    assert_receive {:action, {:terminal_lifecycle, :resumed, 2, :runtime}}
    assert :sys.get_state(owner).credit == nil
    scene(runtime, 2)
    send(owner, {:draw, "after-resume", 2})
    state = :sys.get_state(owner)
    assert state.credit == nil
    record(owner, <<1, 18, 1::64, 2::64, 2::64>>)
    assert :sys.get_state(owner).credit == 4
    assert_receive {:draw_result, "after-resume", 2, :ok}
  end

  test "external resume barrier retires queued draw and credit before a fresh Ready" do
    {owner, runtime} = owner()
    ready(owner)
    scene(runtime, 1)
    send(owner, {:draw, "initial", 1})
    :sys.get_state(owner)
    record(owner, <<1, 18, 1::64, 1::64, 1::64>>)
    scene(runtime, 2)
    send(owner, {:draw, "old", 2})
    :sys.get_state(owner)
    state = record(owner, <<1, 24, 1::64>>)
    assert state.control == {:resume, 2}
    assert state.phase == :resuming
    assert state.credit == nil
    assert state.pending == nil
    assert_receive {:draw_result, "old", 2, {:error, :stale_revision}}
    ready(owner)
    assert_receive {:action, {:terminal_capabilities, 2, _}}
    scene(runtime, 3)
    send(owner, {:draw, "new", 3})
    state = :sys.get_state(owner)
    assert state.credit == nil
    assert state.pending == {3, 3, "new"}
    record(owner, <<1, 18, 1::64, 3::64, 3::64>>)
    assert_receive {:draw_result, "new", 3, :ok}
    assert :sys.get_state(owner).credit == 3
  end

  @tag capture_log: true
  test "a stalled native reader cannot block the owner's shutdown deadline" do
    runtime = start_supervised!({Runtime, self()})
    size = %Size{columns: 500, rows: 200}

    owner =
      start_supervised!(
        {Owner,
         runtime: runtime,
         capabilities: %Capabilities{size: size},
         flags: %{alternate?: false, focus?: true, paste?: true},
         executable: Path.expand("../../../../support/terminal_wire_stalled.sh", __DIR__)}
      )

    {:os_pid, os_pid} = Port.info(:sys.get_state(owner).port, :os_pid)

    on_exit(fn ->
      System.cmd("/bin/kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end)

    record(owner, <<1, 16, 1::64, 500::16, 200::16, 6>>)

    {scene, _} =
      Projector.project(Fixtures.representative(:chat, size, %Capabilities{size: size}))

    :ok = GenServer.call(runtime, {:put, %{scene | revision: 1}})
    monitor = Process.monitor(owner)
    send(owner, {:draw, "large", 1})
    send(owner, {:terminal_control, :shutdown, "close"})
    assert_receive {:DOWN, ^monitor, :process, ^owner, :terminal_protocol_failed}, 4500
  end
end
