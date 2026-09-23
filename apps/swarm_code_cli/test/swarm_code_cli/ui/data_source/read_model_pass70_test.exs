defmodule SwarmCodeCLI.UI.DataSource.ReadModelPass70Test do
  @moduledoc """
  Pass 70 C1 deltas reach the read model: background commands with the run,
  rate limits and toasts from the shell, and an unknown kind is not a crash.
  """
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.UI.ReadModel
  alias SwarmCodeCLI.UI.DataSource.{Delta, DTO}

  @run "33333333-3333-4333-8333-333333333333"
  @conversation "22222222-2222-4222-8222-222222222222"

  defp command(id, revision, state \\ :running),
    do: %DTO.BackgroundCommand{
      id: id,
      run_id: @run,
      command: "sleep 600",
      state: state,
      revision: revision
    }

  test "background commands arrive with the workspace snapshot, update and leave by delta" do
    snapshot = %DTO.WorkspaceSnapshot{
      conversation_id: @conversation,
      transcript: %DTO.TranscriptWindow{},
      runs_page: %DTO.PageInfo{},
      interactions_page: %DTO.PageInfo{},
      background: [command("bg-1", 1)]
    }

    model = ReadModel.snapshot(%ReadModel{}, :workspace, snapshot)
    assert model.background["bg-1"].state == :running

    upsert = %Delta{
      kind: :background_upsert,
      entity_id: "bg-1",
      run_id: @run,
      body: command("bg-1", 2, :exited)
    }

    assert {:ok, model, [], []} = ReadModel.delta(model, :workspace, upsert)
    assert model.background["bg-1"].state == :exited

    # An older revision never wins.
    stale = %{upsert | body: command("bg-1", 1)}
    assert {:ok, ^model, [], []} = ReadModel.delta(model, :workspace, stale)

    remove = %Delta{kind: :background_remove, entity_id: "bg-1", run_id: @run}
    assert {:ok, model, [], ["bg-1"]} = ReadModel.delta(model, :workspace, remove)
    assert model.background == %{}
  end

  test "rate limits come from the shell snapshot and are replaced per provider" do
    limit = %DTO.RateLimit{provider_id: "p1", provider: "llmotions", used_percent: 62.0}

    shell = %DTO.ShellSnapshot{
      counts: %DTO.Counts{},
      connection: %DTO.Connection{source_epoch: "e"},
      rate_limits: [limit]
    }

    model = ReadModel.snapshot(%ReadModel{}, :shell, shell)
    assert model.rate_limits["p1"].used_percent == 62.0

    newer = %{limit | used_percent: 90.0, revision: 2, retry_at: 1_000}
    delta = %Delta{kind: :rate_limit, entity_id: "p1", body: newer}
    assert {:ok, model, [], []} = ReadModel.delta(model, :shell, delta)
    assert model.rate_limits["p1"].retry_at == 1_000
  end

  test "toasts keep the newest sixteen, one per id, newest first" do
    model =
      Enum.reduce(1..20, %ReadModel{}, fn n, model ->
        toast = %DTO.Toast{id: "t#{n}", title: "toast #{n}", at: n}
        {:ok, model, [], []} = ReadModel.delta(model, :shell, %Delta{kind: :toast, body: toast})
        model
      end)

    assert length(model.toasts) == 16
    assert hd(model.toasts).id == "t20"

    again = %DTO.Toast{id: "t10", title: "again", at: 21}
    {:ok, model, [], []} = ReadModel.delta(model, :shell, %Delta{kind: :toast, body: again})
    assert hd(model.toasts).title == "again"
    assert Enum.count(model.toasts, &(&1.id == "t10")) == 1
  end

  test "metadata outside the workspace and unknown kinds change nothing" do
    metadata = %Delta{
      kind: :workspace_metadata,
      conversation_id: @conversation,
      body: %DTO.WorkspaceMetadata{conversation_id: @conversation}
    }

    assert {:ok, %ReadModel{}, [], []} = ReadModel.delta(%ReadModel{}, :shell, metadata)

    future = %Delta{kind: :something_newer}
    assert {:ok, %ReadModel{}, [], []} = ReadModel.delta(%ReadModel{}, :workspace, future)
  end
end
