defmodule SwarmCodeCLI.UI.DataSource.Pass71QueueTest do
  @moduledoc """
  pass71 S5: the queue count (`queued`, prompts of the conversation waiting
  behind its live turn) crosses the wire on the workspace snapshot and the
  `workspace_metadata` delta, decodes as 0 from an older daemon, and exists in
  the fake data source.
  """
  use ExUnit.Case, async: true
  alias SwarmCode.Protocol.Scope
  alias SwarmCodeCLI.UI.DataSource.{Delta, DTO, Request}
  alias SwarmCodeCLI.UI.DataSource.Fake.{Script, Session}

  @conversation "22222222-2222-4222-8222-222222222222"

  defp metadata(extra) do
    Map.merge(
      %{
        "conversation_id" => @conversation,
        "mode" => "build",
        "chat_model" => nil,
        "swarm_model" => nil,
        "effort" => nil,
        "swarm_effort" => nil
      },
      extra
    )
  end

  test "workspace metadata carries the queue count; an older daemon's is 0" do
    assert {:ok, %DTO.WorkspaceMetadata{queued: 2}} =
             DTO.WorkspaceMetadata.decode(metadata(%{"queued" => 2}))

    assert {:ok, %DTO.WorkspaceMetadata{queued: 0}} = DTO.WorkspaceMetadata.decode(metadata(%{}))

    assert {:error, _} = DTO.WorkspaceMetadata.decode(metadata(%{"queued" => -1}))

    delta = %{
      "kind" => "workspace_metadata",
      "entity_id" => nil,
      "run_id" => nil,
      "conversation_id" => @conversation,
      "attempt_id" => nil,
      "channel" => nil,
      "text" => nil,
      "sequence" => 1,
      "revision" => 1,
      "body" => metadata(%{"queued" => 3})
    }

    assert {:ok, %Delta{body: %DTO.WorkspaceMetadata{queued: 3}}} = Delta.decode(delta)
  end

  defp script do
    {:ok, value} =
      Script.decode(
        File.read!(Path.expand("../../../fixtures/fake/three_run_script.json", __DIR__))
      )

    value
  end

  test "the fake counts a queued prompt and says so in a metadata delta" do
    initial = script()
    scope = %Scope{kind: :conversation, id: Script.id(:a), generation: 0}
    assert Keyword.fetch!(Session.workspace_fields(initial, scope), :queued) == 0

    request = %Request{
      request_id: "queue-1",
      kind: {:dispatch, :queue, "then say hello", :main, []},
      origin: {:draft, {Script.id(:a), :main}},
      scope: scope,
      generation: 0,
      deadline: Script.clock_ms() + 1000,
      expected_response: :outcome
    }

    assert {:ok, next, _outcome, deltas} = Script.command(initial, request)

    assert [%Delta{body: %DTO.WorkspaceMetadata{queued: 1}}] =
             for(%Delta{kind: :workspace_metadata} = d <- deltas, do: d)

    assert Keyword.fetch!(Session.workspace_fields(next, scope), :queued) == 1
  end
end
