defmodule SwarmCode.Daemon.Service.SessionConfigurationTest do
  use ExUnit.Case, async: false

  alias SwarmCode.Daemon.Service.{SessionConfiguration, SessionSelection}
  alias SwarmCode.Domain.{Conversations, Providers, Repo, Cache}

  setup do
    path = SchemaFixture.database!(:current, SwarmCode.Daemon.Test.LeaseFixture.build_root())
    start_supervised!({Repo, database: path, domain_fixture: true, pool_size: 1, log: false})
    Cache.clear()
    on_exit(&Cache.clear/0)
    root = Path.join(Path.dirname(path), "project")
    File.mkdir!(root)
    {:ok, session} = SessionSelection.open(root)
    %{session: session}
  end

  test "explicit endpoint and model configure saved chat and swarm without duplicate providers",
       c do
    env = %{
      "SWARM_PROVIDER" => "openai",
      "SWARM_BASE_URL" => "http://127.0.0.1:45678/v1",
      "SWARM_MODEL" => "fixture-model",
      "SWARM_API_KEY" => "local-key",
      "SWARM_EFFORT" => "high"
    }

    assert {:ok, configured} = SessionConfiguration.prepare(c.session, env)
    conversation = Conversations.get!(configured.conversation.id)
    provider = Providers.get!(conversation.chat_provider_id)
    assert provider.kind == "openai_compatible"
    assert provider.base_url == "http://127.0.0.1:45678/v1"
    assert provider.api_key == "local-key"
    assert conversation.chat_model == "fixture-model"
    assert conversation.swarm_provider_id == provider.id
    assert conversation.swarm_model == "fixture-model"
    assert conversation.effort == "high"

    assert {:ok, again} =
             SessionConfiguration.prepare(configured, Map.delete(env, "SWARM_API_KEY"))

    assert again.conversation.chat_provider_id == provider.id
    assert Providers.get!(provider.id).api_key == "local-key"
    assert length(Providers.list()) == 1
  end

  test "saved provider selections work without environment overrides", c do
    {:ok, provider} =
      Providers.create(%{
        name: "Saved provider",
        kind: "anthropic",
        base_url: "http://127.0.0.1:45679",
        models: ["saved-model"],
        default_model: "saved-model"
      })

    {:ok, conversation} =
      Conversations.update(c.session.conversation, %{
        chat_provider_id: provider.id,
        chat_model: "saved-model"
      })

    assert {:ok, selected} =
             SessionConfiguration.prepare(%{c.session | conversation: conversation}, %{})

    assert selected.conversation.chat_provider_id == provider.id
    assert selected.conversation.chat_model == "saved-model"
    assert length(Providers.list()) == 1
  end

  test "missing or invalid configuration refuses before creating a provider", c do
    assert {:error, :provider_required} = SessionConfiguration.prepare(c.session, %{})

    assert {:error, :endpoint_required} =
             SessionConfiguration.prepare(c.session, %{
               "SWARM_MODEL" => "fixture",
               "ANTHROPIC_BASE_URL" => "http://127.0.0.1:45679"
             })

    assert {:error, :invalid_provider} =
             SessionConfiguration.prepare(c.session, %{
               "SWARM_MODEL" => "fixture",
               "SWARM_BASE_URL" => "not-an-endpoint"
             })

    assert Providers.list() == []
  end
end
