defmodule SwarmCodeCLI.UI.Draft do
  @moduledoc "One process-local composer draft. Presentation changes never mark a draft dirty."
  alias SwarmCodeCLI.UI.{DraftKey, Editor, Intent, SafeText}
  alias SwarmCodeCLI.UI.Draft.AttachmentRef
  @derive {Inspect, only: []}
  @enforce_keys [:key, :editor]
  defstruct [
    :key,
    :editor,
    scroll_x: 0,
    scroll_y: 0,
    height: 1,
    target: :none,
    chips: [],
    attachments: [],
    staged_validation: :none
  ]

  @type t :: %__MODULE__{
          key: DraftKey.t(),
          editor: Editor.t(),
          scroll_x: non_neg_integer(),
          scroll_y: non_neg_integer(),
          height: 1..8,
          target: :none | Intent.dispatch_target(),
          chips: [{:command | :goal | :research, binary(), SafeText.t()}],
          attachments: [AttachmentRef.t()],
          staged_validation: :none | {:pending | :valid, binary()} | {:invalid, [binary()]}
        }

  def new(key, editor), do: validate!(%__MODULE__{key: key, editor: editor})

  @spec dirty?(t()) :: boolean()
  def dirty?(%__MODULE__{} = draft) do
    String.trim(Editor.text(draft.editor)) != "" or draft.target != :none or
      draft.chips != [] or draft.attachments != [] or draft.staged_validation != :none
  end

  @doc "Payload identity excludes cursor, selection, undo history, scroll and height."
  def payload_identity(%__MODULE__{} = draft) do
    {Editor.text(draft.editor), draft.target, draft.chips, draft.attachments,
     draft.staged_validation}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
  end

  def clear(%__MODULE__{} = draft) do
    %{new(draft.key, Editor.reset(draft.editor)) | height: draft.height}
  end

  def validate!(%__MODULE__{} = draft) do
    valid =
      map_size(draft) == 10 and match?({:ok, _}, DraftKey.validate(draft.key)) and
        valid_editor?(draft.editor) and nonneg?(draft.scroll_x) and nonneg?(draft.scroll_y) and
        is_integer(draft.height) and draft.height in 1..8 and
        (draft.target == :none or Intent.valid_dispatch_target?(draft.target)) and
        bounded?(draft.chips, 16, &chip?/1) and
        bounded?(draft.attachments, 16, &(AttachmentRef.validate(&1) == :ok)) and
        validation?(draft.staged_validation)

    if valid, do: draft, else: raise(ArgumentError, "invalid draft")
  end

  def validate!(_), do: raise(ArgumentError, "invalid draft")

  defp valid_editor?(%{__struct__: Editor} = editor) do
    Editor.text_bytes(editor) <= 262_144 and editor.max_bytes <= 262_144
  rescue
    _ -> false
  end

  defp valid_editor?(_), do: false
  defp nonneg?(n), do: is_integer(n) and n >= 0

  defp chip?({kind, id, %SafeText{} = label}) when kind in [:command, :goal, :research] do
    Intent.valid_id?(id) and byte_size(SafeText.value(label)) <= 4_096
  rescue
    _ -> false
  end

  defp chip?(_), do: false
  defp validation?(:none), do: true
  defp validation?({kind, id}) when kind in [:pending, :valid], do: Intent.valid_id?(id)
  defp validation?({:invalid, errors}), do: bounded?(errors, 16, &Intent.valid_id?/1)
  defp validation?(_), do: false
  defp bounded?([], _left, _validator), do: true

  defp bounded?([head | tail], left, validator) when left > 0,
    do: validator.(head) and bounded?(tail, left - 1, validator)

  defp bounded?(_, _, _), do: false
end
