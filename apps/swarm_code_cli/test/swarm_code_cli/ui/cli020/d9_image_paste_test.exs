defmodule SwarmCodeCLI.UI.Cli020.D9ImagePasteTest do
  @moduledoc """
  cli020 D9 (competitors-6, decision 4i): Ctrl-V attaches the clipboard's
  image through attachment.slot / attach_slot (C14) and osascript/sips.
  """
  use ExUnit.Case, async: false

  alias SwarmCodeCLI.Test.{Cli020Runtime, Cli020State}
  alias SwarmCodeCLI.UI.{Input, Keymap, Reducer, SessionRuntime}
  alias SwarmCodeCLI.UI.Reducer.{ImagePaste, Remote}

  @token String.duplicate("ab", 16)

  setup do
    dir = Path.join(System.tmp_dir!(), "ncode-d9-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{path: Path.join(dir, "slot.png")}
  end

  # A runner that answers `clipboard info` with `info` and writes a file for
  # each write/convert, recording every call.
  defp runner(test, info, fail \\ []) do
    fn exe, args, _ms ->
      send(test, {:ran, Path.basename(exe), args})

      cond do
        args == ["-e", "clipboard info"] ->
          {:ok, 0, info}

        Path.basename(exe) in fail ->
          {:ok, 1, "no"}

        Path.basename(exe) == "osascript" ->
          File.write!(List.last(args), "image")
          {:ok, 0, ""}

        Path.basename(exe) == "sips" ->
          [_, _, _, _, "--out", out] = args
          File.write!(out, "png")
          {:ok, 0, ""}
      end
    end
  end

  test "Ctrl-V in the composer is the image paste and emits its effect" do
    state = Cli020State.ready()

    assert {:ok, {:paste_image}} =
             Keymap.resolve(Input.text_fragment(:press, "v", [:control]), state, %{})

    assert {_state, [{:paste_image, conversation}]} = Reducer.update(state, {:paste_image})
    assert conversation == Cli020State.conversation()
  end

  test "the PNG path writes the clipboard's PNG to the slot path", %{path: path} do
    assert :ok = SessionRuntime.clipboard_image(runner(self(), "«class PNGf», 120"), path)
    assert File.read!(path) == "image"
    assert_received {:ran, "osascript", ["-e", "clipboard info"]}
    assert_received {:ran, "osascript", args}
    assert Enum.any?(args, &(&1 =~ "class PNGf"))
    refute_received {:ran, "sips", _}
  end

  test "the TIFF path converts with sips and removes the .tiff", %{path: path} do
    assert :ok = SessionRuntime.clipboard_image(runner(self(), "«class TIFF», 99"), path)
    assert File.read!(path) == "png"
    refute File.exists?(path <> ".tiff")
    assert_received {:ran, "sips", ["-s", "format", "png", _, "--out", ^path]}
  end

  test "no image in the clipboard writes nothing", %{path: path} do
    assert {:error, :no_image} =
             SessionRuntime.clipboard_image(runner(self(), "«class utf8», 4"), path)

    refute File.exists?(path)
  end

  test "a failed conversion deletes what it wrote", %{path: path} do
    assert {:error, :failed} =
             SessionRuntime.clipboard_image(runner(self(), "«class TIFF»", ["sips"]), path)

    refute File.exists?(path)
    refute File.exists?(path <> ".tiff")
  end

  test "the slot's answer asks the runtime to write the image there", %{path: path} do
    state = Cli020State.ready()
    c = Cli020State.conversation()
    request = %{kind: {:attachment_slot, c}, origin: {:conversation, :attachment}}

    assert {_, [{:paste_image_write, ^c, @token, ^path}]} =
             Remote.answer(state, request, {:ok, %{"token" => @token, "path" => path}})

    assert {state, []} = Remote.answer(state, request, {:ok, %{"token" => "x", "path" => path}})
    assert state.notice == {:command_feedback, "The image could not be attached."}
  end

  test "a finished write attaches the slot; no image says so" do
    state = Cli020State.ready()
    c = Cli020State.conversation()
    {_next, effects} = Reducer.update(state, {:paste_image_done, c, @token, :ok})
    assert Cli020State.commands(effects) == [{:attach_slot, c, @token}]

    {next, []} = Reducer.update(state, {:paste_image_done, c, @token, {:error, :no_image}})
    assert next.notice == {:command_feedback, "The clipboard has no image."}
  end

  test "not macOS and over SSH say why" do
    linux = Cli020Runtime.start(os_type: {:unix, :linux}, env: %{})
    Cli020Runtime.effect(linux, {:paste_image, Cli020Runtime.conversation()})

    assert eventually(fn -> SessionRuntime.snapshot(linux).notice end) ==
             {:command_feedback, ImagePaste.words(:not_macos)}
  end

  test "over SSH the clipboard is the other Mac's" do
    ssh = Cli020Runtime.start(os_type: {:unix, :darwin}, env: %{"SSH_CONNECTION" => "a 1 b 22"})
    Cli020Runtime.effect(ssh, {:paste_image, Cli020Runtime.conversation()})

    assert eventually(fn -> SessionRuntime.snapshot(ssh).notice end) ==
             {:command_feedback, ImagePaste.words(:ssh)}
  end

  defp eventually(fun, n \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, n) do
    case fun.() do
      {:command_feedback, _} = notice -> notice
      _ -> eventually(fun, n - 1)
    end
  end
end
