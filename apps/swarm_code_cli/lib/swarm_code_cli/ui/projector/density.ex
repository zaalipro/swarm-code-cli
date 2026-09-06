defmodule SwarmCodeCLI.UI.Projector.Density do
  @moduledoc "Deterministic per-class content budgets. All widths are terminal cells."
  alias SwarmCodeCLI.UI.{SafeText, Width}
  alias SwarmCodeCLI.UI.SafeText.Limits

  def external(value, limits) do
    case SafeText.external(value, limits) do
      {:ok, safe} -> safe
      {:error, _} -> SafeText.chrome(:text_limit)
    end
  end

  def budget(class) do
    case class do
      c when c in [:xl, :wide] -> %{bindings: 4, banner: :fake_banner, metadata: :full}
      :medium -> %{bindings: 3, banner: :fake_banner_compact, metadata: :counts}
      :narrow -> %{bindings: 2, banner: :fake_banner_compact, metadata: :target}
      :small -> %{bindings: 1, banner: :fake_banner_compact, metadata: :target}
      :compressed_small -> %{bindings: 0, banner: :fake_banner_compact, metadata: :survival}
      :too_small -> %{bindings: 0, banner: nil, metadata: :none}
    end
  end

  def safe(value, state, cells, position \\ :end) do
    limits = %{Limits.content() | ambiguous_width: state.capabilities.ambiguous_width}
    source = if is_struct(value, SafeText), do: value, else: external(value, limits)

    source
    |> SafeText.value()
    |> String.replace(["\r\n", "\n", "\r"], " ")
    |> Width.elide(max(cells, 0), position, limits.ambiguous_width)
    |> external(limits)
  end

  def clip(value, state, cells) do
    limits = %{Limits.content() | ambiguous_width: state.capabilities.ambiguous_width}

    {prefix, _, _} =
      value
      |> external(limits)
      |> SafeText.value()
      |> Width.take_cells(cells, limits.ambiguous_width)

    external(prefix, limits)
  end

  def lines(value, state, width, height) do
    limits = %{Limits.content() | ambiguous_width: state.capabilities.ambiguous_width}

    value
    |> external(limits)
    |> SafeText.value()
    |> Width.wrap(max(1, width), limits.ambiguous_width)
    |> Enum.take(max(0, height))
    |> Enum.map(&external(&1, limits))
  end
end
