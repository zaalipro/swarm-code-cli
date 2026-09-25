defmodule SwarmCodeCLI.UI.Settings.Rows do
  @moduledoc """
  Rows built from the core registry (spec §3.7.5). `registry/2` is the default
  page of a section: every registry entry of the section grouped by `group`
  in registry order, one `scalar/2` row each.
  """

  alias SwarmCodeCLI.UI.Settings.{Ctx, Row}

  alias SwarmCode.Settings.Registry

  @doc "Every registry entry of `section` as rows, with a heading per group."
  @spec registry(Ctx.t(), atom()) :: [Row.t()]
  def registry(%Ctx{} = ctx, section) do
    ctx
    |> entries(section)
    |> Enum.chunk_by(&Map.get(&1, :group))
    |> Enum.flat_map(fn [first | _] = group ->
      heading = if is_binary(Map.get(first, :group)), do: [Row.heading(first.group)], else: []
      heading ++ Enum.map(group, &scalar(ctx, &1))
    end)
  end

  @doc "The registry entries of `section`, in page order."
  @spec entries(Ctx.t(), atom()) :: [struct()]
  def entries(_ctx, section), do: Registry.for_section(section)

  @doc "One registry entry as a row (label and key; the value comes with the data)."
  @spec scalar(Ctx.t(), struct()) :: Row.t()
  def scalar(_ctx, entry) do
    %Row{
      id: "key:" <> entry.key,
      kind: :setting,
      key: entry.key,
      label: Map.get(entry, :label, entry.key)
    }
  end
end
