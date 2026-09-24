defmodule SwarmCodeCLI.UI.DraftKey do
  @moduledoc "A closed, conversation-scoped composer draft identity."

  alias SwarmCodeCLI.UI.Intent

  # `{:agent, node_id}` (pass 72) is the agent overlay's composer: what it
  # steers goes to that one agent.
  @type t ::
          {binary(), :main | {:thread, binary()} | {:edit, binary()} | {:agent, binary()}}

  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_draft_key}
  def validate({conversation_id, :main} = key) do
    if Intent.valid_id?(conversation_id), do: {:ok, key}, else: {:error, :invalid_draft_key}
  end

  def validate({conversation_id, {kind, subject_id}} = key)
      when kind in [:thread, :edit, :agent] do
    if Intent.valid_id?(conversation_id) and Intent.valid_id?(subject_id),
      do: {:ok, key},
      else: {:error, :invalid_draft_key}
  end

  def validate(_key), do: {:error, :invalid_draft_key}

  @spec validate!(term()) :: t()
  def validate!(key) do
    case validate(key) do
      {:ok, valid} -> valid
      {:error, :invalid_draft_key} -> raise ArgumentError, "invalid draft key"
    end
  end
end
