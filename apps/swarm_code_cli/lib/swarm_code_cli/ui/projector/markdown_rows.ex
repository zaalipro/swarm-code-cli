defmodule SwarmCodeCLI.UI.Projector.MarkdownRows do
  @moduledoc """
  cli020 E31 (tui-code-17): the transcript's Markdown rows, cached across
  frames. A message's rows depend only on its text, the width they wrap to,
  the ambiguous-width policy and the glyph tier, so the key is
  `{sha256(text), inner, ambiguous, glyph tier, ascii?}` (collision-safe:
  the whole text is hashed, every input of `Markdown.rows/4` is in it).

  The projector stays a function of the state: it reads
  `state.markdown_cache` (D21: `%{entries: map, bytes: n}`, owned, bounded
  and evicted by the runtime) and reports each entry it computed this frame
  through `Projector.project_reporting/1`; the runtime merges them. A
  missing or evicted entry is computed again, to the same rows.

  Within one projection the computed entries are collected in the
  projecting process's dictionary by `collect/1` and removed on every exit
  path; nothing else is kept there.
  """
  alias SwarmCodeCLI.UI.Projector.Markdown

  @frame __MODULE__

  @doc "The cache key of `text` wrapped to `inner` cells under `state`'s capabilities."
  @spec key(String.t(), pos_integer(), map()) :: tuple()
  def key(text, inner, state) do
    caps = state.capabilities
    {:crypto.hash(:sha256, text), inner, caps.ambiguous_width, caps.glyph_tier, caps.ascii?}
  end

  @doc """
  `Markdown.rows/4` of `text` at `inner`, from the cache when it holds the
  key, else computed and reported.
  """
  @spec rows(String.t(), pos_integer(), map()) :: list()
  def rows(text, inner, state) do
    key = key(text, inner, state)

    case lookup(state, key) do
      {:ok, rows} ->
        rows

      :error ->
        rows =
          Markdown.rows(text, inner, state.capabilities.ambiguous_width,
            ascii?: state.capabilities.ascii?
          )

        report(key, rows)
        rows
    end
  end

  defp lookup(state, key) do
    case Map.fetch(entries(Map.get(state, :markdown_cache)), key) do
      {:ok, rows} ->
        {:ok, rows}

      :error ->
        case Process.get(@frame) do
          %{} = computed -> Map.fetch(computed, key)
          _ -> :error
        end
    end
  end

  defp entries(%{entries: %{} = entries}), do: entries
  defp entries(_none), do: %{}

  defp report(key, rows) do
    case Process.get(@frame) do
      %{} = computed -> Process.put(@frame, Map.put(computed, key, rows))
      _ -> :ok
    end
  end

  @doc """
  Runs `fun` (one projection) collecting the entries it computes; returns
  `{fun's result, computed}`. The collection is removed on every exit path.
  """
  @spec collect((-> result)) :: {result, map()} when result: term()
  def collect(fun) do
    case Process.get(@frame) do
      # A projection inside a projection: the outer one collects.
      %{} ->
        {fun.(), %{}}

      _ ->
        Process.put(@frame, %{})

        try do
          result = fun.()
          {result, Process.get(@frame) || %{}}
        after
          Process.delete(@frame)
        end
    end
  end
end
