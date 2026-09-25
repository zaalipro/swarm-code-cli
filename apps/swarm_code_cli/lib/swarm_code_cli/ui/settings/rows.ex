defmodule SwarmCodeCLI.UI.Settings.Rows do
  @moduledoc """
  Rows built from the core registry (spec §3.7.5). `registry/2` is the default
  page of a section: every registry entry of the section grouped by `group`
  in registry order, one `scalar/2` row each. Until the core registry is part
  of the build the section page is empty (the defaults still run).
  """

  alias SwarmCodeCLI.UI.Settings.{Ctx, Row}

  @compile {:no_warn_undefined, [SwarmCode.Settings.Registry]}

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

  @doc "The registry entries of `section` (empty when the registry is not in the build)."
  @spec entries(Ctx.t(), atom()) :: [struct()]
  def entries(_ctx, section) do
    SwarmCodeCLI.UI.Settings.Sections.optional(SwarmCode.Settings.Registry, :for_section, fn ->
      SwarmCode.Settings.Registry.for_section(section)
    end) || []
  end

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
