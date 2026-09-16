defmodule SwarmCodeCLI.UI.ModelPicker do
  @moduledoc """
  The `/model` and `/swarm_model` picker: every model the workspace snapshot
  lists, one row per provider/model pair, filtered by the layer's query.

  The layer is `{:model_picker, :chat | :swarm, id}`. It opens from the bare
  command in the composer or from the palette, and a pick sends the very
  command the user could have typed, `/model <provider_id>|<model>`, as an
  ordinary dispatch intent. Nothing here decides which provider serves a
  model; the daemon resolves the pair it is sent.
  """

  alias SwarmCodeCLI.UI.{Editor, FieldEditors, State}
  alias SwarmCodeCLI.UI.DataSource.DTO.ModelOption

  @type target :: :chat | :swarm
  @type layer :: {:model_picker, target(), binary()}

  @type row :: %{
          id: binary(),
          model: binary(),
          provider: binary(),
          current?: boolean(),
          intent: SwarmCodeCLI.UI.Intent.t()
        }

  @spec targets() :: [target()]
  def targets, do: [:chat, :swarm]

  @doc "The layer that opens next for `target`, with the id the reducer will advance past."
  @spec open(State.t(), target()) :: layer()
  def open(state, target) when target in [:chat, :swarm],
    do: {:model_picker, target, elem(State.next_id(state, :layer), 0)}

  @doc "The query field that owns the layer's filter text."
  @spec field_key(layer()) :: {:layer_query, binary(), :model_picker}
  def field_key({:model_picker, _target, id}), do: {:layer_query, id, :model_picker}

  @doc "The slash command a pick sends: the exact `<provider_id>|<model>` pair the row shows."
  @spec command(target(), binary(), binary()) :: binary()
  def command(:chat, provider_id, model), do: "/model " <> provider_id <> "|" <> model
  def command(:swarm, provider_id, model), do: "/swarm_model " <> provider_id <> "|" <> model

  @doc "The picker's target when `text` is the bare command that opens it, else nil."
  @spec opener(term()) :: target() | nil
  def opener(text) when is_binary(text) do
    case String.trim(text) do
      "/model" -> :chat
      "/swarm_model" -> :swarm
      _ -> nil
    end
  end

  def opener(_text), do: nil

  @spec title(target()) :: binary()
  def title(:chat), do: "Model"
  def title(:swarm), do: "Sub-agent model"

  @doc "The palette label for the entry that opens the picker."
  @spec label(target()) :: binary()
  def label(:chat), do: "Switch model…"
  def label(:swarm), do: "Switch sub-agent model…"

  @doc "The model the conversation uses for `target` now, as the workspace snapshot names it."
  @spec current(State.t(), target()) :: binary() | nil
  def current(state, target) do
    case workspace(state) do
      nil -> nil
      workspace -> Map.get(workspace, if(target == :chat, do: :chat_model, else: :swarm_model))
    end
  end

  @doc "Every model the snapshot lists, in the daemon's provider-then-model order."
  @spec options(State.t()) :: [ModelOption.t()]
  def options(state) do
    case workspace(state) do
      nil ->
        []

      workspace ->
        workspace
        |> Map.get(:models, [])
        |> Enum.filter(fn
          %ModelOption{provider_id: id, model: model} ->
            is_binary(id) and id != "" and is_binary(model) and model != ""

          _ ->
            false
        end)
        |> Enum.uniq_by(&row_id/1)
    end
  end

  @doc "The filter text typed into the layer's query field."
  @spec query(State.t(), layer()) :: binary()
  def query(state, layer),
    do: state.field_editors |> FieldEditors.fetch(field_key(layer)) |> Editor.text()

  @doc """
  The rows the query leaves, in snapshot order. A row matches when the query
  is a case-insensitive substring of its model or of its provider; an empty
  query keeps every row.
  """
  @spec rows(State.t(), layer()) :: [row()]
  def rows(state, {:model_picker, target, _id} = layer) do
    query = state |> query(layer) |> String.trim() |> String.downcase()
    current = current(state, target)

    for option <- options(state), matches?(option, query) do
      %{
        id: row_id(option),
        model: option.model,
        provider: option.provider,
        current?: option.model == current,
        intent: {:dispatch, :send, command(target, option.provider_id, option.model), :main, []}
      }
    end
  end

  @doc "The focus ring: the query, every visible row, then Cancel."
  @spec focus_graph(State.t(), layer()) :: [binary()]
  def focus_graph(state, layer),
    do: ["query"] ++ Enum.map(rows(state, layer), & &1.id) ++ ["cancel"]

  @doc "The row to land on when the visible rows change under the focus."
  @spec repair_selection(binary(), non_neg_integer(), [row()]) :: binary()
  def repair_selection(id, previous_index, rows) do
    cond do
      Enum.any?(rows, &(&1.id == id)) -> id
      rows == [] -> "query"
      true -> Enum.at(rows, min(max(previous_index, 0), length(rows) - 1)).id
    end
  end

  defp matches?(_option, ""), do: true

  defp matches?(option, query) do
    String.contains?(String.downcase(option.model), query) or
      String.contains?(String.downcase(option.provider || ""), query)
  end

  # The row id doubles as the argument the command carries, so a row is the
  # same row whichever query found it.
  defp row_id(%ModelOption{provider_id: id, model: model}), do: id <> "|" <> model

  defp workspace(state), do: Map.get(state.read_model.snapshots, :workspace)
end
