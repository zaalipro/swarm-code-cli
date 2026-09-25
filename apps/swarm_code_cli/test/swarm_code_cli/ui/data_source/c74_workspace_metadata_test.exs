defmodule SwarmCodeCLI.UI.DataSource.C74WorkspaceMetadataTest do
  @moduledoc """
  pass74 S1-11: the workspace metadata takes the service's 400 models (R5) and
  says whether the chat model's provider can answer (D11); both round-trip
  through the codec's exact-shape check, and a service without the new key
  still decodes.
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.DataSource.{Delta, DTO}

  @conversation "0b6d7c2e-6a40-4a4e-9c35-8f7c0d1b2a31"
  @provider "7f3a1c52-2f8e-4c3b-9a67-1d2e3f4a5b6c"

  defp metadata(fields) do
    Map.merge(
      %{
        "conversation_id" => @conversation,
        "mode" => "build",
        "project" => "ailogic",
        "chat_model" => "deepseek-v4-pro",
        "swarm_model" => "deepseek-v4-flash",
        "effort" => "high",
        "swarm_effort" => nil,
        "models" => [],
        "approval_mode" => "auto",
        "trusted" => true,
        "chat_provider" => "DeepSeek",
        "chat_provider_usable" => true,
        "context_used" => 0,
        "context_window" => 128_000,
        "cost_usd" => 0.0,
        "title" => "Refactor the parser",
        "queued" => 0,
        "queued_texts" => []
      },
      fields
    )
  end

  defp models(n),
    do:
      for(
        i <- 1..n,
        do: %{"provider_id" => @provider, "provider" => "DeepSeek", "model" => "m-#{i}"}
      )

  # The shape `PersistedBackend.broadcast_metadata/1` sends.
  defp delta(body),
    do: %{
      "kind" => "workspace_metadata",
      "entity_id" => nil,
      "run_id" => nil,
      "conversation_id" => @conversation,
      "channel" => nil,
      "attempt_id" => nil,
      "text" => nil,
      "body" => body,
      "sequence" => 1,
      "revision" => 3
    }

  test "400 models decode; 401 do not (R5)" do
    assert {:ok, %DTO.WorkspaceMetadata{models: models}} =
             DTO.WorkspaceMetadata.decode(metadata(%{"models" => models(400)}))

    assert length(models) == 400
    assert {:error, _} = DTO.WorkspaceMetadata.decode(metadata(%{"models" => models(401)}))

    assert {:ok, %Delta{body: %DTO.WorkspaceMetadata{models: [_ | _]}}} =
             Delta.decode(delta(metadata(%{"models" => models(400)})))
  end

  test "chat_provider_usable round-trips; a metadata without it decodes as unknown" do
    assert {:ok, %DTO.WorkspaceMetadata{chat_provider: "DeepSeek", chat_provider_usable: true}} =
             DTO.WorkspaceMetadata.decode(metadata(%{}))

    assert {:ok, %DTO.WorkspaceMetadata{chat_provider_usable: false}} =
             DTO.WorkspaceMetadata.decode(metadata(%{"chat_provider_usable" => false}))

    assert {:error, _} =
             DTO.WorkspaceMetadata.decode(metadata(%{"chat_provider_usable" => "yes"}))

    assert {:ok, %Delta{body: %DTO.WorkspaceMetadata{chat_provider_usable: false}}} =
             Delta.decode(delta(metadata(%{"chat_provider_usable" => false})))

    legacy = Map.delete(metadata(%{}), "chat_provider_usable")

    assert {:ok, %Delta{body: %DTO.WorkspaceMetadata{chat_provider_usable: nil}}} =
             Delta.decode(delta(legacy))
  end
end
