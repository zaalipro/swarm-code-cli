defmodule SwarmCode.Daemon.Service.R1019BackendStateTest do
  @moduledoc """
  Pass 77 C-ARCH-1: the persisted backend's state is a struct whose keys are all
  set by `init/1`, and an init that refuses to start says why in the log.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import SwarmCode.Test.C020Backend
  alias SwarmCode.Daemon.Service.PersistedBackend
  alias SwarmCode.Domain.Conversations

  setup_all do
    setup_world("backend-state")
  end

  setup c do
    {:ok, conv} = Conversations.create(c.project.id)
    %{conversation: conv}
  end

  test "the state is a struct with every key set", c do
    backend = start_backend(c, c.conversation)
    state = :sys.get_state(backend)

    assert %PersistedBackend{} = state
    keys = state |> Map.from_struct() |> Map.keys()
    assert :slash_extras in keys
    assert state.watches == %{} and state.queue_paused == MapSet.new()
    assert is_pid(state.vitals) and is_map(state.git) and state.home_monitors == %{}
  end

  test "an init that refuses to start logs the failed check, not the options", c do
    opts = [
      mode: :persisted,
      repo: SwarmCode.Domain.Repo,
      project_root: c.root,
      project_id: c.project.id,
      conversation_id: c.conversation.id,
      source_epoch: Ecto.UUID.generate(),
      approval_mode: "not a mode",
      prompt: "a secret prompt text"
    ]

    log =
      capture_log(fn ->
        assert {:error, :invalid_backend_configuration} = PersistedBackend.start_link(opts)
      end)

    assert log =~ "persisted backend: init refused: false"
    refute log =~ "a secret prompt text"
  end
end
