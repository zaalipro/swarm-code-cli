defmodule SwarmCodeCLI.UI.Home.Canvas do
  @moduledoc """
  orbit U5: Home's screen as a grid of cells. Home is drawn the way the designer
  drew it (`gen_D.py`): text, braille and backgrounds placed by row and column,
  one thing over another, so it is built on a canvas and cut into scene rows at
  the end, not assembled from stacked blocks.

  A cell is a grapheme with a style role (`:text_primary`, `{:accent, [:bold]}`)
  and, apart from it, an optional background (`:hover`, `:selection`, `:card`).
  A grapheme that is two cells wide under the terminal's width policy keeps its
  second cell as `:cont`. Everything is clipped at the canvas edge. Cells can be
  locked (the mark's), and a locked cell takes no later text.

  `rows/2` turns the canvas into one `Block.RichText` of exactly `width` cells
  per row, every string through `Density.safe/3`. Roles are resolved by `style/2`:
  `Settings.Text.style/2`, except that the ghost role keeps its own colour here
  (the orbits' arcs and the ring's track are decoration, and decoration must be
  fainter than faint text).
  """

  alias SwarmCodeCLI.UI.{Theme, Width}
  alias SwarmCodeCLI.UI.Projector.Density
  alias SwarmCodeCLI.UI.Projector.Settings.Text, as: SettingsText
  alias SwarmCodeCLI.UI.Scene.{Block, Span}
  alias SwarmCodeCLI.UI.Settings.Glyphs

  @blank {" ", :text_primary}

  defstruct [:width, :height, :policy, :ascii?, cells: %{}, bgs: %{}, locks: MapSet.new()]

  @type role :: atom() | {atom(), [atom()]}
  @type part :: {binary(), role()}
  @type t :: %__MODULE__{}

  @doc "An empty canvas of `width` x `height` cells for a state's capabilities."
  @spec new(map(), pos_integer(), pos_integer()) :: t()
  def new(state, width, height) do
    %__MODULE__{
      width: width,
      height: height,
      policy: state.capabilities.ambiguous_width,
      ascii?: Glyphs.tier(state.capabilities) == :ascii
    }
  end

  @doc "A text as it is drawn: one line, no controls, ASCII twins at the ASCII tier."
  @spec prepare(t(), binary()) :: binary()
  def prepare(%__MODULE__{ascii?: ascii?}, text) do
    text =
      text
      |> to_string()
      |> String.replace(["\r\n", "\n", "\r", "\t"], " ")
      |> String.replace(~r/[\x00-\x1F\x7F]/u, "")

    if ascii?, do: Glyphs.asciify(text), else: text
  end

  @doc "The width of `text` in cells as it would be drawn."
  @spec cells(t(), binary()) :: non_neg_integer()
  def cells(%__MODULE__{policy: policy} = canvas, text),
    do: Width.cells(prepare(canvas, text), policy)

  @doc "The width of a list of parts."
  @spec parts_cells(t(), [part()]) :: non_neg_integer()
  def parts_cells(canvas, parts),
    do: parts |> Enum.map(fn {text, _} -> cells(canvas, text) end) |> Enum.sum()

  @doc "`text` cut to `room` cells (at a grapheme), ending in `…` when it was cut."
  @spec clip(t(), binary(), integer()) :: binary()
  def clip(canvas, text, room) do
    text = prepare(canvas, text)

    cond do
      room <= 0 -> ""
      Width.cells(text, canvas.policy) <= room -> text
      true -> fit_ellipsis(canvas, text, room)
    end
  end

  defp fit_ellipsis(canvas, text, room) do
    ellipsis = if canvas.ascii?, do: "...", else: "…"
    ellipsis_cells = Width.cells(ellipsis, canvas.policy)

    if ellipsis_cells > room or (not canvas.ascii? and ellipsis_cells != String.length(ellipsis)) do
      take_cells(canvas, text, room)
    else
      take_cells(canvas, text, room - ellipsis_cells) <> ellipsis
    end
  end

  defp take_cells(canvas, text, room) do
    {taken, _} =
      text
      |> String.graphemes()
      |> Enum.reduce_while({"", 0}, fn grapheme, {acc, used} ->
        size = Width.cells(grapheme, canvas.policy)

        if used + size > room,
          do: {:halt, {acc, used}},
          else: {:cont, {acc <> grapheme, used + size}}
      end)

    taken
  end

  # ------------------------------------------------------------------ writing

  @doc """
  Writes `text` from `{row, col}` in `role`; returns `{canvas, next_col}`. Locked
  cells are skipped, the canvas edge clips. A background written before stays.
  """
  @spec put(t(), integer(), integer(), binary(), role()) :: {t(), integer()}
  def put(%__MODULE__{} = canvas, row, col, text, role) do
    text = prepare(canvas, text)

    {canvas, next} =
      text
      |> String.graphemes()
      |> Enum.reduce({canvas, col}, fn grapheme, {canvas, at} ->
        size = Width.cells(grapheme, canvas.policy)
        {put_grapheme(canvas, row, at, grapheme, size, role), at + size}
      end)

    {canvas, next}
  end

  @doc "`put/5` for a list of parts; returns `{canvas, next_col}`."
  @spec puts(t(), integer(), integer(), [part()]) :: {t(), integer()}
  def puts(canvas, row, col, parts) do
    Enum.reduce(parts, {canvas, col}, fn {text, role}, {canvas, at} ->
      put(canvas, row, at, text, role)
    end)
  end

  @doc "The parts, ending just before column `end_col` (their last cell is `end_col - 1`)."
  @spec rputs(t(), integer(), integer(), [part()]) :: {t(), integer()}
  def rputs(canvas, row, end_col, parts) do
    puts(canvas, row, end_col - parts_cells(canvas, parts), parts)
  end

  defp put_grapheme(canvas, _row, _col, _grapheme, size, _role) when size <= 0, do: canvas

  defp put_grapheme(canvas, row, col, grapheme, size, role) do
    cond do
      row < 0 or row >= canvas.height or col < 0 or col + size > canvas.width ->
        canvas

      Enum.any?(0..(size - 1), &MapSet.member?(canvas.locks, {row, col + &1})) ->
        canvas

      true ->
        canvas = free(canvas, row, col, size)
        cells = Map.put(canvas.cells, {row, col}, {grapheme, role})

        cells =
          Enum.reduce(1..(size - 1)//1, cells, fn i, acc ->
            Map.put(acc, {row, col + i}, :cont)
          end)

        %{canvas | cells: cells}
    end
  end

  # Writing over half of a wide grapheme blanks the other half.
  defp free(canvas, row, col, size) do
    Enum.reduce(col..(col + size - 1), canvas, fn c, canvas ->
      case Map.get(canvas.cells, {row, c}) do
        :cont -> blank_wide(canvas, row, c - 1)
        {_text, _role} -> blank_wide_tail(canvas, row, c)
        nil -> canvas
      end
    end)
  end

  defp blank_wide(canvas, row, head_col) do
    cells =
      canvas.cells
      |> Map.put({row, head_col}, @blank)
      |> Map.put({row, head_col + 1}, @blank)

    %{canvas | cells: cells}
  end

  defp blank_wide_tail(canvas, row, col) do
    if Map.get(canvas.cells, {row, col + 1}) == :cont do
      %{canvas | cells: Map.put(canvas.cells, {row, col + 1}, @blank)}
    else
      canvas
    end
  end

  @doc "A background over `[c0, c1)` of `row`."
  @spec paint(t(), integer(), integer(), integer(), atom()) :: t()
  def paint(%__MODULE__{} = canvas, row, c0, c1, background) do
    if row < 0 or row >= canvas.height do
      canvas
    else
      bgs =
        for col <- max(c0, 0)..(min(c1, canvas.width) - 1)//1, reduce: canvas.bgs do
          acc -> Map.put(acc, {row, col}, background)
        end

      %{canvas | bgs: bgs}
    end
  end

  @doc "Locks cells: nothing is written over them afterwards."
  @spec lock(t(), Enumerable.t()) :: t()
  def lock(canvas, cells), do: %{canvas | locks: MapSet.union(canvas.locks, MapSet.new(cells))}

  @doc "Writes a braille cell (or any single grapheme) that is allowed to be locked cell content."
  @spec put_locked(t(), integer(), integer(), binary(), role()) :: t()
  def put_locked(canvas, row, col, char, role) do
    cond do
      row < 0 or row >= canvas.height or col < 0 or col >= canvas.width ->
        canvas

      true ->
        canvas = %{canvas | cells: Map.put(canvas.cells, {row, col}, {char, role})}
        lock(canvas, [{row, col}])
    end
  end

  # ------------------------------------------------------------------ reading

  @doc "The grapheme at a cell (`\" \"` where nothing is written)."
  @spec char_at(t(), integer(), integer()) :: binary()
  def char_at(%__MODULE__{cells: cells}, row, col) do
    case Map.get(cells, {row, col}) do
      {text, _role} -> text
      _ -> " "
    end
  end

  @doc "Whether the cell is empty or holds braille: where an arc may be drawn."
  @spec free_for_arc?(t(), integer(), integer()) :: boolean()
  def free_for_arc?(canvas, row, col) do
    not MapSet.member?(canvas.locks, {row, col}) and
      (char_at(canvas, row, col) == " " or braille?(char_at(canvas, row, col)))
  end

  @doc "Whether a grapheme is a braille pattern."
  @spec braille?(binary()) :: boolean()
  def braille?(<<cp::utf8>>), do: cp in 0x2800..0x28FF
  def braille?(_char), do: false

  @doc "Blanks the braille in `[c0, c1)` of `row` (a label or a bead makes room for itself)."
  @spec clear_braille(t(), integer(), integer(), integer()) :: t()
  def clear_braille(%__MODULE__{} = canvas, row, c0, c1) do
    cells =
      Enum.reduce(max(c0, 0)..min(c1 - 1, canvas.width - 1)//1, canvas.cells, fn col, acc ->
        with false <- MapSet.member?(canvas.locks, {row, col}),
             {char, _role} <- Map.get(acc, {row, col}),
             true <- braille?(char) do
          Map.delete(acc, {row, col})
        else
          _ -> acc
        end
      end)

    %{canvas | cells: cells}
  end

  # ------------------------------------------------------------------- output

  @doc "The scene rows: one `Block.RichText` of exactly `width` cells per canvas row."
  @spec rows(t(), map()) :: [Block.RichText.t()]
  def rows(%__MODULE__{} = canvas, state) do
    for row <- 0..(canvas.height - 1) do
      runs = runs(canvas, row)

      spans =
        Enum.map(runs, fn {text, role, bg} ->
          %Span{
            text: Density.safe(text, state, max(Width.cells(text, canvas.policy), 1)),
            style: style(state, with_background(role, bg))
          }
        end)

      %Block.RichText{spans: spans}
    end
  end

  # [{text, role, bg}] for the row, equal neighbours merged.
  defp runs(canvas, row) do
    0..(canvas.width - 1)
    |> Enum.reduce([], fn col, acc ->
      case Map.get(canvas.cells, {row, col}, @blank) do
        :cont ->
          acc

        {text, role} ->
          bg = Map.get(canvas.bgs, {row, col})

          case acc do
            [{prev, ^role, ^bg} | rest] -> [{prev <> text, role, bg} | rest]
            _ -> [{text, role, bg} | acc]
          end
      end
    end)
    |> Enum.reverse()
  end

  defp with_background(role, nil), do: role
  defp with_background(role, bg), do: {role, :on, bg}

  @doc """
  The scene style of a role. `{role, mods}` adds modifiers, `{role, :on, bg}` a
  background; the ghost role is its own colour (see the moduledoc).
  """
  @spec style(map(), term()) :: map()
  def style(state, :text_ghost) do
    base = Theme.style(:text_ghost, state.capabilities)

    case state.capabilities do
      %{color_mode: :monochrome} ->
        %{base | prefix: nil, modifiers: Enum.uniq([:dim | base.modifiers])}

      _ ->
        %{base | prefix: nil}
    end
  end

  def style(state, {:text_ghost, modifiers}) when is_list(modifiers) do
    base = style(state, :text_ghost)
    %{base | modifiers: Enum.uniq(modifiers ++ base.modifiers)}
  end

  def style(state, role), do: SettingsText.style(state, role)
end
