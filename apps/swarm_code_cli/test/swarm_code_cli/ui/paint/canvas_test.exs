defmodule SwarmCodeCLI.UI.Paint.CanvasTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SwarmCodeCLI.UI.{Size, Width}
  alias SwarmCodeCLI.UI.Paint.{Canvas, Plan}
  alias SwarmCodeCLI.UI.Scene.Rect

  test "bounded canvas starts with the supplied blank style" do
    assert {:ok, canvas} = Canvas.new(%Size{columns: 3, rows: 2}, 7)
    assert Canvas.finish(canvas) == List.to_tuple(List.duplicate({:glyph, " ", 1, 7}, 6))
    assert Canvas.actions(canvas) == %{}
    assert {:error, :invalid_size} = Canvas.new(%Size{columns: 0, rows: 1}, 0)
    assert {:error, :capacity_exceeded} = Canvas.new(%Size{columns: 501, rows: 1}, 0)
    assert {:error, :capacity_exceeded} = Canvas.new(%Size{columns: 1, rows: 201}, 0)
    assert {:error, :invalid_cell} = Canvas.new(%Size{columns: 1, rows: 1}, 4096)
    assert {:ok, largest} = Canvas.new(%Size{columns: 500, rows: 200}, 0)
    assert tuple_size(Canvas.finish(largest)) == 100_000
  end

  test "overpainting a continuation clears the entire old glyph and its owner" do
    {:ok, canvas} = Canvas.new(%Size{columns: 5, rows: 1}, 0)
    {:ok, canvas} = Canvas.put(canvas, 1, 0, "界", 2, 1, "old")
    assert Canvas.actions(canvas) == %{"old" => [%Rect{x: 1, y: 0, width: 2, height: 1}]}
    {:ok, replaced} = Canvas.put(canvas, 2, 0, "x", 1, 2, "new")

    assert Canvas.finish(replaced) ==
             {{:glyph, " ", 1, 0}, {:glyph, " ", 1, 0}, {:glyph, "x", 1, 2}, {:glyph, " ", 1, 0},
              {:glyph, " ", 1, 0}}

    assert Canvas.actions(replaced) == %{"new" => [%Rect{x: 2, y: 0, width: 1, height: 1}]}
    assert elem(Canvas.finish(canvas), 1) == {:glyph, "界", 2, 1}
  end

  test "overlay fill clears old spans crossing both rectangle edges" do
    {:ok, canvas} = Canvas.new(%Size{columns: 6, rows: 1})
    {:ok, canvas} = Canvas.put(canvas, 0, 0, "界", 2, 1, "a")
    {:ok, canvas} = Canvas.put(canvas, 3, 0, "界", 2, 1, "b")
    {:ok, canvas} = Canvas.fill(canvas, %Rect{x: 1, y: 0, width: 3, height: 1}, 2)

    assert Canvas.finish(canvas) ==
             {{:glyph, " ", 1, 0}, {:glyph, " ", 1, 2}, {:glyph, " ", 1, 2}, {:glyph, " ", 1, 2},
              {:glyph, " ", 1, 0}, {:glyph, " ", 1, 0}}

    assert Canvas.actions(canvas) == %{}
  end

  test "right edge omits a whole glyph without disturbing existing content" do
    {:ok, canvas} = Canvas.new(%Size{columns: 3, rows: 1})
    {:ok, canvas} = Canvas.put(canvas, 1, 0, "界", 2, 0, "keep")
    assert {:ok, ^canvas} = Canvas.put(canvas, 2, 0, "界", 2, 0)
    assert {:ok, ^canvas} = Canvas.fill(canvas, %Rect{x: 3, y: 1, width: 0, height: 0}, 0)
  end

  test "contextual glyphs may span more than two cells" do
    glyph = "क्ष्म"
    width = Width.cells(glyph, :narrow)
    assert width > 2
    {:ok, canvas} = Canvas.new(%Size{columns: 5, rows: 1})
    {:ok, canvas} = Canvas.put(canvas, 0, 0, glyph, width, 0)
    assert elem(Canvas.finish(canvas), 0) == {:glyph, glyph, width, 0}
    for x <- 1..(width - 1), do: assert(elem(Canvas.finish(canvas), x) == {:continuation, 0})
    {:ok, canvas} = Canvas.put(canvas, 2, 0, "é", 1, 0)
    assert elem(Canvas.finish(canvas), 0) == {:glyph, " ", 1, 0}
  end

  test "the widest permitted unit clears all 500 cells when its last continuation is overwritten" do
    {:ok, canvas} = Canvas.new(%Size{columns: 500, rows: 1})
    {:ok, canvas} = Canvas.put(canvas, 0, 0, String.duplicate("x", 500), 500, 0, "wide")
    assert elem(Canvas.finish(canvas), 499) == {:continuation, 0}
    {:ok, canvas} = Canvas.put(canvas, 499, 0, "z", 1, 0)
    assert Canvas.actions(canvas) == %{}
    assert elem(Canvas.finish(canvas), 0) == {:glyph, " ", 1, 0}
    assert elem(Canvas.finish(canvas), 498) == {:glyph, " ", 1, 0}
    assert elem(Canvas.finish(canvas), 499) == {:glyph, "z", 1, 0}
  end

  test "glyph bytes are bounded before retained array construction" do
    {:ok, canvas} = Canvas.new(%Size{columns: 1, rows: 1})

    assert {:error, :invalid_cell} =
             Canvas.put(canvas, 0, 0, String.duplicate("x", 262_145), 1, 0)
  end

  test "glyphs reject hidden controls and unattached marks while opaque IDs remain separate" do
    {:ok, canvas} = Canvas.new(%Size{columns: 2, rows: 1})

    for glyph <- ["a\u202E", "́a", "a\u200B"] do
      assert {:error, :invalid_cell} = Canvas.put(canvas, 0, 0, glyph, 1, 0)
    end

    assert {:ok, _} = Canvas.put(canvas, 0, 0, "x", 1, 0, "opaque\u202Eid")
  end

  test "fill clears crossing overhangs to the canvas blank style while leaving other background untouched" do
    {:ok, canvas} = Canvas.new(%Size{columns: 8, rows: 1}, 7)
    {:ok, canvas} = Canvas.fill(canvas, %Rect{x: 0, y: 0, width: 8, height: 1}, 3)
    {:ok, canvas} = Canvas.put(canvas, 1, 0, "क्ष्म", 3, 4, "left")
    {:ok, canvas} = Canvas.put(canvas, 5, 0, "क्ष्म", 3, 4, "right")
    {:ok, canvas} = Canvas.fill(canvas, %Rect{x: 2, y: 0, width: 4, height: 1}, 9)

    assert Canvas.finish(canvas) ==
             {{:glyph, " ", 1, 3}, {:glyph, " ", 1, 7}, {:glyph, " ", 1, 9}, {:glyph, " ", 1, 9},
              {:glyph, " ", 1, 9}, {:glyph, " ", 1, 9}, {:glyph, " ", 1, 7}, {:glyph, " ", 1, 7}}

    assert Canvas.actions(canvas) == %{}
  end

  test "filling an unchanged empty viewport avoids reconstruction work" do
    {:ok, canvas} = Canvas.new(%Size{columns: 120, rows: 40})
    rect = %Rect{x: 0, y: 0, width: 120, height: 40}
    Canvas.fill(canvas, rect, 0)
    Canvas.fill(canvas, rect, 1)
    {unchanged_result, unchanged_work} = fill_work(canvas, rect, 0)
    {changed_result, changed_work} = fill_work(canvas, rect, 1)
    assert {:ok, unchanged} = unchanged_result
    assert Canvas.finish(unchanged) == Canvas.finish(canvas)
    assert {:ok, changed} = changed_result
    assert elem(Canvas.finish(changed), 4799) == {:glyph, " ", 1, 1}
    assert unchanged_work * 2 < changed_work
  end

  defp fill_work(canvas, rect, style) do
    {:reductions, before} = Process.info(self(), :reductions)
    result = Canvas.fill(canvas, rect, style)
    {:reductions, after_count} = Process.info(self(), :reductions)
    {result, after_count - before}
  end

  test "invalid cells, owners and rectangles return typed errors" do
    {:ok, canvas} = Canvas.new(%Size{columns: 4, rows: 2})

    for glyph <- ["", "\n", "\t", "\e[0m", <<255>>, <<0x9B::utf8>>],
        do: assert({:error, :invalid_cell} == Canvas.put(canvas, 0, 0, glyph, 1, 0))

    for width <- [0, -1, 501, 1.0],
        do: assert({:error, :invalid_cell} == Canvas.put(canvas, 0, 0, "x", width, 0))

    for owner <- ["", <<255>>, :command, String.duplicate("a", 257)],
        do: assert({:error, :invalid_cell} == Canvas.put(canvas, 0, 0, "x", 1, 0, owner))

    assert {:error, :invalid_rect} = Canvas.put(canvas, -1, 0, "x", 1, 0)

    assert {:error, :invalid_rect} =
             Canvas.fill(canvas, %Rect{x: 3, y: 0, width: 2, height: 1}, 0)
  end

  test "actions coalesce visible adjacent cells separately for each row" do
    {:ok, canvas} = Canvas.new(%Size{columns: 4, rows: 2})

    canvas =
      Enum.reduce([{0, 0}, {1, 0}, {3, 0}, {0, 1}], canvas, fn {x, y}, acc ->
        {:ok, next} = Canvas.put(acc, x, y, "x", 1, 0, "opaque/id")
        next
      end)

    assert Canvas.actions(canvas) == %{
             "opaque/id" => [
               %Rect{x: 0, y: 0, width: 2, height: 1},
               %Rect{x: 3, y: 0, width: 1, height: 1},
               %Rect{x: 0, y: 1, width: 1, height: 1}
             ]
           }
  end

  property "arbitrary overwrites and fills preserve complete same-row spans" do
    operation =
      tuple({integer(0..11), integer(0..3), member_of(["x", "界", "é", "क्ष्म", "لا"]), boolean()})

    check all(operations <- list_of(operation, max_length: 80)) do
      size = %Size{columns: 12, rows: 4}
      {:ok, canvas} = Canvas.new(size)

      Enum.reduce(operations, canvas, fn {x, y, glyph, fill?}, acc ->
        {:ok, next} =
          if fill?,
            do: Canvas.fill(acc, %Rect{x: x, y: y, width: min(3, 12 - x), height: 1}, 0),
            else: Canvas.put(acc, x, y, glyph, Width.cells(glyph, :narrow), 0, "action")

        plan =
          struct(Plan,
            size: size,
            cells: Canvas.finish(next),
            palette: {%{foreground: nil, background: nil, modifiers: []}},
            actions: Canvas.actions(next)
          )

        assert Plan.validate(plan) == :ok
        next
      end)
    end
  end
end
