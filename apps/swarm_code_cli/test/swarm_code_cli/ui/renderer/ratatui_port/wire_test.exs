defmodule SwarmCodeCLI.UI.Renderer.RatatuiPort.WireTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.UI.Renderer.RatatuiPort.Wire
  alias SwarmCodeCLI.UI.Size

  test "init and control records have fixed exact layouts" do
    assert {:ok, <<11::32, 1, 1, 7::64, 7>>} =
             Wire.init(7, %{alternate?: true, focus?: true, paste?: true})

    assert {:ok, <<11::32, 1, 1, 7::64, 0>>} =
             Wire.init(7, %{alternate?: false, focus?: false, paste?: false})

    for {operation, tag} <- [credit: 2, shutdown: 4, suspend: 5, resume: 6] do
      assert {:ok, <<18::32, 1, ^tag, 7::64, 9::64>>} = Wire.control(operation, 7, 9)
    end

    assert {:error, :invalid_record} = Wire.control(:stop_run, 7, 9)
    assert {:error, :invalid_record} = Wire.control(:credit, -1, 9)

    # pass70 B10: the wheel is opt-in; any other extra key is refused.
    assert {:ok, <<11::32, 1, 1, 7::64, 23>>} =
             Wire.init(7, %{alternate?: true, focus?: true, paste?: true, mouse?: true})

    assert {:ok, <<11::32, 1, 1, 7::64, 7>>} =
             Wire.init(7, %{alternate?: true, focus?: true, paste?: true, mouse?: false})

    assert {:error, :invalid_record} =
             Wire.init(7, %{alternate?: true, focus?: true, paste?: true, mouse?: :yes})

    assert {:error, :invalid_record} =
             Wire.init(7, %{alternate?: true, focus?: true, paste?: true, keys?: true})

    assert {:error, :invalid_record} =
             Wire.init(7, %{alternate?: :yes, focus?: true, paste?: true})
  end

  test "native status records decode to closed generation-correlated values" do
    assert {:ok, {:ready, 7, %Size{columns: 120, rows: 40}, 7}} =
             Wire.decode(<<1, 16, 7::64, 120::16, 40::16, 7>>)

    assert {:ok, {:painted, 7, 9, 11}} = Wire.decode(<<1, 18, 7::64, 9::64, 11::64>>)
    assert {:ok, {:resume_needed, 7}} = Wire.decode(<<1, 24, 7::64>>)
    assert {:error, :invalid_record} = Wire.decode(<<1, 24, 7::64, 0>>)
    assert {:ok, {:skipped, 7, 9, 11}} = Wire.decode(<<1, 23, 7::64, 9::64, 11::64>>)
    assert {:ok, {:restored, 7, 9, :closed}} = Wire.decode(<<1, 19, 7::64, 9::64, 0>>)
    assert {:ok, {:restored, 7, 9, :suspended}} = Wire.decode(<<1, 19, 7::64, 9::64, 1>>)

    assert {:ok, {:input, 7, 9, {:resize, %Size{columns: 600, rows: 210}}}} =
             Wire.decode(<<1, 20, 7::64, 9::64, 600::16, 210::16>>)

    assert {:ok, {:error, 7, :restoration}} = Wire.decode(<<1, 21, 7::64, 6>>)
  end

  test "key, text, paste, rejection and focus payloads preserve exact neutral inputs" do
    assert {:ok,
            {:input, 7, 9, {:key, :repeat, :up, [:shift, :control, :alt, :super, :hyper, :meta]}}} =
             Wire.decode(<<1, 17, 7::64, 9::64, 0, 1, 4, 63>>)

    assert {:ok, {:input, 7, 9, {:key, :press, {:function, 12}, []}}} =
             Wire.decode(<<1, 17, 7::64, 9::64, 0, 0, 43, 0>>)

    text = "ა́界"

    assert {:ok, {:input, 7, 9, {:text_fragment, :release, ^text, [:alt]}}} =
             Wire.decode(<<1, 17, 7::64, 9::64, 1, 2, 4, byte_size(text)::16, text::binary>>)

    assert {:ok, {:input, 7, 9, {:paste, "\e[2J\n"}}} =
             Wire.decode(<<1, 17, 7::64, 9::64, 2, 5::32, "\e[2J\n">>)

    assert {:ok, {:input, 7, 9, {:rejected, :paste_too_large}}} =
             Wire.decode(<<1, 17, 7::64, 9::64, 3, 2>>)

    assert {:ok, {:input, 7, 9, :focus_gained}} = Wire.decode(<<1, 17, 7::64, 9::64, 4>>)
    assert {:ok, {:input, 7, 9, :focus_lost}} = Wire.decode(<<1, 17, 7::64, 9::64, 5>>)
  end

  test "bounded payloads reject unknown values, malformed UTF8 and trailing bytes" do
    for body <- [
          <<1, 16, 7::64, 0::16, 40::16, 7>>,
          <<1, 16, 7::64, 120::16, 40::16, 8>>,
          <<1, 17, 7::64, 9::64, 0, 0, 23, 0>>,
          <<1, 17, 7::64, 9::64, 0, 3, 4, 0>>,
          <<1, 17, 7::64, 9::64, 0, 0, 4, 64>>,
          <<1, 17, 7::64, 9::64, 1, 0, 0, 1::16, 255>>,
          <<1, 17, 7::64, 9::64, 1, 0, 0, 0::16>>,
          <<1, 17, 7::64, 9::64, 2, 1::32, 255>>,
          <<1, 17, 7::64, 9::64, 3, 3>>,
          <<1, 19, 7::64, 9::64, 2>>,
          <<1, 21, 7::64, 7>>,
          <<1, 18, 7::64, 9::64, 11::64, 0>>,
          <<2, 18, 7::64, 9::64, 11::64>>,
          <<1, 99>>,
          :not_bytes
        ] do
      assert {:error, :invalid_record} = Wire.decode(body)
    end

    paste = String.duplicate("x", 262_144)

    assert {:ok, {:input, 7, 9, {:paste, ^paste}}} =
             Wire.decode(<<1, 17, 7::64, 9::64, 2, 262_144::32, paste::binary>>)

    assert {:error, :invalid_record} =
             Wire.decode(<<1, 17, 7::64, 9::64, 2, 262_145::32, paste::binary, "x">>)

    text = String.duplicate("x", 4096)

    assert {:ok, {:input, 7, 9, {:text_fragment, :press, ^text, []}}} =
             Wire.decode(<<1, 17, 7::64, 9::64, 1, 0, 0, 4096::16, text::binary>>)

    assert {:error, :invalid_record} =
             Wire.decode(<<1, 17, 7::64, 9::64, 1, 0, 0, 4097::16, text::binary, "x">>)
  end

  # pass70 B10: clipboard text and wheel reports.
  test "copy records carry bounded inert UTF-8 and normalise CRLF" do
    text = "fn main() {\r\n\tok()\n}"
    sent = "fn main() {\n\tok()\n}"
    size = byte_size(sent)

    assert {:ok, <<len::32, 1, 7, 7::64, 9::64, ^size::32, ^sent::binary>>} =
             Wire.copy(7, 9, text)

    assert len == 22 + size
    assert {:ok, _} = Wire.copy(7, 9, String.duplicate("x", 65_536))

    for bad <- [
          "",
          String.duplicate("x", 65_537),
          "\e]52;c;evil\a",
          "bell\a",
          "lone\rcarriage",
          "rtl\u202e",
          "c1\u009b",
          <<255, 254>>
        ] do
      assert {:error, :invalid_record} = Wire.copy(7, 9, bad)
    end

    assert {:error, :invalid_record} = Wire.copy(-1, 9, "x")
    assert {:error, :invalid_record} = Wire.copy(7, 9, :text)
  end

  test "ready accepts the mouse flag and wheel payloads decode to mouse inputs" do
    assert {:ok, {:ready, 7, %Size{columns: 80, rows: 24}, 23}} =
             Wire.decode(<<1, 16, 7::64, 80::16, 24::16, 23>>)

    assert {:error, :invalid_record} = Wire.decode(<<1, 16, 7::64, 80::16, 24::16, 8>>)

    assert {:ok, {:input, 7, 9, {:mouse, :wheel_up, nil, 300, 2, []}}} =
             Wire.decode(<<1, 17, 7::64, 9::64, 6, 0, 0, 300::16, 2::16>>)

    assert {:ok, {:input, 7, 9, {:mouse, :wheel_down, nil, 0, 0, [:shift, :control]}}} =
             Wire.decode(<<1, 17, 7::64, 9::64, 6, 1, 3, 0::16, 0::16>>)

    for body <- [
          <<1, 17, 7::64, 9::64, 6, 2, 0, 0::16, 0::16>>,
          <<1, 17, 7::64, 9::64, 6, 0, 64, 0::16, 0::16>>,
          <<1, 17, 7::64, 9::64, 6, 0, 0, 0::16>>
        ] do
      assert {:error, :invalid_record} = Wire.decode(body)
    end
  end
end
