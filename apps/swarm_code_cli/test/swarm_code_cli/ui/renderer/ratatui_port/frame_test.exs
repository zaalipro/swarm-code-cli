defmodule SwarmCodeCLI.UI.Renderer.RatatuiPort.FrameTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.UI.{Size, Paint}
  alias SwarmCodeCLI.UI.Paint.Plan
  alias SwarmCodeCLI.UI.Scene.Cursor
  alias SwarmCodeCLI.UI.Renderer.RatatuiPort.Frame

  defp plan do
    %Plan{
      revision: 7,
      size: %Size{columns: 3, rows: 1},
      color_mode: :truecolor,
      cells: {{:glyph, "界", 2, 0}, {:continuation, 0}, {:glyph, "x", 1, 1}},
      palette: {
        %{foreground: {:rgb, 255, 128, 0}, background: nil, modifiers: [:bold]},
        %{foreground: {:indexed, 200}, background: {:ansi, :blue}, modifiers: [:reversed]}
      },
      cursor: %Cursor{x: 2, y: 0, shape: :bar}
    }
  end

  test "draw bytes have an exact bounded versioned layout with declared glyph widths" do
    assert :ok = Plan.validate(plan())
    assert {:ok, iodata} = Frame.encode(plan(), 9)

    body =
      <<1, 3, 9::64, 7::64, 3::16, 1::16, 0, 3, 2::16, 1, 2::16, 0::16, 1, 1, 2::32, 3, 255, 128,
        0, 0, 1, 2, 200, 1, 4, 16, 2::16, 0::16, 3::32, "界", 1::16, 1::16, 1::32, "x">>

    assert IO.iodata_to_binary(iodata) == <<byte_size(body)::32, body::binary>>
  end

  test "opaque actions and focus metadata do not cross the terminal transport" do
    p = plan()

    decorated = %{
      p
      | focus: %{region_id: "private-focus", control_id: nil},
        diagnostics: [{:clipped_action, "private-action"}]
    }

    assert :ok = Plan.validate(decorated)
    assert Frame.encode(decorated, 1) == Frame.encode(p, 1)
    {:ok, bytes} = Frame.encode(decorated, 1)
    refute IO.iodata_to_binary(bytes) =~ "private"
  end

  test "mode, width policy, cursor and modifiers have closed exact codes" do
    p = %{
      plan()
      | size: %Size{columns: 1, rows: 1},
        cells: {{:glyph, "x", 1, 0}},
        palette:
          {%{
             foreground: nil,
             background: nil,
             modifiers: [:reversed, :underlined, :italic, :dim, :bold]
           }},
        cursor: nil
    }

    for {mode, code} <- [monochrome: 0, ansi16: 1, ansi256: 2, truecolor: 3],
        {policy, policy_code} <- [narrow: 0, wide: 1] do
      {:ok, bytes} = Frame.encode(%{p | color_mode: mode, ambiguous_width: policy}, 0)

      assert <<_length::32, 1, 3, 0::64, 7::64, 1::16, 1::16, ^policy_code, ^code, 1::16, 0,
               1::32, 0, 0, 31, 1::16, 0::16, 1::32, "x">> = IO.iodata_to_binary(bytes)
    end

    for {shape, code} <- [block: 0, bar: 1, underline: 2] do
      {:ok, bytes} =
        Frame.encode(%{p | cursor: %Cursor{x: 0, y: 0, shape: shape, visible?: false}}, 0)

      assert <<_length::32, _header::binary-size(26), 1, 0::16, 0::16, ^code, 0, _rest::binary>> =
               IO.iodata_to_binary(bytes)
    end
  end

  test "malformed Plans and non-u64 sequence numbers reject before producing bytes" do
    for p <- [
          nil,
          %{},
          %{plan() | cells: {{:glyph, "\e[2J", 3, 0}}},
          %{plan() | size: %Size{columns: 501, rows: 1}}
        ] do
      assert {:error, :invalid_frame} = Frame.encode(p, 1)
    end

    for seq <- [-1, 18_446_744_073_709_551_616, "1", 1.0, nil] do
      assert {:error, :invalid_frame} = Frame.encode(plan(), seq)
    end

    assert {:ok, _} = Frame.encode(plan(), 18_446_744_073_709_551_615)
  end

  test "all current representative Plans encode without terminal or application startup" do
    alias SwarmCodeCLI.UI.{Capabilities, Fixtures, Projector}

    for kind <- [:chat, :swarm, :consensus, :research] do
      size = %Size{columns: 120, rows: 40}

      state =
        Fixtures.representative(kind, size, %Capabilities{size: size, color_mode: :truecolor})

      {scene, _} = Projector.project(state)
      {:ok, p} = Paint.build(scene)
      assert {:ok, bytes} = Frame.encode(p, 1)
      binary = IO.iodata_to_binary(bytes)
      assert <<length::32, body::binary>> = binary
      assert length == byte_size(body)
      assert length <= 33_554_432
    end
  end
end
