defmodule SwarmCode.Protocol.FeatureRequestTest do
  use ExUnit.Case, async: true
  alias SwarmCode.Protocol.{ServiceRequest, Scope}
  @scope %Scope{kind: :global, id: nil, generation: 3}

  test "feature library queries round trip within the closed bounded service protocol" do
    for feature <- ~w(workflows research schedules settings usage changes checkpoints mcp memory) do
      body = %{
        "op" => "feature.query",
        "feature" => feature,
        "id" => nil,
        "cursor" => nil,
        "page_size" => 20,
        "byte_limit" => 65_536,
        "timeout_ms" => 5_000
      }

      assert {:ok, request} = ServiceRequest.decode(body, @scope)
      assert request.operation == :feature_query
      assert {:ok, ^body} = ServiceRequest.encode(request, @scope)

      assert {:error, _} =
               ServiceRequest.decode(Map.put(body, "feature", "user-supplied-atom"), @scope)

      assert {:error, _} =
               ServiceRequest.decode(Map.put(body, "id", String.duplicate("x", 257)), @scope)

      assert {:error, _} = ServiceRequest.decode(Map.put(body, "page_size", 201), @scope)
      assert {:error, _} = ServiceRequest.decode(Map.put(body, "extra", true), @scope)
    end
  end

  test "feature mutations accept only known action pairs and bounded JSON attributes" do
    body = %{
      "op" => "feature.command",
      "feature" => "schedules",
      "action" => "toggle",
      "id" => "scheduled-task",
      "attributes" => %{},
      "timeout_ms" => 5_000
    }

    assert {:ok, request} = ServiceRequest.decode(body, @scope)
    assert request.operation == :feature_command
    assert {:ok, ^body} = ServiceRequest.encode(request, @scope)
    assert {:error, _} = ServiceRequest.decode(%{body | "action" => "execute_arbitrary"}, @scope)
    assert {:error, _} = ServiceRequest.decode(%{body | "feature" => "usage"}, @scope)
    assert {:error, _} = ServiceRequest.decode(%{body | "id" => nil}, @scope)
    assert {:error, _} = ServiceRequest.decode(%{body | "attributes" => %{bad: "key"}}, @scope)
    assert {:error, _} = ServiceRequest.decode(%{body | "attributes" => %{"x" => self()}}, @scope)
    assert {:error, _} = ServiceRequest.decode(Map.put(body, "extra", true), @scope)

    create = %{
      body
      | "feature" => "research",
        "action" => "start",
        "id" => nil,
        "attributes" => %{"question" => "Compare storage designs", "level" => "standard"}
    }

    assert {:ok, _} = ServiceRequest.decode(create, @scope)

    assert {:error, _} =
             ServiceRequest.decode(
               %{create | "attributes" => %{"question" => String.duplicate("x", 32_001)}},
               @scope
             )
  end

  test "question answers use a closed bounded operation" do
    scope = %Scope{kind: :conversation, id: "44444444-4444-4444-8444-444444444444", generation: 3}

    body = %{
      "op" => "question.answer",
      "run_id" => "11111111-1111-4111-8111-111111111111",
      "node_id" => "22222222-2222-4222-8222-222222222222",
      "interaction_id" => "33333333-3333-4333-8333-333333333333",
      "expected_revision" => 4,
      "answers" => ["option-a"],
      "custom_text" => "",
      "timeout_ms" => 5_000
    }

    assert {:ok, request} = ServiceRequest.decode(body, scope)
    assert request.operation == :question_answer
    assert {:ok, ^body} = ServiceRequest.encode(request, scope)

    assert {:error, _} =
             ServiceRequest.decode(
               %{body | "answers" => Enum.map(1..65, &Integer.to_string/1)},
               scope
             )

    assert {:error, _} =
             ServiceRequest.decode(%{body | "answers" => [String.duplicate("x", 257)]}, scope)

    assert {:error, _} = ServiceRequest.decode(Map.put(body, "extra", true), scope)
  end
end
