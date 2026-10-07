defmodule SwarmCodeCLI.Cli020.E31MarkdownCacheTest do
  # cli020 E31 (tui-code-17): the transcript's Markdown rows come from
  # `state.markdown_cache` when it holds them, and every computed entry is
  # reported by `Projector.project_reporting/1` (beside the action table). Golden equivalence: the scene of the
  # locked fixture is identical with an empty cache, a warm cache and a cache
  # evicted mid-way.
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{Capabilities, Fixtures, Projector, Size}
  alias SwarmCodeCLI.UI.Projector.MarkdownRows

  defp fixture({columns, rows}, caps \\ []) do
    size = %Size{columns: columns, rows: rows}
    caps = struct!(%Capabilities{size: size, color_mode: :truecolor}, caps)
    Fixtures.long_conversation(size, caps, 200)
  end

  defp warm(state, entries),
    do: Map.put(state, :markdown_cache, %{entries: entries, bytes: 0})

  for size <- [{160, 120}, {100, 40}, {80, 24}] do
    test "golden: empty, warm and half-evicted caches draw the same scene at #{inspect(size)}" do
      state = fixture(unquote(size))
      {cold, _table, computed} = Projector.project_reporting(state)
      assert map_size(computed) >= 1
      assert {^cold, _} = Projector.project(state)

      {warm_scene, _table, none} = Projector.project_reporting(warm(state, computed))
      assert warm_scene == cold
      assert none == %{}

      {kept, evicted} = computed |> Enum.sort() |> Enum.split(div(map_size(computed), 2))
      {half, _table, again} = Projector.project_reporting(warm(state, Map.new(kept)))
      assert half == cold

      assert again |> Map.keys() |> Enum.sort() ==
               evicted |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    end
  end

  test "the action table is the same cold and warm, and holds targets only" do
    state = fixture({120, 40})
    {_scene, table, computed} = Projector.project_reporting(state)
    {_scene, warm_table, _} = Projector.project_reporting(warm(state, computed))
    assert table == warm_table
    assert Enum.all?(Map.keys(table), &is_binary/1)
  end

  test "the key holds every input of the rows" do
    state = fixture({120, 40})
    ascii = fixture({120, 40}, ascii?: true, glyph_tier: :ascii)
    k = MarkdownRows.key("**x**", 40, state)
    refute k == MarkdownRows.key("**x**", 41, state)
    refute k == MarkdownRows.key("**y**", 40, state)
    refute k == MarkdownRows.key("**x**", 40, ascii)
    assert {<<_::256>>, 40, _, _, false} = k
  end

  test "an ASCII cache entry is never drawn on a rich frame" do
    rich = fixture({120, 40})
    ascii = fixture({120, 40}, ascii?: true, glyph_tier: :ascii)
    {_, _, ascii_rows} = Projector.project_reporting(ascii)
    {cold, _} = Projector.project(rich)
    {mixed, _} = Projector.project(warm(rich, ascii_rows))
    assert mixed == cold
  end

  test "the per-frame collection leaves nothing behind, even on a raise" do
    assert {_, %{}} = MarkdownRows.collect(fn -> :ok end)
    assert_raise RuntimeError, fn -> MarkdownRows.collect(fn -> raise "boom" end) end
    assert Process.get(MarkdownRows) == nil
  end
end
