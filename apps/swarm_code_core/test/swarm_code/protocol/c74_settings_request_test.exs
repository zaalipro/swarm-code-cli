defmodule SwarmCode.Protocol.C74SettingsRequestTest do
  use ExUnit.Case, async: true

  alias SwarmCode.Protocol.{Scope, ServiceHandshake, ServiceRequest}

  @global %Scope{kind: :global, id: nil, generation: 0}
  @uuid "11111111-1111-4111-8111-111111111111"
  @canary "sk-canary-7Q2X-DO-NOT-SHOW"

  defp query(overrides \\ %{}) do
    Map.merge(
      %{
        "op" => "settings.query",
        "timeout_ms" => 15_000,
        "view" => "values",
        "sections" => nil,
        "keys" => nil,
        "kind" => nil,
        "id" => nil,
        "project_id" => nil,
        "cursor" => nil,
        "page_size" => 200,
        "byte_limit" => 900_000,
        "options" => nil
      },
      overrides
    )
  end

  defp command(overrides \\ %{}) do
    Map.merge(
      %{
        "op" => "settings.command",
        "timeout_ms" => 15_000,
        "action" => "values.patch",
        "target" => nil,
        "attributes" => %{"changes" => []},
        "expected" => %{},
        "secrets" => [],
        "dry_run" => false
      },
      overrides
    )
  end

  test "both operations decode and encode back in the global scope" do
    assert {:ok, %ServiceRequest{operation: :settings_query} = request} =
             ServiceRequest.decode(query(), @global)

    assert {:ok, body} = ServiceRequest.encode(request, @global)
    assert body["op"] == "settings.query"

    assert {:ok, %ServiceRequest{operation: :settings_command}} =
             ServiceRequest.decode(command(), @global)
  end

  test "a scope other than global is refused" do
    for kind <- [:project, :conversation, :run] do
      scope = %Scope{kind: kind, id: @uuid, generation: 0}
      assert {:error, _} = ServiceRequest.decode(query(), scope)
      assert {:error, _} = ServiceRequest.decode(command(), scope)
    end
  end

  test "the exact key set: a missing or an extra key is refused" do
    assert {:error, _} = ServiceRequest.decode(Map.delete(query(), "options"), @global)
    assert {:error, _} = ServiceRequest.decode(Map.put(query(), "secrets", []), @global)
    assert {:error, _} = ServiceRequest.decode(Map.delete(command(), "dry_run"), @global)
  end

  test "every bound, just inside and just outside" do
    inside = [
      query(%{"page_size" => 1}),
      query(%{"page_size" => 200}),
      query(%{"byte_limit" => 4_096}),
      query(%{"keys" => List.duplicate("k", 400)}),
      query(%{"id" => String.duplicate("i", 512)}),
      query(%{"options" => %{"slot" => String.duplicate("s", 32)}}),
      command(%{"secrets" => Enum.map(1..16, &%{"slot" => "s#{&1}", "value" => "v"})}),
      command(%{"attributes" => %{"list" => List.duplicate(1, 2_048)}}),
      command(%{"target" => Map.new(1..16, &{"k#{&1}", "v"})})
    ]

    outside = [
      query(%{"page_size" => 201}),
      query(%{"byte_limit" => 4_095}),
      query(%{"keys" => List.duplicate("k", 401)}),
      query(%{"id" => String.duplicate("i", 513)}),
      query(%{"options" => %{"slot" => String.duplicate("s", 33)}}),
      query(%{"view" => "everything"}),
      command(%{"secrets" => Enum.map(1..17, &%{"slot" => "s#{&1}", "value" => "v"})}),
      command(%{"attributes" => %{"list" => List.duplicate(1, 2_049)}}),
      command(%{"target" => Map.new(1..17, &{"k#{&1}", "v"})}),
      command(%{"action" => "provider.show_key"}),
      command(%{"secrets" => [%{"slot" => "a", "value" => String.duplicate("v", 8_193)}]})
    ]

    for body <- inside, do: assert({:ok, _} = ServiceRequest.decode(body, @global))
    for body <- outside, do: assert({:error, _} = ServiceRequest.decode(body, @global))
  end

  test "inspect of a request never shows a pasted secret" do
    {:ok, request} =
      ServiceRequest.decode(
        command(%{
          "action" => "provider.set_key",
          "secrets" => [%{"slot" => "api_key", "value" => @canary}]
        }),
        @global
      )

    refute inspect(request) =~ @canary
    assert inspect(request) =~ "1 redacted"
  end

  test "the capability set has 17 names and settings is one of them" do
    names =
      ~w(query detail watch conversation.open conversation.list conversation.new mark_seen
         project.update dispatch.send run.pause run.continue run.stop run.steer approval.resolve
         feature.command question.answer settings)

    assert length(names) == 17

    ok = %{
      "op" => "hello_ok",
      "body_version" => 1,
      "source_epoch" => @uuid,
      "connection_id" => @uuid,
      "capabilities" => names,
      "max_frame_bytes" => 1_048_576
    }

    assert {:ok, hello_ok} = ServiceHandshake.decode_hello_ok(ok)
    assert :settings in hello_ok.capabilities
    assert {:ok, encoded} = ServiceHandshake.encode_hello_ok(hello_ok)
    assert encoded["capabilities"] == names
  end
end
