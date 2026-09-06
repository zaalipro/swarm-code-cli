defmodule SwarmCodeCLI.UI.FieldEditors do
  @moduledoc "Transient query/filter/Other editors, isolated from conversation drafts."
  alias SwarmCodeCLI.UI.{Editor, FieldKey, Intent}
  @derive {Inspect, only: []}
  defstruct entries: %{}, max_fields: 32, ambiguous_width: :narrow

  @type t :: %__MODULE__{
          entries: %{FieldKey.t() => Editor.t()},
          max_fields: pos_integer(),
          ambiguous_width: :narrow | :wide
        }

  def new(options \\ []) do
    fields = struct!(__MODULE__, options)

    unless Keyword.keyword?(options) and
             Keyword.keys(options) -- [:max_fields, :ambiguous_width] == [] and
             is_integer(fields.max_fields) and fields.max_fields in 1..128 and
             fields.ambiguous_width in [:narrow, :wide],
           do: raise(ArgumentError, "invalid field editor options")

    fields
  end

  def fetch(%__MODULE__{} = fields, key) do
    FieldKey.validate!(key)

    case Map.fetch(fields.entries, key) do
      {:ok, editor} -> editor
      :error -> Editor.new(max_bytes: 16_384, ambiguous_width: fields.ambiguous_width)
    end
  end

  def put(%__MODULE__{} = fields, key, %{__struct__: Editor} = editor) do
    FieldKey.validate!(key)

    unless is_integer(editor.max_bytes) and editor.max_bytes <= 16_384 and
             Editor.text_bytes(editor) <= 16_384,
           do: raise(ArgumentError, "field editor exceeds its text bound")

    if not Map.has_key?(fields.entries, key) and map_size(fields.entries) >= fields.max_fields,
      do: raise(ArgumentError, "field editor capacity reached")

    %{fields | entries: Map.put(fields.entries, key, editor)}
  end

  def close_owner(%__MODULE__{} = fields, owner) do
    unless Intent.valid_id?(owner), do: raise(ArgumentError, "invalid field owner")
    %{fields | entries: Map.reject(fields.entries, fn {key, _} -> elem(key, 1) == owner end)}
  end

  @doc "Unlike composer whitespace, every byte of a transient field is unsent work."
  def dirty?(%__MODULE__{} = fields),
    do: Enum.any?(fields.entries, fn {_key, editor} -> Editor.text(editor) != "" end)
end
