defmodule SwarmCodeCLI.Plain.FiniteInputTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.Demo.FiniteInput

  test "dead pending reader is retired before a replacement reads the next line" do
    input = start_supervised!(FiniteInput)

    reader =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    monitor = Process.monitor(reader)
    send(input, {:io_request, reader, make_ref(), {:get_chars, :unicode, "", 1}})
    assert :sys.get_state(input).waiter != nil
    Process.exit(reader, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^reader, :killed}
    assert :ok = FiniteInput.release_line(input, "next\n")
    assert :io.get_chars(input, "", 1) == "n"
    assert :io.get_chars(input, "", 1) == "e"
  end

  test "delivering text and EOF removes the reader monitor" do
    input = start_supervised!(FiniteInput)
    ref = make_ref()
    send(input, {:io_request, self(), ref, {:get_chars, :unicode, "", 1}})
    assert :sys.get_state(input).waiter != nil
    assert {:monitors, [{:process, owner}]} = Process.info(input, :monitors)
    assert owner == self()
    assert :ok = FiniteInput.release_line(input, "a\n")
    assert_receive {:io_reply, ^ref, "a"}
    assert Process.info(input, :monitors) == {:monitors, []}
    assert :io.get_chars(input, "", 1) == "\n"
    ref = make_ref()
    send(input, {:io_request, self(), ref, {:get_chars, :unicode, "", 1}})
    assert :ok = FiniteInput.eof(input)
    assert_receive {:io_reply, ^ref, :eof}
    assert Process.info(input, :monitors) == {:monitors, []}
  end

  test "unrelated DOWN cannot release another pending reader" do
    input = start_supervised!(FiniteInput)
    ref = make_ref()
    send(input, {:io_request, self(), ref, {:get_chars, :unicode, "", 1}})
    before = :sys.get_state(input)
    send(input, {:DOWN, make_ref(), :process, self(), :normal})
    assert :sys.get_state(input).waiter == before.waiter
    assert :ok = FiniteInput.release_line(input, "a\n")
    assert_receive {:io_reply, ^ref, "a"}
  end
end
