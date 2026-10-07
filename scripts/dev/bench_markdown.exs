# cli020 E31 (tui-code-17): the Markdown row cache's bench on the locked
# fixture (`UI.Fixtures.long_conversation/3`, 200 messages).
#
#   cd apps/swarm_code_cli && mise exec -- mix run --no-start ../../scripts/dev/bench_markdown.exs
#
# It projects the fixture `@frames` times cold (no cache, the projector parses
# every visible message each frame) and, when the projector reports its
# computed rows (`Projector.project_reporting/1`), warm (the reported rows put in
# `state.markdown_cache` as D21's runtime does). It prints the median frame
# time, the reductions per frame, the post-GC heap of the projecting process,
# the cache's entries and bytes, and whether the warm scene equals the cold one.
defmodule SwarmCode.Development.BenchMarkdown do
  @moduledoc false

  alias SwarmCodeCLI.UI.{Capabilities, Fixtures, Projector, Size}

  @frames 40

  def run do
    size = %Size{columns: 160, rows: 50}
    caps = %Capabilities{size: size, color_mode: :truecolor}
    state = Fixtures.long_conversation(size, caps, 200)

    {cold_scene, _table, rows} = reporting(state)
    cold = measure(fn -> Projector.project(state) end)

    IO.puts("fixture: 200 messages, #{size.columns}x#{size.rows}, #{@frames} frames")
    report("cold", cold)
    IO.puts("computed per cold frame: #{map_size(rows)} Markdown blocks")

    if rows != %{} do
      warm_state = Map.put(state, :markdown_cache, %{entries: rows, bytes: bytes(rows)})
      {warm_scene, _table, again} = reporting(warm_state)
      warm = measure(fn -> Projector.project(warm_state) end)
      report("warm", warm)
      IO.puts("computed per warm frame: #{map_size(again)}")
      IO.puts("cache: #{map_size(rows)} entries, #{bytes(rows)} bytes (external term size)")
      IO.puts("golden: warm scene == cold scene: #{warm_scene == cold_scene}")
    end
  end

  # Before E31 there is no report: the cold frame alone is measured.
  defp reporting(state) do
    if Code.ensure_loaded?(Projector) and function_exported?(Projector, :project_reporting, 1) do
      Projector.project_reporting(state)
    else
      {scene, table} = Projector.project(state)
      {scene, table, %{}}
    end
  end

  defp measure(fun) do
    :erlang.garbage_collect()
    {:reductions, r0} = Process.info(self(), :reductions)

    times =
      for _ <- 1..@frames do
        {us, _} = :timer.tc(fun)
        us
      end

    {:reductions, r1} = Process.info(self(), :reductions)
    :erlang.garbage_collect()
    {:memory, memory} = Process.info(self(), :memory)
    %{median_us: median(times), reductions: div(r1 - r0, @frames), memory: memory}
  end

  defp report(label, m),
    do:
      IO.puts(
        "#{label}: median #{Float.round(m.median_us / 1000, 2)} ms/frame · " <>
          "#{m.reductions} reductions/frame · post-GC process memory #{m.memory} bytes"
      )

  defp median(list), do: list |> Enum.sort() |> Enum.at(div(length(list), 2))
  defp bytes(rows), do: rows |> :erlang.term_to_binary() |> byte_size()
end

SwarmCode.Development.BenchMarkdown.run()
