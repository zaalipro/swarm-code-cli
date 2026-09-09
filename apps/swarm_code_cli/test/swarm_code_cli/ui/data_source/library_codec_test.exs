defmodule SwarmCodeCLI.UI.DataSource.LibraryCodecTest do
  use ExUnit.Case, async: true
  alias SwarmCode.Protocol.Scope
  alias SwarmCodeCLI.UI.DataSource.{DTO, Request}
  alias SwarmCodeCLI.UI.DataSource.Daemon.Codec
  @nonce "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  @wire_id "11111111-1111-4111-8111-111111111111"

  test "feature mutations encode attributes and decode a correlated outcome" do
    request = %Request{
      request_id: "change",
      kind: {:feature_command, :schedules, :toggle, "task", %{}},
      scope: %Scope{kind: :global, id: nil, generation: 3},
      generation: 3,
      origin: {:feature, :schedules},
      deadline: 5_000,
      expected_response: :outcome
    }

    assert {:ok, message} = Codec.request(request, @wire_id, @nonce, 0)
    assert message.body["op"] == "feature.command"
    assert message.body["action"] == "toggle"
    assert message.body["attributes"] == %{}

    body = %{
      "status" => "accepted",
      "request_id" => @wire_id,
      "identifiers" => ["task"],
      "interaction" => nil,
      "error" => nil,
      "corrective_action" => "none"
    }

    response = %{
      message
      | type: :response,
        body: %{"op" => "result", "response_kind" => "outcome", "value" => body}
    }

    assert {:ok, %{body: %DTO.Outcome{request_id: "change", status: :accepted}}} =
             Codec.response(response, request, @wire_id, @nonce)
  end

  test "library queries and rows cross the strict client codec with feature correlation" do
    request = %Request{
      request_id: "library-1",
      kind: {:feature_query, :workflows, nil, nil, 20, 65_536},
      scope: %Scope{kind: :global, id: nil, generation: 0},
      generation: 0,
      origin: {:feature, :workflows},
      deadline: 5_000,
      expected_response: :library_snapshot
    }

    assert {:ok, message} = Codec.request(request, @wire_id, @nonce, 0)
    assert message.body["op"] == "feature.query"

    row = %{
      "id" => "review",
      "title" => "Review",
      "subtitle" => "Project workflow",
      "status" => "ready",
      "detail" => "Review changes",
      "actions" => ["start", "inspect"]
    }

    value = %{
      "feature" => "workflows",
      "title" => "Workflows",
      "description" => "Choose a workflow",
      "items" => [row],
      "state" => "idle",
      "before_cursor" => nil,
      "after_cursor" => nil,
      "request_id" => @wire_id,
      "error" => nil,
      "presence" => "covered",
      "covered_ids" => ["review"],
      "through_sequence" => 0
    }

    response = %{
      message
      | type: :response,
        body: %{"op" => "result", "response_kind" => "library_snapshot", "value" => value}
    }

    assert {:ok,
            %{
              body: %DTO.LibrarySnapshot{
                feature: :workflows,
                request_id: "library-1",
                items: [item]
              }
            }} =
             Codec.response(response, request, @wire_id, @nonce)

    assert item.actions == [:start, :inspect]
    invalid = put_in(response.body["value"]["feature"], "research")
    assert {:error, _} = Codec.response(invalid, request, @wire_id, @nonce)
    invalid = put_in(response.body["value"]["items"], [Map.put(row, "api_key", "secret")])
    assert {:error, _} = Codec.response(invalid, request, @wire_id, @nonce)
  end
end
