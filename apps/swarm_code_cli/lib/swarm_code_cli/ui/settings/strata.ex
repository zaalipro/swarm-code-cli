defmodule SwarmCodeCLI.UI.Settings.Strata do
  @moduledoc """
  The settings layers as hues (pass 75, E): one mapping from the layer that
  set a value to the Theme role its spine, tag, ladder cell and source row
  draw in, so the same layer is never two colours. It reuses the lane roles;
  no Theme or Scene role is added.
  """

  alias SwarmCodeCLI.UI.Scene.Style

  @type layer ::
          :session | :project | :project_file | :env | :flag | :cli | :global | :default | nil

  @doc "The role of a layer: its stratum hue, `:text_faint` for the default or an unknown one."
  @spec role(layer() | term()) :: Style.role()
  def role(:session), do: :agent_lane_1
  def role(layer) when layer in [:project, :project_file], do: :agent_lane_2
  def role(:env), do: :agent_lane_4
  def role(:flag), do: :agent_lane_5
  def role(:cli), do: :run_consensus_judge
  def role(:global), do: :text_muted
  def role(_layer), do: :text_faint

  @doc "The role of a row's spine cell: `:warning` for an attention row, else its layer's hue."
  @spec spine_role(map(), keyword()) :: Style.role()
  def spine_role(row, _opts \\ []) do
    if :attention in (Map.get(row, :marks) || []),
      do: :warning,
      else: role(Map.get(row, :layer))
  end

  @doc "Whether a layer set the value (false for the default, nil and unknown layers)."
  @spec set?(layer() | term()) :: boolean()
  def set?(layer), do: layer in [:session, :project, :project_file, :env, :flag, :cli, :global]
end
