defmodule SwarmCodeCLI.UI.Renderer.RatatuiPort.OwnerTest do
  use ExUnit.Case, async: false
  alias SwarmCodeCLI.UI.{Capabilities, Fixtures, Projector, SafeText, SceneSlot, Size}
  alias SwarmCodeCLI.UI.Scene.Block
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

  # pass71 F4 (V's request I-2/S-2): the launcher's theme reaches the paint;
  # without it the light palette was reachable only from tests.
  test "the theme the launcher chose paints the frame" do
    runtime = start_supervised!({Runtime, self()})
    caps = %Capabilities{size: %Size{columns: 80, rows: 24}, color_mode: :truecolor}

    owner =
      start_supervised!(
        {Owner,
         runtime: runtime,
         capabilities: caps,
         theme: :light,
         flags: %{alternate?: false, focus?: true, paste?: true},
         executable: Path.expand("../../../../support/terminal_wire_sink.sh", __DIR__)}
      )

    ready(owner)
    scene(runtime, 1)
    send(owner, {:draw, "light", 1})
    plan = :sys.get_state(owner).last_plan
    backgrounds = plan.palette |> Tuple.to_list() |> Enum.map(& &1.background)
    assert {:rgb, 0xF4, 0xF3, 0xF1} in backgrounds
  end

  test "rich terminals get the rich glyph tier from a hand-built capability set" do
    assert Capabilities.glyph_tier(:truecolor, :narrow, false, "xterm-ghostty") == :rich
    assert Capabilities.glyph_tier(:ansi256, :narrow, false, "xterm-ghostty") == :measured
    assert Capabilities.glyph_tier(:truecolor, :wide, false, "xterm-kitty") == :measured
    assert Capabilities.glyph_tier(:truecolor, :narrow, true, "xterm-kitty") == :measured
    assert Capabilities.glyph_tier(:truecolor, :narrow, false, "screen") == :measured
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
    # rel F17: the helper that never read its EOF was signalled away.
    refute os_alive?(os_pid)
  end

  # pass70 B2: a frame that cannot be painted never stops the owner.
  @tag capture_log: true
  test "a scene over the paint budget keeps the owner alive and draws an error line" do
    {owner, runtime} = owner()
    ready(owner)
    scene(runtime, 1)
    send(owner, {:draw, "first", 1})
    :sys.get_state(owner)
    record(owner, <<1, 18, 1::64, 1::64, 1::64>>)
    assert_receive {:draw_result, "first", 1, :ok}
    previous = :sys.get_state(owner).last_plan

    oversized(runtime, 2)
    send(owner, {:draw, "big", 2})
    state = :sys.get_state(owner)
    assert Process.alive?(owner)
    assert state.pending == {2, 2, "big"}
    assert MapSet.member?(state.draw_errors, :capacity_exceeded)
    assert last_row(state.last_plan) =~ "too large to draw"
    # Every row above the error line is the previous frame.
    %{columns: columns, rows: rows} = previous.size

    assert Enum.slice(Tuple.to_list(state.last_plan.cells), 0, columns * (rows - 1)) ==
             Enum.slice(Tuple.to_list(previous.cells), 0, columns * (rows - 1))

    record(owner, <<1, 18, 1::64, 2::64, 2::64>>)
    assert_receive {:draw_result, "big", 2, :ok}

    # The same failure again is drawn again but logged only once (state keeps
    # one entry per reason), and a good scene afterwards paints normally.
    oversized(runtime, 3)
    send(owner, {:draw, "big-again", 3})
    assert MapSet.size(:sys.get_state(owner).draw_errors) == 1
    record(owner, <<1, 18, 1::64, 3::64, 3::64>>)
    assert_receive {:draw_result, "big-again", 3, :ok}
    scene(runtime, 4)
    send(owner, {:draw, "good", 4})
    refute last_row(:sys.get_state(owner).last_plan) =~ "too large"
  end

  @tag capture_log: true
  test "a first frame that cannot be painted draws a blank screen with the error line" do
    {owner, runtime} = owner()
    ready(owner)
    oversized(runtime, 1)
    send(owner, {:draw, "big", 1})
    state = :sys.get_state(owner)
    assert state.pending == {1, 1, "big"}
    assert last_row(state.last_plan) =~ "too large to draw"
    assert :ok = SwarmCodeCLI.UI.Paint.Plan.validate(state.last_plan)
  end

  test "a slow paint is answered early, and the newest request is drawn after it" do
    {owner, runtime} = owner()
    ready(owner)
    scene(runtime, 1)
    send(owner, {:draw, "slow", 1})
    %{timer: {_, identity}} = :sys.get_state(owner)
    send(owner, {:deadline, identity, :draw})
    assert_receive {:draw_result, "slow", 1, {:error, :stale_revision}}
    assert :sys.get_state(owner).pending_replied?

    scene(runtime, 2)
    send(owner, {:draw, "queued", 2})
    assert :sys.get_state(owner).queued == {"queued", 2}
    scene(runtime, 3)
    send(owner, {:draw, "newest", 3})
    assert_receive {:draw_result, "queued", 2, {:error, :stale_revision}}
    state = record(owner, <<1, 18, 1::64, 1::64, 1::64>>)
    refute_receive {:draw_result, "slow", 1, :ok}, 30
    assert state.pending == {2, 3, "newest"}
    assert state.queued == nil
    record(owner, <<1, 18, 1::64, 2::64, 3::64>>)
    assert_receive {:draw_result, "newest", 3, :ok}
    assert Process.alive?(owner)
  end

  @tag capture_log: true
  test "a helper that ignores SIGTERM is killed when the owner stops" do
    runtime = start_supervised!({Runtime, self()})

    owner =
      start_supervised!(
        {Owner,
         runtime: runtime,
         capabilities: %Capabilities{size: %Size{columns: 80, rows: 24}},
         flags: %{alternate?: false, focus?: true, paste?: true},
         executable: Path.expand("../../../../support/terminal_wire_stubborn.sh", __DIR__)},
        restart: :temporary
      )

    {:os_pid, os_pid} = Port.info(:sys.get_state(owner).port, :os_pid)

    on_exit(fn ->
      System.cmd("/bin/kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end)

    assert os_alive?(os_pid)
    monitor = Process.monitor(owner)
    GenServer.stop(owner, :shutdown, 10_000)
    assert_receive {:DOWN, ^monitor, :process, ^owner, _}, 10_000
    refute os_alive?(os_pid)
  end

  defp oversized(runtime, revision) do
    size = %Size{columns: 80, rows: 24}

    {scene, _} =
      Projector.project(Fixtures.representative(:chat, size, %Capabilities{size: size}))

    [region | rest] = scene.regions
    padding = List.duplicate(%Block.Text{text: SafeText.chrome(:main)}, 5_000)

    scene = %{
      scene
      | revision: revision,
        regions: [%{region | blocks: region.blocks ++ padding} | rest]
    }

    :ok = GenServer.call(runtime, {:put, scene})
  end

  defp last_row(%{size: %{columns: columns, rows: rows}, cells: cells}) do
    cells
    |> Tuple.to_list()
    |> Enum.slice((rows - 1) * columns, columns)
    |> Enum.map_join(fn
      {:glyph, text, _, _} -> text
      _ -> ""
    end)
  end

  defp os_alive?(os_pid) do
    {_, status} =
      System.cmd("/bin/kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)

    status == 0
  end

  # pass70 B10: copy is asynchronous, validated in the caller, and spends a
  # control token only once the terminal is running.
  test "copy validates in the caller and sends only while running" do
    {owner, _runtime} = owner()
    before = :sys.get_state(owner).counter
    assert :ok = Owner.copy(owner, "early")
    assert :sys.get_state(owner).counter == before

    ready(owner)
    assert :ok = Owner.copy(owner, "hello\n\tworld")
    assert :sys.get_state(owner).counter == before + 1
    assert {:error, :invalid_text} = Owner.copy(owner, "\e[2J")
    assert {:error, :invalid_text} = Owner.copy(owner, "")
    assert :sys.get_state(owner).counter == before + 1

    # The renderer-neutral message the runtime sends; bad text is refused
    # without spending a token or stopping the owner.
    send(owner, {:terminal_copy, "from the runtime"})
    assert :sys.get_state(owner).counter == before + 2
    send(owner, {:terminal_copy, "\e]52;c;x\a"})
    assert :sys.get_state(owner).counter == before + 2
    assert Process.alive?(owner)
  end

  # pass70 F: the session runtime's `y` sends the acknowledged form and waits
  # for `{:terminal_copy_result, token, result}` from the owner.
  @tag capture_log: true
  test "the acknowledged copy answers the runtime with the result" do
    {owner, runtime} = owner()
    generation = :sys.get_state(owner).generation
    send(owner, {:terminal_copy, generation, :early, "early"})
    assert_receive {:terminal_copy_result, :early, {:error, :unavailable}}

    ready(owner)
    before = :sys.get_state(owner).counter
    send(owner, {:terminal_copy, generation, :ok, "two\nlines"})
    assert_receive {:terminal_copy_result, :ok, :ok}
    assert :sys.get_state(owner).counter == before + 1

    send(owner, {:terminal_copy, generation, :bad, "\e[2J"})
    assert_receive {:terminal_copy_result, :bad, {:error, :invalid_text}}

    send(owner, {:terminal_copy, generation + 7, :old, "stale"})
    assert_receive {:terminal_copy_result, :old, {:error, :stale_generation}}
    assert :sys.get_state(owner).counter == before + 1
    assert Process.alive?(owner) and Process.alive?(runtime)
  end

  test "the mouse flag is expected back in ready and reported as a capability" do
    runtime = start_supervised!({Runtime, self()})

    owner =
      start_supervised!(
        {Owner,
         runtime: runtime,
         capabilities: %Capabilities{size: %Size{columns: 80, rows: 24}},
         flags: %{alternate?: false, focus?: true, paste?: true, mouse?: true},
         executable: Path.expand("../../../../support/terminal_wire_sink.sh", __DIR__)}
      )

    record(owner, <<1, 16, 1::64, 80::16, 24::16, 22>>)
    assert_receive {:registered, ^owner, 1, caps}
    assert caps.mouse == :best_effort
    # pass70 F: the real runtime validates these capabilities when the terminal
    # registers; a closed set without :best_effort closed every SWARM_MOUSE=1
    # session at bind.
    assert {:ok, _} = SwarmCodeCLI.UI.Action.validate({:terminal_capabilities, 1, caps})
  end
end
