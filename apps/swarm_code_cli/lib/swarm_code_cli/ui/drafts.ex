defmodule SwarmCodeCLI.UI.Drafts do
  @moduledoc "Bounded in-memory drafts with exact submission settlement and no silent eviction."
  alias SwarmCodeCLI.UI.{Draft, DraftKey, Editor, Intent}
  @derive {Inspect, only: []}
  defstruct entries: %{}, pending: %{}, max_drafts: 32, ambiguous_width: :narrow

  @type t :: %__MODULE__{
          entries: %{DraftKey.t() => Draft.t()},
          pending: map(),
          max_drafts: pos_integer(),
          ambiguous_width: :narrow | :wide
        }

  def new(options \\ []) do
    store = struct!(__MODULE__, options)

    unless Keyword.keyword?(options) and
             Keyword.keys(options) -- [:max_drafts, :ambiguous_width] == [] and
             is_integer(store.max_drafts) and store.max_drafts in 1..128 and
             store.ambiguous_width in [:narrow, :wide],
           do: raise(ArgumentError, "invalid draft store options")

    store
  end

  def fetch(%__MODULE__{} = store, key) do
    DraftKey.validate!(key)

    case Map.fetch(store.entries, key) do
      {:ok, draft} -> draft
      :error -> Draft.new(key, Editor.new(ambiguous_width: store.ambiguous_width))
    end
  end

  def put(%__MODULE__{} = store, %Draft{} = draft) do
    Draft.validate!(draft)

    if not Map.has_key?(store.entries, draft.key) and map_size(store.entries) >= store.max_drafts,
      do:
        raise(
          ArgumentError,
          "draft capacity reached; preserve unsent work before opening another draft"
        )

    pending =
      case Map.fetch(store.pending, draft.key) do
        {:ok, {_request, identity}} ->
          if identity == Draft.payload_identity(draft),
            do: store.pending,
            else: Map.delete(store.pending, draft.key)

        :error ->
          store.pending
      end

    %{store | entries: Map.put(store.entries, draft.key, draft), pending: pending}
  end

  def mark_submitted(%__MODULE__{} = store, key, request_id) do
    unless Intent.valid_id?(request_id), do: raise(ArgumentError, "invalid draft submission ID")
    draft = fetch(store, key)
    store = put(store, draft)
    %{store | pending: Map.put(store.pending, key, {request_id, Draft.payload_identity(draft)})}
  end

  def clear_origin(%__MODULE__{} = store, key, request_id) do
    DraftKey.validate!(key)

    case {Map.fetch(store.entries, key), Map.fetch(store.pending, key)} do
      {{:ok, draft}, {:ok, {^request_id, identity}}} ->
        if Draft.payload_identity(draft) == identity do
          %{
            store
            | entries: Map.put(store.entries, key, Draft.clear(draft)),
              pending: Map.delete(store.pending, key)
          }
        else
          store
        end

      _ ->
        store
    end
  end

  def dirty?(%__MODULE__{} = store),
    do: Enum.any?(store.entries, fn {_key, draft} -> Draft.dirty?(draft) end)
end
