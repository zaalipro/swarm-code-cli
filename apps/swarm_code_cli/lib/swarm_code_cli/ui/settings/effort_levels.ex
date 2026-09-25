defmodule SwarmCodeCLI.UI.Settings.EffortLevels do
  @moduledoc """
  The effort levels sub-page of a provider (spec §2.23 *effort_level*, T§24 sketch).
  """

  alias SwarmCodeCLI.UI.Settings.IntegrationRows, as: R

  @doc "Where a provider's levels come from, in words (`DeepSeek V4 · 3 levels`)."
  def source_words(f) do
    levels = R.field(f, "effort_levels")
    overrides = map_size(R.field(f, "model_effort_levels") || %{})
    presets = R.field(f, "presets") || []

    base =
      cond do
        levels in [nil, []] ->
          "built-in levels"

        preset = Enum.find(presets, &(R.field(&1, "levels") == levels)) ->
          "#{R.field(preset, "name")} · #{R.count(length(levels), "level")}"

        true ->
          "custom · #{R.count(length(levels), "level")}"
      end

    if overrides > 0, do: base <> " + #{R.count(overrides, "model override")}", else: base
  end

  @doc "The sub-page rows."
  def rows(_ctx, _id), do: []
end
