defmodule SwarmCode.Domain.R1019UIStateDeleteTest do
  @moduledoc """
  Pass 77 D-ARCH-11 (CLI side): `UIState` subscribes to the data layer's
  delete notice, so the state remembered for a deleted conversation goes away
  on the message and not only through a direct call. The engine notifier the
  synced code reads is configured to the CLI's own notifications module.
  """
  use ExUnit.Case, async: false

  alias SwarmCode.Domain.{Conversations, UIState}

  defp remembered(id) do
    # `expanded` is a per-key set: it is folded by `update/3`, not by `put/2`.
    UIState.update(id, :expanded, fn _ -> MapSet.new(["card-1"]) end)
    assert UIState.get(id).expanded == MapSet.new(["card-1"])
  end

  defp eventually(fun, attempts \\ 200) do
    cond do
      fun.() ->
        true

      attempts == 0 ->
        false

      true ->
        receive do
        after
          10 -> eventually(fun, attempts - 1)
        end
    end
  end

  test "the delete notice clears a conversation's remembered UI state" do
    id = Ecto.UUID.generate()
    other = Ecto.UUID.generate()
    remembered(id)
    remembered(other)

    Conversations.broadcast_deleted(id)

    assert eventually(fn -> UIState.get(id).expanded == MapSet.new() end)
    # Another conversation's state is untouched.
    assert UIState.get(other).expanded == MapSet.new(["card-1"])
    UIState.delete(other)
  end

  test "the notice also drops a window row and the open mark of the conversation" do
    id = Ecto.UUID.generate()

    window = %{
      side_open?: true,
      side_run_id: nil,
      pane_view: nil,
      pane_hidden: nil,
      side_cards_collapsed?: false,
      side_sections: %{}
    }

    UIState.put_window(id, "window-1", window)
    assert UIState.get_window(id, "window-1").side_open? == true

    Conversations.broadcast_deleted(id)

    assert eventually(fn -> UIState.get_window(id, "window-1").side_open? == false end)
  end

  test "the engine notifier is the CLI's notifications module" do
    assert Application.get_env(:swarm_code_daemon, :engine_notifier) ==
             SwarmCode.Domain.Notifications

    Code.ensure_loaded!(SwarmCode.Domain.Notifications)
    assert function_exported?(SwarmCode.Domain.Notifications, :notify_waiting, 1)
    assert function_exported?(SwarmCode.Domain.Notifications, :notify_finished, 1)
  end
end
