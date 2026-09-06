defmodule SwarmCodeCLI.UI.Draft.AttachmentRef do
  @moduledoc "Attachment metadata held by a draft; content bytes belong to the source."
  alias SwarmCodeCLI.UI.{Intent, SafeText}
  @derive {Inspect, only: []}
  @enforce_keys [:id, :name, :media_type, :byte_size, :status, :reference]
  defstruct [:id, :name, :media_type, :byte_size, :width, :height, :status, :reference]

  @type t :: %__MODULE__{
          id: binary(),
          name: SafeText.t(),
          media_type: binary(),
          byte_size: non_neg_integer(),
          width: pos_integer() | nil,
          height: pos_integer() | nil,
          status: :pending | :ready | :invalid,
          reference: binary()
        }

  def new!(options) do
    attachment = struct!(__MODULE__, options)

    if validate(attachment) == :ok,
      do: attachment,
      else: raise(ArgumentError, "invalid attachment reference")
  end

  def validate(%__MODULE__{} = ref) do
    valid =
      map_size(ref) == 9 and Intent.valid_id?(ref.id) and Intent.valid_id?(ref.reference) and
        ref.media_type in ["image/png", "image/jpeg", "image/webp", "image/gif", "image/avif"] and
        is_integer(ref.byte_size) and ref.byte_size >= 0 and
        ref.status in [:pending, :ready, :invalid] and
        dimensions?(ref.width, ref.height) and safe_name?(ref.name)

    if valid, do: :ok, else: {:error, :invalid_attachment_ref}
  end

  def validate(_), do: {:error, :invalid_attachment_ref}

  defp dimensions?(nil, nil), do: true
  defp dimensions?(w, h), do: is_integer(w) and w > 0 and is_integer(h) and h > 0

  defp safe_name?(%SafeText{} = name) do
    byte_size(SafeText.value(name)) <= 4_096
  rescue
    _ -> false
  end

  defp safe_name?(_), do: false
end
