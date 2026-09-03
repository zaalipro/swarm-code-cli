defmodule SwarmCodeCLI.UI.SceneContractsTest do
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.TestSupport.ContractFixtures
  alias SwarmCodeCLI.UI.{Renderer, SafeText, Scene}
  alias SwarmCodeCLI.UI.Scene.{Span, Style}

  test "a minimal SafeText Scene validates and raw binary text does not" do
    scene = ContractFixtures.minimal_scene(SafeText.chrome(:fake_banner))
    assert :ok = Scene.validate(scene)

    assert {:error, %Renderer.Error{code: :invalid_scene}} =
             Scene.validate(ContractFixtures.with_raw_text(scene, "unsafe"))
  end

  test "renderer behavior exposes only the exact neutral callbacks" do
    callbacks = Renderer.behaviour_info(:callbacks) |> Enum.sort()
    assert callbacks == [draw: 2, init: 1, normalize_event: 2, shutdown: 1]
  end

  test "scene rejects out of bounds and unsafe values" do
    scene = ContractFixtures.minimal_scene(SafeText.chrome(:main))

    bad =
      put_in(scene.regions, [%{hd(scene.regions) | rect: %{x: -1, y: 0, width: 1, height: 1}}])

    assert {:error, %Renderer.Error{code: :invalid_scene}} = Scene.validate(bad)

    assert {:error, %Renderer.Error{code: :invalid_scene}} =
             Scene.validate(%{scene | cursor: %{x: 0, y: 0, shape: :bogus}})
  end

  test "scene rejects incoherent virtual list windows and forged fields" do
    scene = ContractFixtures.minimal_scene(SafeText.chrome(:main))

    block = %SwarmCodeCLI.UI.Scene.Block.VirtualList{
      total_count: 1,
      first_index: 1,
      items: [%SwarmCodeCLI.UI.Scene.Block.Text{text: SafeText.chrome(:main)}],
      overscan: 0
    }

    bad = put_in(scene.regions, [%{hd(scene.regions) | blocks: [block]} | tl(scene.regions)])
    assert {:error, %Renderer.Error{code: :invalid_scene}} = Scene.validate(bad)

    forged =
      struct(SwarmCodeCLI.UI.Scene.Block.Text, text: SafeText.chrome(:main))
      |> Map.put(:rogue, :renderer_specific)

    forged_scene =
      put_in(scene.regions, [%{hd(scene.regions) | blocks: [forged]} | tl(scene.regions)])

    assert {:error, %Renderer.Error{code: :invalid_scene}} = Scene.validate(forged_scene)

    overscan = %{block | total_count: 1, first_index: 0, overscan: 3}

    overscan_scene =
      put_in(scene.regions, [%{hd(scene.regions) | blocks: [overscan]} | tl(scene.regions)])

    assert {:error, %Renderer.Error{code: :invalid_scene}} = Scene.validate(overscan_scene)

    forged_style = struct(Style) |> Map.put(:rogue, :renderer_specific)
    span = %Span{text: SafeText.chrome(:main), style: forged_style}
    rich = %SwarmCodeCLI.UI.Scene.Block.RichText{spans: [span]}

    style_scene =
      put_in(scene.regions, [%{hd(scene.regions) | blocks: [rich]} | tl(scene.regions)])

    assert {:error, %Renderer.Error{code: :invalid_scene}} = Scene.validate(style_scene)
  end
end
