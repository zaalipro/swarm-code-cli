defmodule SwarmCodeCLI.UI.Paint do
  @moduledoc "Builds bounded renderer-neutral cells from an admitted Scene."
  alias SwarmCodeCLI.UI.Paint.{Budget, Options, Plan}

  @spec build(term(), Options.t()) :: {:ok, Plan.t()} | {:error, atom()}
  def build(scene, options \\ %Options{}) do
    with :ok <- Options.validate(options),
         :ok <- Budget.validate_scene(scene),
         true <- compatible_styles?(scene, options.color_mode),
         {:ok, plan} <- SwarmCodeCLI.UI.Paint.Scene.paint(scene, options),
         :ok <- Plan.validate(plan) do
      {:ok, plan}
    else
      {:error, :invalid_options} = error -> error
      {:error, :capacity_exceeded} = error -> error
      _ -> {:error, :invalid_scene}
    end
  rescue
    _ -> {:error, :invalid_scene}
  end

  # Admission is independent of which blocks happen to be visible this frame.
  # Budget has already bounded this traversal and excluded unknown structs.
  defp compatible_styles?(%SwarmCodeCLI.UI.Scene.Style{} = style, mode) do
    inherited = %{foreground: nil, background: nil, modifiers: []}
    match?({:ok, _}, SwarmCodeCLI.UI.Paint.Style.resolve(style, inherited, mode))
  end

  defp compatible_styles?(%{} = map, mode),
    do: Enum.all?(Map.values(map), &compatible_styles?(&1, mode))

  defp compatible_styles?(list, mode) when is_list(list),
    do: Enum.all?(list, &compatible_styles?(&1, mode))

  defp compatible_styles?(tuple, mode) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.all?(&compatible_styles?(&1, mode))

  defp compatible_styles?(_, _), do: true
end
