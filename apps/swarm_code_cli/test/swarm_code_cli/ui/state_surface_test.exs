defmodule SwarmCodeCLI.UI.StateSurfaceTest do
  @moduledoc """
  C-ARCH-8 (first step): `State.surface/1` names the surface that owns the keys,
  in the precedence `Keymap.Context.of/1` has always read the nullable fields
  in: hint, layers, settings, Home, overlay, else the shell.
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{Home, State}
  alias SwarmCodeCLI.UI.Keymap.Context
  alias SwarmCodeCLI.UI.Settings.Layer

  @hint %{labels: [], typed: ""}
  @layer {:help, 1}
  @settings struct(Layer)
  @home struct(Home, focus: :list)
  @overlay %{run_id: "r", node_id: "n", focus: :band}

  defp base, do: %State{focus: "main"}

  # {hint, layers, settings, home, overlay} => the owner.
  @table [
    {nil, [], nil, nil, nil, :shell},
    {nil, [], nil, nil, :overlay, :overlay},
    {nil, [], nil, :home, nil, :home},
    {nil, [], nil, :home, :overlay, :home},
    {nil, [], :settings, nil, nil, :settings},
    {nil, [], :settings, :home, :overlay, :settings},
    {nil, [:layer], nil, nil, nil, :layer},
    {nil, [:layer], :settings, :home, :overlay, :layer},
    {:hint, [], nil, nil, nil, :hint},
    {:hint, [:layer], :settings, :home, :overlay, :hint}
  ]

  for {{hint, layers, settings, home, overlay, expected}, n} <- Enum.with_index(@table) do
    want = if expected == :layer, do: {:layer, @layer}, else: expected

    test "row #{n}: #{inspect({hint, layers, settings, home, overlay})} is #{expected}" do
      fields = [
        hint: if(unquote(hint) == :hint, do: @hint),
        layers: if(unquote(layers) == [:layer], do: [@layer], else: []),
        settings: if(unquote(settings) == :settings, do: @settings),
        home: if(unquote(home) == :home, do: @home),
        overlay: if(unquote(overlay) == :overlay, do: @overlay)
      ]

      state = struct(base(), fields)

      assert State.surface(state) == unquote(Macro.escape(want))
    end
  end

  test "a state with no surface field set is the shell, whatever else it holds" do
    assert State.surface(%State{}) == :shell
    assert State.surface(%{focus: "composer"}) == :shell

    assert State.surface(%{hint: nil, layers: [], settings: nil, home: nil, overlay: nil}) ==
             :shell
  end

  test "Keymap.Context.of/1 follows the same precedence" do
    assert Context.of(struct(base(), hint: @hint, layers: [@layer])) == :hint
    assert Context.of(struct(base(), layers: [@layer], overlay: @overlay)) == :dialog
    assert Context.of(struct(base(), home: @home, overlay: @overlay)) == :home_list
    assert Context.of(struct(base(), overlay: @overlay)) == :overlay
    assert Context.of(struct(base(), focus: "composer")) == :composer
    assert Context.of(struct(base(), focus: "inspector")) == :inspector
    assert Context.of(base()) == :main
  end
end
