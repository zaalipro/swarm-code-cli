defmodule SwarmCodeCLI.UI.DataSource.Fake.Conversation do
  @moduledoc """
  cli020 C: the synthetic answers to the conversation commands
  (`Intent.conversation_action/1`) so the reducer and projector can be tested
  without a daemon. They agree with `PersistedBackend`'s outcomes in shape;
  the fake keeps no queue, shell or rewind state of its own.
  """
  alias SwarmCodeCLI.UI.Intent
  alias SwarmCodeCLI.UI.DataSource.DTO

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

  # cli020 C16: two synthetic turns to rewind to, and a rewind that hands
  # the prompt back (the demo keeps its transcript as it is).
  defp answer(script, {:rewind_turns, _}, _conversation) do
    clock = SwarmCodeCLI.UI.DataSource.Fake.Script.clock_ms()

    turns = [
      %DTO.RewindTurn{
        message_id: "7e000000-0000-4000-8000-000000000002",
        position: 3,
        turn: 2,
        prompt: "Add the retry button",
        at: clock - 60_000,
        run_id: "7e000000-0000-4000-8000-0000000000b2",
        files: 3
      },
      %DTO.RewindTurn{
        message_id: "7e000000-0000-4000-8000-000000000001",
        position: 1,
        turn: 1,
        prompt: "Explain the build",
        at: clock - 600_000,
        run_id: "7e000000-0000-4000-8000-0000000000b1",
        files: 0
      }
    ]

    {:ok, script, [], [], nil, %DTO.CommandResult{kind: :rewind_turns, turns: turns}}
  end

  defp answer(script, {:rewind_apply, _, _message, scope}, conversation) do
    text = if scope == :files, do: nil, else: "Add the retry button"
    restored = if scope == :conversation, do: 0, else: 3

    {:ok, script, [], [conversation], nil,
     %DTO.CommandResult{kind: :rewound, text: text, restored: restored}}
  end

  # cli020 C15: `!cmd` is accepted (the demo runs nothing) and so is a stop.
  defp answer(script, {:shell_run, _, _}, _conversation),
    do: {:ok, script, [], ["5e110000-0000-4000-8000-000000000001"], nil}

  defp answer(script, {:shell_stop, _}, conversation),
    do: {:ok, script, [], [conversation], nil}

  # cli020 C14: a clipboard slot (nothing is written: the demo has no inbox)
  # and the image staged from it.
  defp answer(script, {:attachment_slot, _}, _conversation) do
    token = String.duplicate("0", 31) <> "1"

    {:ok, script, [], [], nil,
     %DTO.CommandResult{kind: :slot, token: token, path: "/demo/cli-inbox/#{token}.png"}}
  end

  defp answer(script, {:attach_slot, _, _token}, _conversation) do
    attachment = %DTO.StagedAttachment{
      id: "a0000000-0000-4000-8000-000000000001",
      name: "clipboard-120000.png",
      mime: "image/png",
      bytes: 48_213
    }

    {:ok, script, [], [attachment.id], nil,
     %DTO.CommandResult{kind: :attachment, attachment: attachment}}
  end
end
