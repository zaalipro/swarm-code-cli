defmodule SwarmCodeCLI.Cli021.U2StatusLineTest do
  # cli021 U2 and U1's compact form: the status line says `worker <model>`,
  # `ctx` shows used / the model's window (`8k/1M`), and the vitals' compact
  # form (the busiest model's tok/s and RAM) where the panel is not drawn.
  use ExUnit.Case, async: true

  import SwarmCodeCLI.Cli020EHelpers

  alias SwarmCode.Settings.Registry

  @mb 1_048_576
  @vitals %{
    conversation_id: nil,
    models: [
      %{slot: :main, model: "deepseek-v4.1-flash", tps: 142, live: true, history: [140], at: nil},
      %{slot: :worker, model: "ms/glm-5.2", tps: 38, live: false, history: [38], at: 3}
    ],
    beam_bytes: 290 * @mb,
    os_rss_bytes: 300 * @mb,
    children_rss_bytes: 12 * @mb,
    machine_bytes: nil,
    sampled_at: 1
  }

  defp put_vitals(state, vitals \\ @vitals),
    do: %{state | read_model: Map.put(state.read_model, :vitals, vitals)}

  defp status(state), do: state |> screen() |> List.last()

  defp chat(size \\ {160, 30}),
    do:
      fixture(:chat, size)
      |> Map.put(:panel_mode, :auto)
      |> put_workspace(chat_model: "deepseek-v4.1-flash", approval_mode: "auto")

  describe "the worker slot" do
    test "reads worker <model>, never agents" do
      line = chat() |> put_workspace(swarm_model: "gpt-5.5") |> status()
      assert line =~ "deepseek-v4.1-flash · worker gpt-5.5"
      refute line =~ "agents "
    end

    test "says nothing while it is the chat model" do
      line = chat() |> put_workspace(swarm_model: "deepseek-v4.1-flash") |> status()
      refute line =~ "worker"
    end
  end

  describe "ctx" do
    test "used / the model's window" do
      line = chat() |> put_workspace(context_used: 8_000, context_window: 1_000_000) |> status()
      assert line =~ ~r/ctx \S+ 8k\/1M/

      line = chat() |> put_workspace(context_used: 26_000, context_window: 200_000) |> status()
      assert line =~ "26k/200k"

      line =
        chat() |> put_workspace(context_used: 1_234_567, context_window: 1_500_000) |> status()

      assert line =~ "1.2M/1.5M"

      line = chat() |> put_workspace(context_used: 8_000, context_window: 2_000_000) |> status()
      assert line =~ "8k/2M"
    end
  end

  describe "the compact vitals" do
    test "on the status line while the panel is hidden" do
      line = chat() |> put_vitals() |> status()
      assert line =~ "142 tok/s · RAM 312 MB"
    end

    test "not on the status line while the panel draws them" do
      state = fixture(:swarm, {160, 45}) |> Map.put(:panel_mode, :full) |> put_vitals()
      refute status(state) =~ "tok/s"
      assert screen_text(state) =~ "tok/s"
    end

    test "on the strip under 120 columns" do
      state = fixture(:swarm, {100, 30}) |> Map.put(:panel_mode, :full) |> put_vitals()
      [_title, strip | _] = screen(state)
      assert strip =~ "RAM 312 MB"
      refute status(state) =~ "RAM"
    end

    test "nothing streams: the newest measure, then RAM only" do
      idle = %{@vitals | models: [%{hd(@vitals.models) | live: false, history: [142], at: 9}]}
      assert chat() |> put_vitals(idle) |> status() =~ "142 tok/s · RAM 312 MB"

      none = %{@vitals | models: []}
      line = chat() |> put_vitals(none) |> status()
      assert line =~ "RAM 312 MB"
      refute line =~ "tok/s"
    end

    test "no vitals, no words" do
      refute chat() |> status() =~ "RAM"
    end

    test "the status item gives way first" do
      line = chat({100, 30}) |> put_vitals() |> put_workspace(context_used: 8_000) |> status()
      assert line =~ "deepseek-v4.1-flash"
    end

    # cli021 qa (found live at 120x40, panel hidden): while a model streamed,
    # the hints and the other facts left no room for the whole compact form,
    # so the tok/s went away exactly while it moved. A live speed now holds
    # its place before the worker, the cost and the RAM; RAM gives way first.
    test "a live speed holds its place; RAM gives way first" do
      state =
        chat({120, 30})
        |> put_workspace(
          swarm_model: "gpt-6-mini",
          context_used: 8_000,
          context_window: 1_000_000,
          cost_usd: 0.04
        )
        |> put_vitals()

      line = status(state)
      assert line =~ "142 tok/s"
      refute line =~ "RAM"
      assert line =~ ~r/ctx \S+ 8k\/1M/

      # Idle, the stale speed gives way before the RAM.
      idle = %{@vitals | models: [%{hd(@vitals.models) | live: false, history: [142], at: 9}]}
      line = chat({100, 30}) |> put_workspace(context_used: 8_000) |> put_vitals(idle) |> status()
      refute line =~ "tok/s"
    end

    test "the item is listed, in the default, and can be left out" do
      entry = Enum.find(Registry.all(), &(&1.key == "terminal.status_items"))
      assert "vitals" in entry.default
      assert "vitals" in Enum.map(entry.choices, & &1.value)

      line =
        chat() |> put_vitals() |> Map.put(:prefs, %{"status_items" => ~w(mode model)}) |> status()

      refute line =~ "tok/s"
    end
  end
end
