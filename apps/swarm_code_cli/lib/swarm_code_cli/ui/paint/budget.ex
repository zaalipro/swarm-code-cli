defmodule SwarmCodeCLI.UI.Paint.Budget do
  @moduledoc "Bounded structural admission before Scene validation or cell-grid allocation."
  alias SwarmCodeCLI.UI.{Scene, Size, SafeText}

  alias SwarmCodeCLI.UI.Scene.{
    Block,
    Rect,
    Region,
    Dialog,
    Cursor,
    Announcement,
    Span,
    Style,
    Color
  }

  # The node ceiling grows with the terminal: a scene is a few styled spans per
  # visible cell, so a fixed ceiling that fits 160x45 is exceeded by the same
  # conversation at 250x70 (rel F3). `@base_nodes` covers the fixed chrome and
  # `@nodes_per_cell` the worst row the projectors emit (one span per cell, a
  # dialog over the background), so an admitted size can always be drawn.
  @base_nodes 4096
  @nodes_per_cell 12
  @max_bytes 4_194_304
  @max_depth 32
  @max_structural_depth 128
  @display_structs Block.modules()
  @max_regions 64
  @max_actions 4096
  @uint64 18_446_744_073_709_551_615
  @structs [Scene, Size, SafeText, Rect, Region, Dialog, Cursor, Announcement, Span, Style, Color] ++
             Block.modules()
  @fields Map.new(@structs, fn module ->
            {module, module.__struct__() |> Map.keys() |> Enum.sort()}
          end)
  @id_fields [:id, :action_id, :focused_control_id, :before_cursor, :after_cursor]

  def limits,
    do: %{
      nodes: @base_nodes,
      bytes: @max_bytes,
      depth: @max_depth,
      regions: @max_regions,
      actions: @max_actions
    }

  def validate_scene(scene) do
    with :ok <- check(scene), :ok <- Scene.validate(scene) do
      :ok
    else
      {:error, :capacity_exceeded} = error -> error
      _ -> {:error, :invalid_scene}
    end
  rescue
    _ -> {:error, :invalid_scene}
  end

  @doc "The structural node ceiling for a scene of `columns` x `rows` cells."
  def node_limit(columns, rows)
      when is_integer(columns) and columns >= 0 and is_integer(rows) and rows >= 0,
      do: @base_nodes + @nodes_per_cell * min(columns * rows, 100_000)

  def node_limit(_, _), do: @base_nodes

  @doc false
  def check_display_list(items, cells \\ {0, 0})

  def check_display_list(items, {columns, rows}) when is_list(items) do
    case walk(items, 0, 0, counter(node_limit(columns, rows))) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  def check_display_list(_, _), do: {:error, :invalid_scene}

  def check(%Scene{size: size, regions: regions} = scene) do
    with :ok <- size(size),
         :ok <- list_limit(regions, @max_regions),
         {:ok, _} <- walk(scene, 0, 0, counter(node_limit(size.columns, size.rows))) do
      :ok
    end
  end

  def check(_), do: {:error, :invalid_scene}

  defp size(%Size{columns: columns, rows: rows} = size)
       when map_size(size) == 3 and is_integer(columns) and columns > 0 and is_integer(rows) and
              rows > 0 do
    if columns <= 500 and rows <= 200 and columns * rows <= 100_000,
      do: :ok,
      else: {:error, :capacity_exceeded}
  end

  defp size(_), do: {:error, :invalid_scene}

  defp list_limit([], _), do: :ok
  defp list_limit([_ | _], 0), do: {:error, :capacity_exceeded}
  defp list_limit([_ | rest], left), do: list_limit(rest, left - 1)
  defp list_limit(_, _), do: {:error, :invalid_scene}

  defp walk(_, depth, display_depth, _)
       when depth > @max_structural_depth or display_depth > @max_depth,
       do: {:error, :capacity_exceeded}

  defp walk(binary, _, _, count) when is_binary(binary) do
    bytes = count.bytes + byte_size(binary)
    if bytes <= @max_bytes, do: {:ok, %{count | bytes: bytes}}, else: {:error, :capacity_exceeded}
  end

  defp walk(integer, _, _, count)
       when is_integer(integer) and integer >= 0 and integer <= @uint64,
       do: {:ok, count}

  defp walk(atom, _, _, count) when is_atom(atom), do: {:ok, count}
  defp walk([], _, _, count), do: {:ok, count}

  defp walk([head | tail], depth, display_depth, count) do
    with {:ok, count} <- count_node(count),
         {:ok, count} <- walk(head, depth + 1, display_depth, count),
         do: walk_list(tail, depth, display_depth, count)
  end

  defp walk(%SafeText{token: token} = text, depth, display_depth, count)
       when is_atom(token) and map_size(text) == 2 do
    with {:ok, count} <- count_node(count) do
      walk(SafeText.value(text), depth, display_depth, count)
    end
  rescue
    _ -> {:error, :invalid_scene}
  end

  defp walk(%{__struct__: module} = map, depth, display_depth, count) when module in @structs do
    display_depth = display_depth + if(module in @display_structs, do: 1, else: 0)

    if map_size(map) == length(Map.fetch!(@fields, module)) and
         Enum.sort(Map.keys(map)) == Map.fetch!(@fields, module) do
      with true <- display_depth <= @max_depth, {:ok, count} <- count_node(count) do
        Enum.reduce_while(Map.to_list(map), {:ok, count}, fn
          {:__struct__, _}, current ->
            {:cont, current}

          {key, value}, {:ok, current} ->
            with :ok <- identifier(key, value),
                 {:ok, current} <- action(key, value, current),
                 {:ok, current} <- walk(value, depth + 1, display_depth, current) do
              {:cont, {:ok, current}}
            else
              error -> {:halt, error}
            end
        end)
      else
        false -> {:error, :capacity_exceeded}
        error -> error
      end
    else
      {:error, :invalid_scene}
    end
  end

  # A `Block.Columns` column is a plain map: its width and its own block list.
  defp walk(%{width: width, blocks: blocks} = column, depth, display_depth, count)
       when map_size(column) == 2 do
    with {:ok, count} <- count_node(count),
         {:ok, count} <- walk(width, depth + 1, display_depth, count),
         do: walk(blocks, depth + 1, display_depth, count)
  end

  defp walk(tuple, depth, display_depth, count) when is_tuple(tuple) and tuple_size(tuple) <= 4 do
    with {:ok, count} <- count_node(count) do
      Enum.reduce_while(Tuple.to_list(tuple), {:ok, count}, fn value, {:ok, current} ->
        case walk(value, depth + 1, display_depth, current) do
          {:ok, current} -> {:cont, {:ok, current}}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp walk(_, _, _, _), do: {:error, :invalid_scene}

  defp walk_list([], _, _, count), do: {:ok, count}

  defp walk_list([_ | _] = rest, depth, display_depth, count),
    do: walk(rest, depth, display_depth, count)

  defp walk_list(_, _, _, _), do: {:error, :invalid_scene}

  defp counter(max), do: %{nodes: 0, bytes: 0, actions: 0, max: max}

  defp count_node(%{nodes: count, max: max}) when count >= max, do: {:error, :capacity_exceeded}
  defp count_node(count), do: {:ok, %{count | nodes: count.nodes + 1}}

  defp action(:action_id, value, %{actions: actions} = count) when is_binary(value) do
    if actions < @max_actions,
      do: {:ok, %{count | actions: actions + 1}},
      else: {:error, :capacity_exceeded}
  end

  defp action(_, _, count), do: {:ok, count}

  defp identifier(key, value) when key in @id_fields and value != nil do
    if is_binary(value) and byte_size(value) in 1..256 and String.valid?(value) and
         not Enum.any?(String.to_charlist(value), &(&1 < 32 or &1 in 127..159)),
       do: :ok,
       else: {:error, :invalid_scene}
  end

  defp identifier(_, _), do: :ok
end
