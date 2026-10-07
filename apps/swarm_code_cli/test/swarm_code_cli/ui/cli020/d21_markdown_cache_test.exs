defmodule SwarmCodeCLI.UI.Cli020.D21MarkdownCacheTest do
  @moduledoc """
  cli020 D21 (tui-code-17): the markdown row cache never passes 4 MiB, evicts
  the least recently merged keys, and a conversation switch empties it.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias SwarmCodeCLI.Test.Cli020Runtime
  alias SwarmCodeCLI.UI.{MarkdownCache, Projector}

  @chunk String.duplicate("x", 1_048_576)

  test "byte-bounded, least recently merged first" do
    cache =
      Enum.reduce(1..6, MarkdownCache.new(:a), fn n, cache ->
        MarkdownCache.merge(cache, %{n => @chunk}, :a)
      end)

    assert cache.bytes <= MarkdownCache.max_bytes()
    assert MarkdownCache.get(cache, 1) == nil
    assert MarkdownCache.get(cache, 6) == @chunk
    # Merging an old key again makes it the newest.
    cache = MarkdownCache.merge(cache, %{4 => "small"}, :a)
    cache = MarkdownCache.merge(cache, %{7 => @chunk}, :a)
    assert MarkdownCache.get(cache, 4) == "small"
    assert cache.bytes <= MarkdownCache.max_bytes()
  end

  test "another scope starts empty; an entry over the bound is not kept" do
    cache = MarkdownCache.merge(nil, %{1 => "a"}, :a)
    assert MarkdownCache.get(cache, 1) == "a"
    switched = MarkdownCache.merge(cache, %{}, :b)
    assert switched.entries == %{} and switched.bytes == 0
    huge = MarkdownCache.merge(switched, %{2 => String.duplicate("y", 5_000_000)}, :b)
    assert huge.entries == %{}
  end

  test "the runtime merges the projector's rows, stays bounded and empties on a switch" do
    counter = :counters.new(1, [])

    projector = fn ui ->
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)
      {scene, table} = Projector.project(ui)
      {scene, Map.put(table, :markdown_rows, %{{:row, n} => @chunk})}
    end

    runtime = Cli020Runtime.start(projector: projector, os_type: {:unix, :linux}, env: %{})
    poke = fn -> Cli020Runtime.effect(runtime, {:paste_image, Cli020Runtime.conversation()}) end
    for _ <- 1..6, do: poke.()
    state = :sys.get_state(runtime)
    cache = state.ui.markdown_cache
    assert cache.bytes <= MarkdownCache.max_bytes()
    assert map_size(cache.entries) in 1..4
    refute Map.has_key?(state.table, :markdown_rows)

    :sys.replace_state(runtime, fn s ->
      %{s | ui: %{s.ui | destination: {:conversation, "another"}}}
    end)

    poke.()
    cache = :sys.get_state(runtime).ui.markdown_cache
    assert cache.scope == {:conversation, "another"}
    assert map_size(cache.entries) == 1
  end
end
