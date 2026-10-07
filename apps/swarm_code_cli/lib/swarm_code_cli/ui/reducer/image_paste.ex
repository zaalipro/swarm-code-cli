defmodule SwarmCodeCLI.UI.Reducer.ImagePaste do
  @moduledoc """
  cli020 D9 (competitors-6, decision 4i): Ctrl-V attaches the clipboard's
  image. The reducer emits `{:paste_image, conversation}`; the session
  runtime says why it cannot (not macOS, over SSH) or asks for a slot
  (`{:paste_image_slot, conversation}` → `attachment.slot`, C14). The slot's
  answer (`%{token, path}`) becomes `{:paste_image_write, conversation,
  token, path}`: the runtime writes the clipboard's PNG (or TIFF converted
  by `sips`) to the path in an owned job and answers `{:paste_image_done,
  conversation, token, result}`, after which `attachment.attach_slot`
  stages it (the chip is E15's). A slot that is never attached expires on
  the daemon (60 s).
  """

  alias SwarmCodeCLI.UI.Reducer.Remote

  @doc "Ctrl-V in the composer."
  def open(state) do
    case Remote.conversation(state) do
      nil -> {state, []}
      conversation -> {state, [{:paste_image, conversation}]}
    end
  end

  @doc "The runtime may read the clipboard: ask for a slot."
  def slot(state, conversation) do
    if conversation == Remote.conversation(state),
      do: Remote.send(state, {:attachment_slot, conversation}, :attachment),
      else: {state, []}
  end

  @doc "The slot's answer: the runtime writes the image to its path."
  def slot_answer(state, %{kind: {:attachment_slot, conversation}}, payload) do
    token = Remote.field(payload, :token)
    path = Remote.field(payload, :path)

    if is_binary(token) and token =~ ~r/\A[0-9a-f]{32}\z/ and is_binary(path) and
         Path.type(path) == :absolute do
      {state, [{:paste_image_write, conversation, token, path}]}
    else
      {%{state | notice: {:command_feedback, "The image could not be attached."}}, []}
    end
  end

  @doc "The runtime's job ended."
  def done(state, conversation, token, :ok) do
    if conversation == Remote.conversation(state),
      do: Remote.send(state, {:attach_slot, conversation, token}, :attachment),
      else: {state, []}
  end

  def done(state, _conversation, _token, {:error, reason}),
    do: {%{state | notice: {:command_feedback, words(reason)}}, []}

  @doc "What a failed paste says."
  def words(:no_image), do: "The clipboard has no image."
  def words(:not_macos), do: "Image paste needs macOS; use /attach PATH."
  def words(:ssh), do: "Over SSH the clipboard is the other Mac's; use /attach PATH."
  def words(_reason), do: "The clipboard's image could not be read."
end
