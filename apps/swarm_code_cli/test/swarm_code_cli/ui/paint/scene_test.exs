defmodule SwarmCodeCLI.UI.Paint.SceneTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.UI.{Scene, Size, SafeText, Paint}
  alias SwarmCodeCLI.UI.Scene.{Block, Rect, Region, Dialog, Cursor}
  alias SwarmCodeCLI.UI.Paint.{Plan, Options}

  defp text(value), do: elem(SafeText.external(value, SafeText.Limits.content()), 1)

  defp region(id, role, x, y, width, height, blocks, focus \\ :inactive),
    do: %Region{
      id: id,
      role: role,
      rect: %Rect{x: x, y: y, width: width, height: height},
      label: text(id),
      blocks: blocks,
      focus: focus
    }

  defp row(plan, y) do
    for x <- 0..(plan.size.columns - 1), reduce: "" do
      acc ->
        case Plan.cell(plan, x, y) do
          {:glyph, text, _, _} -> acc <> text
          _ -> acc
        end
    end
  end

  test "one-row strips and composer retain cell coordinates while navigator reserves its label" do
    scene = %Scene{
      size: %Size{columns: 12, rows: 5},
      layout_class: :small,
      regions: [
        region("title", :title, 0, 0, 12, 1, [%Block.Text{text: text("FAKE DEMO")}]),
        region("nav", :navigator, 0, 1, 4, 3, [%Block.Text{text: text("run")}]),
        region(
          "composer",
          :composer,
          4,
          1,
          8,
          3,
          [%Block.Composer{text: text("界a"), placeholder: text("type")}],
          :active
        )
      ],
      cursor: %Cursor{x: 7, y: 1, shape: :bar, visible?: true}
    }

    assert {:ok, plan} = Paint.build(scene, %Options{})
    assert :ok = Plan.validate(plan)
    assert row(plan, 0) == "FAKE DEMO   "
    assert {:glyph, "界", 2, _} = Plan.cell(plan, 4, 1)
    assert {:continuation, 4} = Plan.cell(plan, 5, 1)
    assert {:glyph, "a", 1, _} = Plan.cell(plan, 6, 1)
    assert plan.cursor == scene.cursor
    assert plan.focus.region_id == "composer"
    assert plan.focus.rect == Enum.at(scene.regions, 2).rect
    assert row(plan, 2) =~ "run"
  end

  test "wide policy and ASCII chrome never transliterate external text" do
    scene = %Scene{
      size: %Size{columns: 8, rows: 2},
      ambiguous_width: :wide,
      regions: [region("main", :main, 0, 0, 8, 2, [%Block.Text{text: text("·é界")}])]
    }

    assert {:ok, plan} = Paint.build(scene, %Options{ascii?: true})
    assert {:glyph, "·", 2, _} = Plan.cell(plan, 0, 0)
    assert {:glyph, "é", 1, _} = Plan.cell(plan, 2, 0)
    assert {:glyph, "界", 2, _} = Plan.cell(plan, 3, 0)
    assert :ok = Plan.validate(plan)
  end

  test "overlay clears whole crossed glyphs and only overlay actions remain active" do
    scene = %Scene{
      size: %Size{columns: 12, rows: 7},
      regions: [
        region("main", :main, 0, 0, 12, 7, [
          %Block.Text{text: text("界 background"), action_id: "background"}
        ])
      ],
      overlay: %Dialog{
        id: "dialog",
        rect: %Rect{x: 1, y: 0, width: 10, height: 7},
        title: text("Question"),
        blocks: [%Block.Text{text: text("yes"), action_id: "yes"}],
        footer: [%Block.Text{text: text("Cancel"), action_id: "cancel"}],
        focused_control_id: "cancel"
      }
    }

    assert {:ok, plan} = Paint.build(scene, %Options{})
    assert :ok = Plan.validate(plan)
    assert {:glyph, " ", 1, _} = Plan.cell(plan, 0, 0)
    refute Map.has_key?(plan.actions, "background")
    assert Map.has_key?(plan.actions, "yes")
    assert Map.has_key?(plan.actions, "cancel")
    assert plan.focus.region_id == "dialog"
    assert plan.focus.control_id == "cancel"
    assert plan.cursor == nil
  end

  test "incompatible explicit colors are rejected before viewport clipping" do
    rgb = %Scene.Style{foreground: %Scene.Color{role: :default, value: {:rgb, 1, 2, 3}}}
    colored = %Block.RichText{spans: [%Scene.Span{text: text("rgb"), style: rgb}]}

    for {height, blocks} <- [
          {1, [colored]},
          {1, [%Block.Text{text: text("first")}, colored]},
          {0, [colored]}
        ] do
      scene = %Scene{
        size: %Size{columns: 5, rows: 2},
        regions: [region("main", :main, 0, 0, 5, height, blocks)]
      }

      assert :ok = Scene.validate(scene)
      assert {:error, :invalid_scene} = Paint.build(scene, %Options{color_mode: :monochrome})
    end
  end

  test "clipped actions are explicit and colors must match output capability" do
    scene = %Scene{
      size: %Size{columns: 5, rows: 1},
      regions: [
        region("main", :main, 0, 0, 5, 1, [
          %Block.Text{text: text("first"), action_id: "first"},
          %Block.Text{text: text("lost"), action_id: "lost"}
        ])
      ]
    }

    assert {:ok, plan} = Paint.build(scene, %Options{})
    assert Map.keys(plan.actions) == ["first"]
    assert plan.diagnostics == [{:clipped_action, "lost"}]
    assert {:error, :invalid_options} = Paint.build(scene, %{color_mode: :bogus})

    assert {:error, :capacity_exceeded} =
             Paint.build(%{scene | size: %Size{columns: 9999, rows: 9999}}, %Options{})

    assert Paint.build(scene, %Options{}) == Paint.build(scene, %Options{})
  end
end
