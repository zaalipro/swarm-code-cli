defmodule SwarmCode.Protocol.ServiceRequestTest do
  use ExUnit.Case, async: true

  alias SwarmCode.Protocol.{Envelope, Error, Scope, ServiceRequest}

  @project "11111111-1111-4111-8111-111111111111"
  @conversation "22222222-2222-4222-8222-222222222222"
  @run "55555555-5555-4555-8555-555555555555"
  @interaction "66666666-6666-4666-8666-666666666666"
  @max_counter 9_007_199_254_740_991

  test "literal v1 envelope yields a closed workspace request without changing the envelope" do
    json =
      ~s({"v":1,"type":"request","request_id":"#{@project}","nonce":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","scope":{"kind":"conversation","id":"#{@conversation}","generation":3},"sequence":null,"occurred_at":null,"body":{"op":"query","slot":"workspace","cursor":null,"direction":"after","page_size":50,"byte_limit":262144,"timeout_ms":5000}})

    assert {:ok, envelope} = Envelope.decode(json)
    assert envelope.version == 1
    assert {:ok, request} = ServiceRequest.decode(envelope.body, envelope.scope)
    assert request.operation == :query
    assert request.timeout_ms == 5000

    assert request.params == %{
             "slot" => "workspace",
             "cursor" => nil,
             "direction" => "after",
             "page_size" => 50,
             "byte_limit" => 262_144
           }

    assert {:ok, body} = ServiceRequest.encode(request, envelope.scope)
    assert body == envelope.body
  end

  test "all implemented operations round-trip literal JSON without atomizing params" do
    for {operation, json, scope} <- examples() do
      body = Jason.decode!(json)
      assert {:ok, request} = ServiceRequest.decode(body, scope)
      assert request.operation == operation
      assert request.timeout_ms == 5000
      assert Enum.all?(Map.keys(request.params), &is_binary/1)
      assert {:ok, ^body} = ServiceRequest.encode(request, scope)
    end
  end

  test "required nullable fields and every body key are closed" do
    for {_operation, json, scope} <- examples() do
      body = Jason.decode!(json)
      invalid(Map.put(body, "unexpected", true), scope)
      invalid(Map.put(body, :op, body["op"]), scope)

      for key <- Map.keys(body), do: invalid(Map.delete(body, key), scope)

      for timeout <- [nil, 0, -1, 600_001, 1.0, "5000", true],
          do: invalid(Map.put(body, "timeout_ms", timeout), scope)

      for timeout <- [1, 600_000],
          do:
            assert({:ok, _} = ServiceRequest.decode(Map.put(body, "timeout_ms", timeout), scope))
    end
  end

  test "query and watch slots use typed scope and watch excludes unimplemented slots" do
    for slot <- ["workspace", "transcript", "pending"] do
      assert {:ok, _} = ServiceRequest.decode(query(slot), scope(:conversation))
      for kind <- [:global, :project, :run], do: invalid(query(slot), scope(kind))
    end

    assert {:ok, _} = ServiceRequest.decode(query("inspector"), scope(:run))
    for kind <- [:global, :project, :conversation], do: invalid(query("inspector"), scope(kind))

    for slot <- ["shell", "activity"],
        kind <- [:global, :project, :conversation, :run],
        do: assert({:ok, _} = ServiceRequest.decode(query(slot), scope(kind)))

    for slot <- ["transcript", "pending", "unknown", :shell] do
      invalid(
        %{
          "op" => "watch",
          "slot" => slot,
          "watch_ref" => "watch-1",
          "page_size" => 50,
          "byte_limit" => 262_144,
          "timeout_ms" => 5000
        },
        scope(:conversation)
      )
    end

    invalid(query("other"), scope(:conversation))
    invalid(Map.put(query(), "direction", "sideways"), scope(:conversation))
  end

  test "page sizes, byte budgets and JSON-safe counters enforce both endpoints" do
    for {key, good, bad} <- [
          {"page_size", [1, 200], [0, 201, 1.0]},
          {"byte_limit", [1, 1_048_576], [0, 1_048_577, 1.0]}
        ] do
      for value <- good,
          do:
            assert(
              {:ok, _} = ServiceRequest.decode(Map.put(query(), key, value), scope(:conversation))
            )

      for value <- bad, do: invalid(Map.put(query(), key, value), scope(:conversation))
    end

    for {operation, key} <- [
          {:detail, "offset"},
          {:ack, "sequence"},
          {:approval_resolve, "expected_revision"}
        ] do
      {body, target_scope} = example(operation)

      for value <- [0, @max_counter],
          do: assert({:ok, _} = ServiceRequest.decode(Map.put(body, key, value), target_scope))

      for value <- [-1, @max_counter + 1, 0.0, nil, true],
          do: invalid(Map.put(body, key, value), target_scope)
    end

    {detail, target_scope} = example(:detail)

    for value <- [4, 65_536],
        do:
          assert({:ok, _} = ServiceRequest.decode(Map.put(detail, "bytes", value), target_scope))

    for value <- [0, 3, 65_537, 4.0], do: invalid(Map.put(detail, "bytes", value), target_scope)
  end

  test "opaque references are nonempty bounded UTF-8 and cannot contain controls" do
    for {operation, key} <- [
          {:query, "cursor"},
          {:detail, "detail_ref"},
          {:watch, "watch_ref"},
          {:unwatch, "watch_ref"},
          {:ack, "watch_ref"},
          {:resync, "watch_ref"}
        ] do
      {body, target_scope} = example(operation)

      for value <- ["x", String.duplicate("é", 128)],
          do: assert({:ok, _} = ServiceRequest.decode(Map.put(body, key, value), target_scope))

      for value <- ["", String.duplicate("é", 129), <<255>>, "a\n", "a\u0085", 1, [], %{}],
          do: invalid(Map.put(body, key, value), target_scope)

      if key != "cursor", do: invalid(Map.put(body, key, nil), target_scope)
    end
  end

  test "mutations enforce UUIDs and run-scope identity while leaving persisted membership to service" do
    {open, _} = example(:conversation_open)

    assert {:ok, _} =
             ServiceRequest.decode(
               Map.put(open, "conversation_id", @conversation),
               scope(:project)
             )

    for kind <- [:global, :conversation, :run], do: invalid(open, scope(kind))
    {dispatch, _} = example(:dispatch_send)
    for kind <- [:global, :project, :run], do: invalid(dispatch, scope(kind))

    for operation <- [:run_control, :run_steer, :approval_resolve] do
      {body, _} = example(operation)
      assert {:ok, _} = ServiceRequest.decode(body, scope(:conversation))
      assert {:ok, _} = ServiceRequest.decode(body, scope(:run))
      invalid(body, %{scope(:run) | id: @conversation})
      for kind <- [:global, :project], do: invalid(body, scope(kind))
    end

    for {operation, key} <- [
          {:conversation_open, "conversation_id"},
          {:cancel, "target_request_id"},
          {:run_control, "run_id"},
          {:run_steer, "run_id"},
          {:approval_resolve, "run_id"},
          {:approval_resolve, "interaction_id"}
        ] do
      {body, target_scope} = example(operation)

      for value <- ["opaque", "ABCDEFAB-1111-4111-8111-111111111111", "", 1, <<255>>],
          do: invalid(Map.put(body, key, value), target_scope)

      if operation != :conversation_open, do: invalid(Map.put(body, key, nil), target_scope)
    end
  end

  test "send and steer use their real UTF-8 byte ceilings and preserve text" do
    for {operation, limit} <- [{:dispatch_send, 262_144}, {:run_steer, 65_000}] do
      {body, target_scope} = example(operation)

      for text <- ["  hello\n", String.duplicate("é", div(limit, 2))] do
        assert {:ok, request} = ServiceRequest.decode(Map.put(body, "text", text), target_scope)
        assert request.params["text"] == text
      end

      for text <- ["", " \n\t", String.duplicate("é", div(limit, 2)) <> "x", <<255>>, nil, 1],
          do: invalid(Map.put(body, "text", text), target_scope)
    end
  end

  test "unimplemented mutation variants are refused instead of being downgraded" do
    {dispatch, target_scope} = example(:dispatch_send)

    for action <- ["queue", "revise", "send_now", :send],
        do: invalid(Map.put(dispatch, "action", action), target_scope)

    for target <- [
          %{"kind" => "reply", "id" => @run},
          %{"kind" => "thread", "id" => @run},
          %{"kind" => "revise", "id" => @run},
          %{"kind" => "main", "id" => @run},
          %{"kind" => "main"},
          %{"kind" => "main", "id" => nil, "extra" => 1},
          nil
        ],
        do: invalid(Map.put(dispatch, "target", target), target_scope)

    for operation <- [:dispatch_send, :run_steer] do
      {body, target_scope} = example(operation)

      for refs <- [["attachment-1"], nil, %{}, [1 | 2]],
          do: invalid(Map.put(body, "attachment_refs", refs), target_scope)
    end

    for operation <- [:run_steer, :approval_resolve] do
      {body, target_scope} = example(operation)
      invalid(Map.put(body, "node_id", @run), target_scope)
    end

    {control, target_scope} = example(:run_control)

    for action <- ["pause", "continue", "stop"],
        do:
          assert(
            {:ok, _} = ServiceRequest.decode(Map.put(control, "action", action), target_scope)
          )

    for action <- ["resume", "retry", "queue", :stop],
        do: invalid(Map.put(control, "action", action), target_scope)

    {approval, target_scope} = example(:approval_resolve)
    assert {:ok, _} = ServiceRequest.decode(Map.put(approval, "decision", "deny"), target_scope)

    for decision <- ["always_allow", "allow", :approve, nil],
        do: invalid(Map.put(approval, "decision", decision), target_scope)

    for op <- [
          "question.answer",
          "run.retry",
          "dispatch.send",
          "hello",
          "not_an_operation",
          :query
        ],
        do: invalid(Map.put(query(), "op", op), scope(:conversation))
  end

  test "untyped, malformed and forged structs fail with a fixed error without throwing" do
    for body <- [nil, [], 1, true, "query", self(), %Scope{kind: :global, id: nil, generation: 0}],
        do: invalid(body, scope(:global))

    for target_scope <- [
          nil,
          %{},
          %{"kind" => "conversation", "id" => @conversation, "generation" => 0},
          %{scope(:conversation) | generation: -1},
          %{scope(:conversation) | generation: @max_counter + 1},
          %{scope(:conversation) | id: "opaque"},
          %{scope(:global) | id: @project},
          %{scope(:conversation) | kind: :research},
          Map.put(scope(:conversation), :extra, true),
          Map.delete(scope(:conversation), :generation)
        ],
        do: invalid(query(), target_scope)

    assert {:ok, _} =
             ServiceRequest.decode(query(), %{scope(:conversation) | generation: @max_counter})

    assert {:ok, request} = ServiceRequest.decode(query(), scope(:conversation))

    for forged <- [
          nil,
          %{},
          Map.put(request, :extra, true),
          Map.delete(request, :params),
          %{request | operation: "query"},
          %{request | operation: :hello},
          %{request | timeout_ms: 0},
          %{request | params: nil},
          %{request | params: Map.put(request.params, "op", "query")},
          %{request | params: Map.put(request.params, "timeout_ms", 5000)},
          %{request | params: Map.put(request.params, "page_size", 201)}
        ] do
      assert {:error, %Error{code: :invalid_envelope, message: "invalid protocol envelope"}} =
               ServiceRequest.encode(forged, scope(:conversation))
    end

    assert {:error, %Error{code: :invalid_envelope}} = ServiceRequest.encode(request, scope(:run))
  end

  defp invalid(body, target_scope),
    do:
      assert(
        {:error, %Error{code: :invalid_envelope, message: "invalid protocol envelope"}} =
          ServiceRequest.decode(body, target_scope)
      )

  defp scope(:global), do: %Scope{kind: :global, id: nil, generation: 3}
  defp scope(:project), do: %Scope{kind: :project, id: @project, generation: 3}
  defp scope(:conversation), do: %Scope{kind: :conversation, id: @conversation, generation: 3}
  defp scope(:run), do: %Scope{kind: :run, id: @run, generation: 3}

  defp query(slot \\ "workspace"),
    do: %{
      "op" => "query",
      "slot" => slot,
      "cursor" => nil,
      "direction" => "after",
      "page_size" => 50,
      "byte_limit" => 262_144,
      "timeout_ms" => 5000
    }

  defp example(operation) do
    {^operation, json, target_scope} = Enum.find(examples(), fn {op, _, _} -> op == operation end)
    {Jason.decode!(json), target_scope}
  end

  defp examples do
    [
      {:query,
       ~s({"op":"query","slot":"workspace","cursor":null,"direction":"after","page_size":50,"byte_limit":262144,"timeout_ms":5000}),
       scope(:conversation)},
      {:detail,
       ~s({"op":"detail","detail_ref":"detail-1","offset":0,"bytes":65536,"timeout_ms":5000}),
       scope(:conversation)},
      {:watch,
       ~s({"op":"watch","watch_ref":"watch-1","slot":"workspace","page_size":50,"byte_limit":262144,"timeout_ms":5000}),
       scope(:conversation)},
      {:unwatch, ~s({"op":"unwatch","watch_ref":"watch-1","timeout_ms":5000}),
       scope(:conversation)},
      {:ack, ~s({"op":"ack","watch_ref":"watch-1","sequence":0,"timeout_ms":5000}),
       scope(:conversation)},
      {:resync, ~s({"op":"resync","watch_ref":"watch-1","timeout_ms":5000}),
       scope(:conversation)},
      {:cancel, ~s({"op":"cancel","target_request_id":"#{@project}","timeout_ms":5000}),
       scope(:global)},
      {:conversation_open,
       ~s({"op":"conversation.open","conversation_id":null,"timeout_ms":5000}), scope(:project)},
      {:dispatch_send,
       ~s({"op":"dispatch","action":"send","text":"hello","target":{"kind":"main","id":null},"attachment_refs":[],"timeout_ms":5000}),
       scope(:conversation)},
      {:run_control,
       ~s({"op":"run.control","run_id":"#{@run}","action":"pause","timeout_ms":5000}),
       scope(:run)},
      {:run_steer,
       ~s({"op":"run.steer","run_id":"#{@run}","node_id":null,"text":"please inspect","attachment_refs":[],"timeout_ms":5000}),
       scope(:run)},
      {:approval_resolve,
       ~s({"op":"approval.resolve","run_id":"#{@run}","node_id":null,"interaction_id":"#{@interaction}","expected_revision":0,"decision":"approve","timeout_ms":5000}),
       scope(:run)}
    ]
  end
end
