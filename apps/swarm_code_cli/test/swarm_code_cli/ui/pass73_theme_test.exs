defmodule SwarmCodeCLI.UI.Pass73ThemeTest do
  @moduledoc """
  pass73 T2: `/theme` switches dark/light live. The session runtime sends K's
  `{:terminal_preferences, %{theme: mode}}` to the port owner, which paints
  every later frame in that theme and drops the frame it kept in the old
  palette (the degraded-frame fallback). The start precedence is
  `SWARM_THEME` > cli.json > the desktop settings' mode > dark.
  """
  use ExUnit.Case, async: false

  alias SwarmCodeCLI.UI.{Capabilities, Fixtures, Projector, SceneSlot, Size, Theme}
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

  @size %Size{columns: 80, rows: 24}
  # Carbon light's page and the dark card surface.
  @light_page {:rgb, 0xF4, 0xF3, 0xF1}

  describe "the live switch reaches the port owner" do
    test "dark to light and back, from the next frame on" do
      {owner, runtime} = owner(:dark)
      ready(owner)

      draw(owner, runtime, 1)
      refute light?(:sys.get_state(owner).last_plan)

      send(owner, {:terminal_preferences, %{theme: :light}})
      assert %{theme: :light, last_plan: nil} = :sys.get_state(owner)
      draw(owner, runtime, 2)
      assert light?(:sys.get_state(owner).last_plan)

      send(owner, {:terminal_preferences, %{theme: :dark}})
      assert %{theme: :dark, last_plan: nil} = :sys.get_state(owner)
      draw(owner, runtime, 3)
      refute light?(:sys.get_state(owner).last_plan)
    end

    test "the same theme again keeps the kept frame; a mouse-only change leaves the theme and flags" do
      {owner, runtime} = owner(:light)
      ready(owner)
      draw(owner, runtime, 1)
      kept = :sys.get_state(owner).last_plan
      flags = :sys.get_state(owner).flags

      send(owner, {:terminal_preferences, %{theme: :light}})
      assert :sys.get_state(owner).last_plan == kept

      send(owner, {:terminal_preferences, %{mouse?: false}})
      assert %{theme: :light, flags: ^flags} = :sys.get_state(owner)

      # Nonsense is ignored: the owner answers and keeps its theme.
      send(owner, {:terminal_preferences, %{theme: :sepia}})
      assert :sys.get_state(owner).theme == :light
    end
  end

  describe "precedence at start" do
    test "SWARM_THEME beats cli.json beats the desktop settings beats dark" do
      assert Theme.mode("light", "dark", "dark") == :light
      assert Theme.mode("dark", "light", "light") == :dark
      assert Theme.mode(nil, "light", "dark") == :light
      assert Theme.mode(nil, :dark, "light") == :dark
      assert Theme.mode(nil, nil, "light") == :light
      assert Theme.mode(nil, nil, nil) == :dark
      # An unknown value falls through to the next source.
      assert Theme.mode("sepia", "light", nil) == :light
      assert Theme.mode("", nil, "blue") == :dark
      # The two-argument form of pass 71 is the same rule without cli.json.
      assert Theme.mode("light", "dark") == :light
      assert Theme.mode(nil, "light") == :light
    end

    test "the confirmation says SWARM_THEME still wins at the next launch" do
      assert Theme.switch_words(:light, nil) == "Theme: light · /theme switches back"
      assert Theme.switch_words(:light, "light") == "Theme: light · /theme switches back"

      assert Theme.switch_words(:light, "dark") ==
               "Theme: light · /theme switches back · SWARM_THEME=dark still wins at the next launch"

      assert Theme.env_mode(" Light ") == :light
      assert Theme.env_mode("nope") == nil
    end
  end

  # ------------------------------------------------------------------ helpers

  defp owner(theme) do
    runtime = start_supervised!({Runtime, self()})

    owner =
      start_supervised!(
        {Owner,
         runtime: runtime,
         capabilities: %Capabilities{size: @size, color_mode: :truecolor},
         theme: theme,
         flags: %{alternate?: false, focus?: true, paste?: true},
         executable: Path.expand("../../support/terminal_wire_sink.sh", __DIR__)}
      )

    {owner, runtime}
  end

  defp record(owner, body) do
    port = :sys.get_state(owner).port
    send(owner, {port, {:data, <<byte_size(body)::32, body::binary>>}})
    :sys.get_state(owner)
  end

  defp ready(owner), do: record(owner, <<1, 16, 1::64, 80::16, 24::16, 6>>)

  # One frame at `revision`, confirmed as painted.
  defp draw(owner, runtime, revision) do
    {scene, _} =
      Projector.project(Fixtures.representative(:chat, @size, %Capabilities{size: @size}))

    :ok = GenServer.call(runtime, {:put, %{scene | revision: revision}})
    send(owner, {:draw, "t#{revision}", revision})
    :sys.get_state(owner)
    record(owner, <<1, 18, 1::64, revision::64, revision::64>>)
    assert_receive {:draw_result, _, ^revision, :ok}
  end

  defp light?(plan) do
    plan.palette |> Tuple.to_list() |> Enum.any?(&(&1.background == @light_page))
  end
end
