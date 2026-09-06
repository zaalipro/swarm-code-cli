defmodule SwarmCodeCLI.UI.Paint.BudgetTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.UI.{Scene, Size, SafeText}
  alias SwarmCodeCLI.UI.Scene.{Region, Rect, Block}
  alias SwarmCodeCLI.UI.Paint.{Budget, Options}

  defmodule Untrusted do
    def __struct__ do
      send(self(), :untrusted_struct_called)
      %{}
    end
  end

  defp scene(blocks \\ []) do
    %Scene{
      size: %Size{columns: 80, rows: 24},
      regions: [
        %Region{
          id: "main",
          role: :main,
          rect: %Rect{x: 0, y: 0, width: 80, height: 24},
          label: SafeText.chrome(:empty),
          blocks: blocks
        }
      ]
    }
  end

  test "closed options retain all supported modes and reject extra/forged fields" do
    for mode <- [:truecolor, :ansi256, :ansi16, :monochrome], ascii <- [true, false] do
      assert :ok = Options.validate(%Options{color_mode: mode, ascii?: ascii})
    end

    assert {:error, :invalid_options} = Options.validate(%Options{color_mode: :unknown})
    assert {:error, :invalid_options} = Options.validate(Map.put(%Options{}, :extra, :unsafe))
    assert {:error, :invalid_options} = Options.validate(%Options{ascii?: :yes})
  end

  test "size is rejected before structural or text validation and before any grid exists" do
    assert :ok = Budget.validate_scene(%{scene() | size: %Size{columns: 500, rows: 200}})

    for size <- [
          %Size{columns: 501, rows: 1},
          %Size{columns: 1, rows: 201},
          %Size{columns: 1_000_000_000, rows: 1_000_000_000}
        ] do
      assert {:error, :capacity_exceeded} = Budget.validate_scene(%{scene() | size: size})
    end

    assert {:error, :invalid_scene} =
             Budget.validate_scene(%{scene() | size: %Size{columns: 0, rows: 1}})
  end

  test "oversized structural tails stop at the budget and never dispatch unknown structs" do
    tail = %{__struct__: Untrusted}

    blocks =
      Enum.reduce(1..5000, [tail], fn _, acc ->
        [%Block.Text{text: SafeText.chrome(:empty)} | acc]
      end)

    assert {:error, :capacity_exceeded} = Budget.validate_scene(scene(blocks))
    refute_receive :untrusted_struct_called
    assert {:error, :invalid_scene} = Budget.validate_scene(scene([tail]))
    refute_receive :untrusted_struct_called
    assert {:error, :invalid_scene} = Budget.validate_scene(scene([:bad | :improper]))
  end

  test "deep display lists and region floods reject while normal nesting survives" do
    leaf = %Block.Text{text: SafeText.chrome(:empty)}
    nested = Enum.reduce(1..33, leaf, fn _, child -> %Block.ActionDeck{actions: [child]} end)
    assert {:error, :capacity_exceeded} = Budget.validate_scene(scene([nested]))
    assert :ok = Budget.validate_scene(scene([%Block.ActionDeck{actions: [leaf]}]))
    boundary = Enum.reduce(1..31, leaf, fn _, child -> %Block.ActionDeck{actions: [child]} end)
    assert :ok = Budget.validate_scene(scene([boundary]))
    regions = for n <- 1..65, do: %{hd(scene().regions) | id: "r#{n}"}
    assert {:error, :capacity_exceeded} = Budget.validate_scene(%{scene() | regions: regions})
  end

  test "aggregate raw bytes are bounded before SafeText identity scanning" do
    text = %SafeText{token: {:external, String.duplicate("x", 262_144)}}
    blocks = List.duplicate(%Block.Text{text: text}, 17)
    assert {:error, :capacity_exceeded} = Budget.validate_scene(scene(blocks))
    assert :ok = Budget.validate_scene(scene([%Block.Text{text: SafeText.chrome(:fake_banner)}]))
    forged = %SafeText{token: {:external, "\e]0;not text\a"}}
    assert {:error, :invalid_scene} = Budget.validate_scene(scene([%Block.Text{text: forged}]))
  end

  test "byte accounting includes trusted chrome and accepts the exact aggregate boundary" do
    full = %SafeText{token: {:external, String.duplicate("x", 262_144)}}
    banner = SafeText.chrome(:fake_banner)
    # The region ID and expanded trusted banner are both part of input.
    banner_bytes = byte_size(SafeText.value(banner))
    tail = %SafeText{token: {:external, String.duplicate("x", 262_144 - banner_bytes - 4)}}

    blocks =
      List.duplicate(%Block.Text{text: full}, 15) ++
        [%Block.Text{text: tail}, %Block.Text{text: banner}]

    assert :ok = Budget.check(scene(blocks))

    assert {:error, :capacity_exceeded} =
             Budget.check(scene(blocks ++ [%Block.Text{text: SafeText.chrome(:main)}]))

    assert {:error, :invalid_scene} = Budget.check_display_list([%SafeText{token: :unknown}])
  end

  test "bignums, alien fields, oversized metadata and effect terms cannot enter Paint" do
    assert {:error, :invalid_scene} =
             Budget.validate_scene(%{scene() | revision: Integer.pow(2, 100_000)})

    assert {:error, :invalid_scene} = Budget.validate_scene(Map.put(scene(), :extra, :field))

    assert {:error, :invalid_scene} =
             Budget.validate_scene(%{
               scene()
               | regions: [%{hd(scene().regions) | id: String.duplicate("x", 257)}]
             })

    for term <- [self(), make_ref(), fn -> :ok end] do
      assert {:error, :invalid_scene} = Budget.validate_scene(scene([term]))
    end
  end
end
