defmodule SwarmCode.Protocol.OrbitHomeRequestTest do
  use ExUnit.Case, async: true

  alias SwarmCode.Protocol.{Error, Scope, ServiceHandshake, ServiceRequest}

  @project "11111111-1111-4111-8111-111111111111"
  @conversation "22222222-2222-4222-8222-222222222222"
  @run "55555555-5555-4555-8555-555555555555"
  @source "33333333-3333-4333-8333-333333333333"
  @connection "44444444-4444-4444-8444-444444444444"

  defp overview(overrides \\ %{}),
    do:
      Map.merge(
        %{
          "op" => "home.overview",
          "timeout_ms" => 5000,
          "projects" => 6,
          "per_project" => 12,
          "byte_limit" => 131_072
        },
        overrides
      )

  defp search(overrides \\ %{}),
    do:
      Map.merge(
        %{
          "op" => "conversation.search",
          "timeout_ms" => 5000,
          "query" => "rate limit",
          "limit" => 50,
          "byte_limit" => 262_144
        },
        overrides
      )

  defp scope(:global), do: %Scope{kind: :global, id: nil, generation: 3}
  defp scope(:project), do: %Scope{kind: :project, id: @project, generation: 3}
  defp scope(:conversation), do: %Scope{kind: :conversation, id: @conversation, generation: 3}
  defp scope(:run), do: %Scope{kind: :run, id: @run, generation: 3}

  defp invalid(body, target_scope),
    do:
      assert(
        {:error, %Error{code: :invalid_envelope, message: "invalid protocol envelope"}} =
          ServiceRequest.decode(body, target_scope)
      )

  describe "home.overview" do
    test "round-trips in every non-run scope" do
      for kind <- [:global, :project, :conversation] do
        body = overview()

        assert {:ok, %ServiceRequest{operation: :home_overview} = request} =
                 ServiceRequest.decode(body, scope(kind))

        assert request.timeout_ms == 5000

        assert request.params == %{
                 "projects" => 6,
                 "per_project" => 12,
                 "byte_limit" => 131_072
               }

        assert {:ok, ^body} = ServiceRequest.encode(request, scope(kind))
      end
    end

    test "every bound is enforced at its edges" do
      for {key, low, high} <- [
            {"projects", 1, 8},
            {"per_project", 1, 24},
            {"byte_limit", 1, 1_048_576}
          ] do
        assert {:ok, _} = ServiceRequest.decode(overview(%{key => low}), scope(:global))
        assert {:ok, _} = ServiceRequest.decode(overview(%{key => high}), scope(:global))
        invalid(overview(%{key => low - 1}), scope(:global))
        invalid(overview(%{key => high + 1}), scope(:global))
        invalid(overview(%{key => nil}), scope(:global))
        invalid(overview(%{key => "3"}), scope(:global))
        invalid(overview(%{key => 3.0}), scope(:global))
      end
    end

    test "a missing key, an extra key (a client project_id) and a run scope are invalid" do
      invalid(Map.delete(overview(), "per_project"), scope(:global))
      invalid(Map.put(overview(), "project_id", @project), scope(:global))
      invalid(Map.put(overview(), "extra", 1), scope(:global))
      invalid(overview(), scope(:run))
      invalid(overview(%{"timeout_ms" => 0}), scope(:global))
    end

    test "encode revalidates a forged request" do
      assert {:error, %Error{code: :invalid_envelope}} =
               ServiceRequest.encode(
                 %ServiceRequest{
                   operation: :home_overview,
                   params: %{"projects" => 9, "per_project" => 12, "byte_limit" => 1},
                   timeout_ms: 5000
                 },
                 scope(:global)
               )
    end
  end

  describe "conversation.search" do
    test "round-trips in every non-run scope" do
      for kind <- [:global, :project, :conversation] do
        body = search()

        assert {:ok, %ServiceRequest{operation: :conversation_search} = request} =
                 ServiceRequest.decode(body, scope(kind))

        assert request.params == %{
                 "query" => "rate limit",
                 "limit" => 50,
                 "byte_limit" => 262_144
               }

        assert {:ok, ^body} = ServiceRequest.encode(request, scope(kind))
      end
    end

    test "limit and byte_limit are enforced at their edges" do
      for {key, low, high} <- [{"limit", 1, 50}, {"byte_limit", 1, 1_048_576}] do
        assert {:ok, _} = ServiceRequest.decode(search(%{key => low}), scope(:project))
        assert {:ok, _} = ServiceRequest.decode(search(%{key => high}), scope(:project))
        invalid(search(%{key => low - 1}), scope(:project))
        invalid(search(%{key => high + 1}), scope(:project))
        invalid(search(%{key => "5"}), scope(:project))
      end
    end

    test "the query is 1..200 valid bytes without control characters" do
      assert {:ok, _} = ServiceRequest.decode(search(%{"query" => "a"}), scope(:global))

      assert {:ok, _} =
               ServiceRequest.decode(
                 search(%{"query" => String.duplicate("a", 200)}),
                 scope(:global)
               )

      assert {:ok, _} =
               ServiceRequest.decode(search(%{"query" => "100% sure_\\ ünï"}), scope(:global))

      invalid(search(%{"query" => ""}), scope(:global))
      invalid(search(%{"query" => String.duplicate("a", 201)}), scope(:global))
      invalid(search(%{"query" => "two\nlines"}), scope(:global))
      invalid(search(%{"query" => "tab\there"}), scope(:global))
      invalid(search(%{"query" => "nul\0"}), scope(:global))
      invalid(search(%{"query" => "del\x7F"}), scope(:global))
      invalid(search(%{"query" => <<0xFF, 0xFE>>}), scope(:global))
      invalid(search(%{"query" => nil}), scope(:global))
      invalid(search(%{"query" => 7}), scope(:global))
    end

    test "a missing key, an extra key and a run scope are invalid" do
      invalid(Map.delete(search(), "limit"), scope(:global))
      invalid(Map.put(search(), "project_id", @project), scope(:global))
      invalid(search(), scope(:run))
    end
  end

  test "the home capability decodes to :home and encodes back" do
    body = %{
      "op" => "hello_ok",
      "body_version" => 1,
      "source_epoch" => @source,
      "connection_id" => @connection,
      "capabilities" => ["query", "conversation.list", "home"],
      "max_frame_bytes" => 1_048_576
    }

    assert {:ok, %{__struct__: ServiceHandshake.HelloOk} = hello_ok} =
             ServiceHandshake.decode_hello_ok(body)

    assert hello_ok.capabilities == [:query, :conversation_list, :home]
    assert {:ok, ^body} = ServiceHandshake.encode_hello_ok(hello_ok)
  end
end
