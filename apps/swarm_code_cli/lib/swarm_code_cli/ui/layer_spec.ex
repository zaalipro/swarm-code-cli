defmodule SwarmCodeCLI.UI.LayerSpec do
  @moduledoc "Closed specifications for the fixed layers introduced by the neutral contract."

  alias SwarmCodeCLI.UI.Intent

  @type inspector_tab :: :overview | :agents | :timeline | :changes
  @type t ::
          :help
          | {:run_inspector, binary(), inspector_tab()}
          # {:question, id}: id is the asking op's node_id (one layer per ask, pass 75)
          | {:question | :approval, binary()}
          | {:unsent_changes, :detach | :plain}
          | {:confirm_intent, Intent.t()}
          | {:detail, binary(), binary()}
          | {:library, atom()}
          | {:research_form, binary()}
          | {:feature_form, atom(), binary()}
          | {:command_report, binary()}
          | {:switcher | :action_menu | :jump | :region_filter, binary()}
          | {:runs_dashboard, binary()}
          | {:run_palette, binary()}
          | {:model_picker, :chat | :swarm, binary()}
          # cli020 §8.3: D opens and closes these, E draws them.
          | {:effort_picker, :chat | :swarm}
          | {:rewind, %{turns: list(), selected: non_neg_integer()}}
          | {:rewind_confirm, map()}
          | {:history_search, %{query: binary(), rows: list(), selected: non_neg_integer()}}
          | {:queue_list}

  @spec help() :: t()
  def help, do: :help

  @spec run_inspector(binary(), inspector_tab()) :: t()
  def run_inspector(run_id, tab) do
    layer = {:run_inspector, run_id, tab}

    case validate(layer) do
      {:ok, valid} -> valid
      {:error, :invalid_layer_spec} -> raise ArgumentError, "invalid run inspector layer"
    end
  end

  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_layer_spec}
  def validate({:detail, run_id, ref_id} = layer),
    do:
      if(Intent.valid_id?(run_id) and Intent.valid_id?(ref_id),
        do: {:ok, layer},
        else: {:error, :invalid_layer_spec}
      )

  def validate(:help), do: {:ok, :help}

  def validate({:run_inspector, run_id, tab} = layer)
      when tab in [:overview, :agents, :timeline, :changes] do
    if Intent.valid_id?(run_id), do: {:ok, layer}, else: {:error, :invalid_layer_spec}
  end

  def validate({kind, id} = layer)
      when kind in [
             :question,
             :approval,
             :switcher,
             :action_menu,
             :jump,
             :region_filter,
             :command_report,
             :runs_dashboard,
             :run_palette
           ],
      do: if(Intent.valid_id?(id), do: {:ok, layer}, else: {:error, :invalid_layer_spec})

  # The picker remembers which model it switches: the chat model or the one
  # the workers use. The id owns its query field like any other picker.
  def validate({:model_picker, target, id} = layer) when target in [:chat, :swarm],
    do: if(Intent.valid_id?(id), do: {:ok, layer}, else: {:error, :invalid_layer_spec})

  def validate({:confirm_intent, {:run_control, :stop, _} = intent} = layer),
    do: if(Intent.valid?(intent), do: {:ok, layer}, else: {:error, :invalid_layer_spec})

  def validate({:confirm_intent, {:stop_agent, _, _, _} = intent} = layer),
    do: if(Intent.valid?(intent), do: {:ok, layer}, else: {:error, :invalid_layer_spec})

  def validate({:unsent_changes, path} = layer) when path in [:detach, :plain], do: {:ok, layer}

  def validate({:library, feature} = layer)
      when feature in [
             :workflows,
             :research,
             :schedules,
             :usage,
             :changes,
             :checkpoints,
             :mcp,
             :memory
           ],
      do: {:ok, layer}

  def validate({:research_form, owner} = layer),
    do: if(Intent.valid_id?(owner), do: {:ok, layer}, else: {:error, :invalid_layer_spec})

  def validate({:feature_form, feature, id} = layer)
      when feature in [:workflows, :schedules, :mcp, :memory] do
    if Intent.valid_id?(id), do: {:ok, layer}, else: {:error, :invalid_layer_spec}
  end

  # cli020 §8.3 (D18, D10, D19, D20): the effort picker, the rewind list and
  # its confirmation, the history search and the queue list.
  def validate({:effort_picker, scope} = layer) when scope in [:chat, :swarm], do: {:ok, layer}

  def validate({:rewind, %{turns: turns, selected: selected}} = layer)
      when is_list(turns) and is_integer(selected) and selected >= 0 and length(turns) <= 1_000,
      do: {:ok, layer}

  def validate({:rewind_confirm, turn} = layer) when is_map(turn), do: {:ok, layer}

  def validate({:history_search, %{query: query, rows: rows, selected: selected}} = layer)
      when is_binary(query) and byte_size(query) <= 1_024 and is_list(rows) and
             length(rows) <= 50 and is_integer(selected) and selected >= 0,
      do: {:ok, layer}

  def validate({:queue_list} = layer), do: {:ok, layer}

  def validate(_layer), do: {:error, :invalid_layer_spec}
end
