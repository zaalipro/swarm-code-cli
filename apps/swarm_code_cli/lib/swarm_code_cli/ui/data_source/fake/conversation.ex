defmodule SwarmCodeCLI.UI.DataSource.Fake.Conversation do
  @moduledoc """
  cli020 C: the synthetic answers to the conversation commands
  (`Intent.conversation_action/1`) so the reducer and projector can be tested
  without a daemon. They agree with `PersistedBackend`'s outcomes in shape;
  the fake keeps no queue, shell or rewind state of its own.
  """
  alias SwarmCodeCLI.UI.Intent

  @doc "`{:ok, script, deltas, identifiers, feedback}` or `{:error, code}`."
  def prepare(script, %{kind: kind, scope: scope}) do
    cond do
      Intent.conversation_action(kind) == nil ->
        {:error, :not_allowed}

      not match?(%{kind: :conversation}, scope) or scope.id != elem(kind, 1) ->
        {:error, :invalid_origin}

      true ->
        answer(script, kind, scope.id)
    end
  end

  # The queue: resuming and editing are accepted (the fake's queue is its
  # `:queued` runs; nothing waits behind a paused stop here).
  defp answer(script, {:queue_resume, _}, conversation),
    do: {:ok, script, [], [conversation], nil}

  defp answer(script, {:queue_edit, _, _, _}, conversation),
    do: {:ok, script, [], [conversation], nil}
end
