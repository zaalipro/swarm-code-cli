defmodule SwarmCodeCLI.UI.Renderer.RatatuiPort.Cli020PortTest do
  @moduledoc """
  cli020 lane D, the Elixir half of the terminal port wire: Ready's
  enhanced-keys bit (D2), Notify tag 9 (D3), the Scroll input kind 7 (D5) and
  Redraw tag 10 (D11).
  """
  use ExUnit.Case, async: false
  import Bitwise
  alias SwarmCodeCLI.UI.{Capabilities, SceneSlot, Size}
  alias SwarmCodeCLI.UI.Renderer.RatatuiPort.{Owner, Wire}

  defmodule Runtime do
    use GenServer
    def start_link(test), do: GenServer.start_link(__MODULE__, test)
    def init(test), do: {:ok, %{test: test, slot: SceneSlot.new()}}

    def handle_call({:terminal, owner, generation, caps}, _, state) do
      send(state.test, {:registered, owner, generation, caps})
      {:reply, {:ok, state.slot}, state}
    end

    def handle_call(request, _, state) do
      send(state.test, request)
      {:reply, :ok, state}
    end

    def handle_info(message, state) do
      send(state.test, message)
      {:noreply, state}
    end
  end

  defp owner(flags \\ %{alternate?: true, focus?: true, paste?: true}) do
    runtime = start_supervised!({Runtime, self()})
    caps = %Capabilities{size: %Size{columns: 80, rows: 24}}

    owner =
      start_supervised!(
        {Owner,
         runtime: runtime,
         capabilities: caps,
         flags: flags,
         executable: Path.expand("../../../../support/terminal_wire_sink.sh", __DIR__)}
      )

    {owner, runtime}
  end

  defp record(owner, body) do
    port = :sys.get_state(owner).port
    send(owner, {port, {:data, <<byte_size(body)::32, body::binary>>}})
    :sys.get_state(owner)
  end

  describe "D2: Ready's enhanced-keys bit" do
    test "the wire takes bit 128 in Ready only" do
      assert {:ok, {:ready, 1, %Size{columns: 80, rows: 24}, 135}} =
               Wire.decode(<<1, 16, 1::64, 80::16, 24::16, 135>>)

      assert {:error, :invalid_record} = Wire.decode(<<1, 16, 1::64, 80::16, 24::16, 8>>)
    end

    test "a Ready with the bit registers enhanced keys as supported" do
      {owner, _runtime} = owner()
      record(owner, <<1, 16, 1::64, 80::16, 24::16, 7 ||| 128>>)
      assert_receive {:registered, ^owner, 1, caps}
      assert caps.enhanced_keys == :supported
    end

    test "a Ready without it keeps enhanced keys unavailable" do
      {owner, _runtime} = owner()
      record(owner, <<1, 16, 1::64, 80::16, 24::16, 7>>)
      assert_receive {:registered, ^owner, 1, caps}
      assert caps.enhanced_keys == :unavailable
    end
  end

  describe "D5: the Scroll input" do
    test "input kind 7 decodes to {:scroll, direction, count}" do
      assert {:ok, {:input, 1, 9, {:scroll, :up, 3}}} =
               Wire.decode(<<1, 17, 1::64, 9::64, 7, 1, 3>>)

      assert {:ok, {:input, 1, 9, {:scroll, :down, 32}}} =
               Wire.decode(<<1, 17, 1::64, 9::64, 7, 0, 32>>)

      for bad <- [<<7, 2, 3>>, <<7, 1, 0>>, <<7, 1, 33>>, <<7, 1>>] do
        assert {:error, :invalid_record} = Wire.decode(<<1, 17, 1::64, 9::64, bad::binary>>)
      end
    end
  end

  describe "D3: the Notify command" do
    test "encodes the three kinds exactly" do
      assert {:ok, <<21::32, 1, 9, 1::64, 4::64, 0, 0::16>>} = Wire.notify(1, 4, :bell, "")
      title = "ncode · demo"

      assert {:ok, <<len::32, 1, 9, 1::64, 5::64, 2, tl::16, ^title::binary>>} =
               Wire.notify(1, 5, :title, title)

      assert tl == byte_size(title) and len == 21 + tl

      assert {:ok, <<_::32, 1, 9, 1::64, 6::64, 1, _::16, "ncode: p finished">>} =
               Wire.notify(1, 6, :notification, "ncode: p finished")
    end

    test "refuses controls, a leading digit on a notification, and long texts" do
      for text <- ["a\e[0m", "bell\a", "line\n", "c1 \u009b", "del \x7f"] do
        assert {:error, :invalid_record} = Wire.notify(1, 1, :title, text)
      end

      assert {:error, :invalid_record} = Wire.notify(1, 1, :notification, "9;4")
      assert {:ok, _} = Wire.notify(1, 1, :title, "9 lives")
      assert {:ok, _} = Wire.notify(1, 1, :title, String.duplicate("a", 512))
      assert {:error, :invalid_record} = Wire.notify(1, 1, :title, String.duplicate("a", 513))
      assert {:error, :invalid_record} = Wire.notify(1, 1, :beep, "x")
    end
  end

  describe "D3: the owner sends Notify between frames" do
    test "a valid text spends a token; one the wire refuses is dropped" do
      {owner, _runtime} = owner()
      state = record(owner, <<1, 16, 1::64, 80::16, 24::16, 7>>)
      counter = state.counter
      send(owner, {:terminal_notify, :title, "ncode · demo"})
      assert :sys.get_state(owner).counter == counter + 1
      send(owner, {:terminal_notify, :title, "bad \e]0;x\a"})
      assert :sys.get_state(owner).counter == counter + 1
      send(owner, {:terminal_notify, :bell, ""})
      assert :sys.get_state(owner).counter == counter + 2
    end

    test "nothing is sent before Ready" do
      {owner, _runtime} = owner()
      counter = :sys.get_state(owner).counter
      send(owner, {:terminal_notify, :bell, ""})
      assert :sys.get_state(owner).counter == counter
    end
  end

  describe "D11: the Redraw control" do
    test "is the fixed 18-byte control tag 10" do
      assert {:ok, <<18::32, 1, 10, 1::64, 7::64>>} = Wire.control(:redraw, 1, 7)
    end
  end
end
