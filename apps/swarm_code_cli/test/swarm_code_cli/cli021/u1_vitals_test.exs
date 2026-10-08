defmodule SwarmCodeCLI.Cli021.U1VitalsTest do
  # cli021 U1: the side panel's top section shows the vitals (tok/s per model
  # with a sparkline, RAM as a bar with the number); the strip or the status
  # line shows the compact form when the panel is not drawn.
  use ExUnit.Case, async: true

  import SwarmCodeCLI.Cli020EHelpers

  alias SwarmCodeCLI.UI.{SafeText, Width}
  alias SwarmCodeCLI.UI.Projector.{Panel, Vitals}

  @mb 1_048_576
  # C2's `DTO.Vitals` / `DTO.ModelSpeed` shape (plain maps: the projector
  # reads them with `Map.get`).
  @vitals %{
    conversation_id: nil,
    models: [
      %{
        slot: :main,
        model: "deepseek-v4.1-flash",
        tps: 142,
        live: true,
        history: [60, 80, 120, 130, 142, 138, 120, 140, 150, 160, 150],
        at: nil
      },
      %{
        slot: :worker,
        model: "ms/glm-5.2",
        tps: 38,
        live: false,
        history: [10, 20, 25, 30, 38],
        at: 5
      },
      %{slot: :validator, model: "nv/glm-5.3", tps: nil, live: false, history: [], at: nil}
    ],
    beam_bytes: 250 * @mb,
    os_rss_bytes: 271 * @mb,
    children_rss_bytes: 41 * @mb,
    machine_bytes: 16 * 1024 * @mb,
    sampled_at: 1
  }

  defp put_vitals(state, vitals \\ @vitals),
    do: %{state | read_model: Map.put(state.read_model, :vitals, vitals)}

  defp texts(rows) do
    rows
    |> Enum.map(&elem(&1, 0))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn block -> Enum.map_join(block.spans, "", &SafeText.value(&1.text)) end)
  end

  defp swarm(size \\ {160, 45}, caps \\ []),
    do: fixture(:swarm, size, caps) |> Map.put(:panel_mode, :full) |> put_vitals()

  describe "the panel's top section" do
    test "speed rows, then RAM, above the run in chat, at every width exactly its width" do
      state = swarm()

      for width <- [56, 46, 40, 28] do
        rows = texts(Panel.plan(state, width, 43))
        policy = state.capabilities.ambiguous_width
        assert Enum.all?(rows, &(Width.cells(&1, policy) == width)), "width #{width}"

        [head | _] = rows
        assert head =~ ~r/^ speed +tok\/s $/
        assert Enum.any?(Enum.take(rows, 5), &(&1 =~ "RAM")), "width #{width}"
        assert Enum.any?(Enum.take(rows, 6), &(&1 =~ "312 MB")), "width #{width}"
        ram = Enum.find_index(rows, &(&1 =~ "312 MB"))
        title = Enum.find_index(rows, &(&1 =~ "architecture" or &1 =~ "review"))
        assert title == nil or title > ram
      end
    end

    test "the slot words at the widest dock; the breakdown as room allows" do
      wide = texts(Panel.plan(swarm(), 56, 43))
      assert Enum.any?(wide, &(&1 =~ ~r/main +deepseek-v4\.1-flash/))
      assert Enum.any?(wide, &(&1 =~ ~r/worker +ms\/glm-5\.2/))
      assert Enum.any?(wide, &(&1 =~ ~r/app 271 MB · tools 41 MB +of 16 GB $/))

      # The default dock (46) and narrower: the names keep their cells, the
      # dot's colour is the slot; the gauge says what it measures against.
      # The split gives way before the scale.
      for width <- [46, 40] do
        narrow = texts(Panel.plan(swarm(), width, 43))
        refute Enum.any?(narrow, &(&1 =~ "worker"))
        assert Enum.any?(narrow, &(&1 =~ "deepseek-v4.1-flash"))
        assert Enum.any?(narrow, &(&1 =~ ~r/of 16 GB $/))
        assert Enum.any?(narrow, &(&1 =~ "app 271")) == (width == 46)
      end
    end

    test "numbers end on one right edge; a long name is cut in its middle" do
      rows = texts(Panel.plan(swarm(), 28, 43))
      assert Enum.any?(rows, &(&1 =~ ~r/ 142 $/))
      assert Enum.any?(rows, &(&1 =~ ~r/  38 $/))
      assert Enum.any?(rows, &(&1 =~ ~r/312 MB $/))
      flash = Enum.find(rows, &(&1 =~ "142"))
      assert flash =~ "…"
      assert flash =~ "flash"
    end

    test "a model not measured yet says so with a dash" do
      rows = texts(Panel.plan(swarm(), 46, 43))
      assert Enum.any?(rows, &(&1 =~ ~r/nv\/glm-5\.3 +− $/))
    end

    test "no vitals draws the panel exactly as before" do
      bare = fixture(:swarm, {160, 45}) |> Map.put(:panel_mode, :full)
      nil_vitals = put_vitals(bare, nil)
      assert texts(Panel.plan(bare, 46, 43)) == texts(Panel.plan(nil_vitals, 46, 43))
      refute Enum.any?(texts(Panel.plan(bare, 46, 43)), &(&1 =~ "tok/s"))
    end

    test "a short pane keeps one vitals row; a tiny one none" do
      [one | rest] = texts(Panel.plan(swarm(), 46, 14))
      assert one =~ "142 tok/s"
      assert one =~ "RAM 312 MB"
      refute Enum.any?(rest, &(&1 =~ "tok/s"))
      refute Enum.any?(texts(Panel.plan(swarm(), 46, 8)), &(&1 =~ "tok/s"))
    end

    test "memory only: no speed heading" do
      state = swarm() |> put_vitals(%{models: [], beam_bytes: 2 * 1024 * @mb, sampled_at: 1})
      [first | _] = texts(Panel.plan(state, 46, 43))
      assert first =~ "RAM"
      assert first =~ "2 GB"
    end

    test "live is lit, idle is dim, through theme roles" do
      state = swarm({160, 45}, color_mode: :truecolor)
      plan = plan(state)
      {x, y} = locate(state, "deepseek-v4.1-flash")
      {ix, iy} = locate(state, "ms/glm-5.2")
      live = cell_style(plan, x, y)
      idle = cell_style(plan, ix, iy)
      assert live.foreground != idle.foreground
      # The live dot in the chat's colour, the idle one ghost.
      refute cell_style(plan, x - 2, y).foreground == cell_style(plan, ix - 2, iy).foreground
    end

    test "ASCII draws no glyph outside ASCII" do
      state = swarm({160, 45}, ascii?: true, color_mode: :monochrome)
      # Row 0 is the fake demo's banner (`FAKE DEMO — NO USER DATA`), not ours.
      text = state |> screen() |> tl() |> Enum.join("\n")
      assert text =~ "tok/s"
      leaked = Regex.scan(~r/[^\x00-\x7F·…]/u, text) |> List.flatten() |> Enum.uniq()
      assert leaked == []
    end
  end

  describe "the seam (C2's DTO)" do
    test "one model in two slots is one row naming both; the streaming slot's numbers" do
      [main | rest] = @vitals.models
      worker = %{main | slot: :worker, tps: 90, live: false, history: [90], at: 7}
      state = swarm() |> put_vitals(%{@vitals | models: [main, worker | rest]})
      rows = texts(Panel.plan(state, 56, 43))
      assert Enum.count(rows, &(&1 =~ "deepseek-v4.1-flash")) == 1
      assert Enum.any?(rows, &(&1 =~ ~r/main\+worker +deepseek-v4\.1-flash.* 142 $/))
    end

    test "another conversation's speeds are left out; the memory stays" do
      state =
        swarm()
        |> put_workspace(conversation_id: "shown")
        |> put_vitals(%{@vitals | conversation_id: "elsewhere"})

      rows = texts(Panel.plan(state, 46, 43))
      refute Enum.any?(rows, &(&1 =~ "tok/s"))
      assert Enum.any?(rows, &(&1 =~ "312 MB"))
    end

    test "before the first OS reading the VM's own total" do
      state =
        swarm() |> put_vitals(%{@vitals | os_rss_bytes: nil, children_rss_bytes: nil})

      rows = texts(Panel.plan(state, 56, 43))
      assert Enum.any?(rows, &(&1 =~ "250 MB"))
      refute Enum.any?(rows, &(&1 =~ "tools"))
    end
  end

  describe "the sparkline" do
    test "newest at the right, one shared scale, three tiers" do
      assert Vitals.spark([0, 50, 100], 100, 5, :rich) == "  ▁▅█"
      assert Vitals.spark([0, 50, 100], 100, 5, :measured) == "  ⡀⣦⣿"
      assert Vitals.spark([0, 50, 100], 100, 5, :ascii) == "  _=#"
      assert Vitals.spark([10, 20, 30, 40], 40, 2, :rich) == "▆█"
      assert Vitals.spark([], 0, 3, :rich) == "   "
    end
  end
end
