defmodule SwarmCode.Daemon.Service.SessionConfigurationTest do
  # pass70 B4 (decision D3, arch F4, rel F5): the database decides the model;
  # environment variables never create provider rows or rewrite a
  # conversation, except the first-run fallback and the in-memory
  # `ncode --model` session override.
  use ExUnit.Case, async: false

  alias SwarmCode.Daemon.Service.{SessionConfiguration, SessionSelection}
  alias SwarmCode.Domain.{Conversations, Providers, Repo, Cache}

  @swarm_env %{
    "SWARM_PROVIDER" => "openai",
    "SWARM_BASE_URL" => "http://127.0.0.1:45678/v1",
    "SWARM_MODEL" => "fixture-model",
    "SWARM_API_KEY" => "local-key",
    "SWARM_EFFORT" => "high"
  }

  setup do
    path = SchemaFixture.database!(:current, SwarmCode.Daemon.Test.LeaseFixture.build_root())
    start_supervised!({Repo, database: path, domain_fixture: true, pool_size: 1, log: false})
    Cache.clear()
    SessionConfiguration.clear_override()

    on_exit(fn ->
      Cache.clear()
      SessionConfiguration.clear_override()
      # cli022 F4: @swarm_env's SWARM_EFFORT is the session's chat effort.
      SessionConfiguration.clear_env_effort()
    end)

    root = Path.join(Path.dirname(path), "project")
    File.mkdir!(root)
    {:ok, session} = SessionSelection.open(root)
    # A real database always has its settings row; the fixture gets it here so
    # the byte-identical snapshots compare settings too.
    _ = SwarmCode.Domain.Settings.get_cached()
    %{session: session}
  end

  defp provider!(attrs) do
    {:ok, provider} =
      Providers.create(
        Map.merge(
          %{kind: "openai_compatible", base_url: "https://saved.invalid/v1", api_key: "saved"},
          attrs
        )
      )

    Cache.clear()
    provider
  end

  defp snapshot(conversation_id) do
    %{rows: providers} = Repo.query!("SELECT * FROM providers ORDER BY id")

    %{rows: conversation} =
      Repo.query!("SELECT * FROM conversations WHERE id = ?1", [conversation_id])

    %{rows: settings} = Repo.query!("SELECT * FROM settings")
    {providers, conversation, settings}
  end

  test "SWARM_* leave the providers table and the conversation row byte-identical", c do
    saved = provider!(%{name: "Saved", models: ["saved-model"], default_model: "saved-model"})

    {:ok, conversation} =
      Conversations.update(c.session.conversation, %{
        chat_provider_id: saved.id,
        chat_model: "saved-model"
      })

    session = %{c.session | conversation: conversation}
    before = snapshot(conversation.id)

    assert {:ok, prepared} = SessionConfiguration.prepare(session, @swarm_env)
    assert prepared.conversation.chat_provider_id == saved.id
    assert prepared.conversation.chat_model == "saved-model"
    refute Map.has_key?(prepared, :notice)
    assert SessionConfiguration.override() == nil
    assert snapshot(conversation.id) == before
  end

  test "--model is a session override resolved against the database, never persisted", c do
    a = provider!(%{name: "Alpha", models: ["a-model", "shared"], default_model: "a-model"})

    b =
      provider!(%{
        name: "Beta",
        base_url: "https://beta.invalid/v1",
        models: ["b-model", "shared"],
        default_model: "b-model"
      })

    {:ok, conversation} =
      Conversations.update(c.session.conversation, %{
        chat_provider_id: a.id,
        chat_model: "a-model"
      })

    session = %{c.session | conversation: conversation}
    before = snapshot(conversation.id)

    assert {:ok, prepared} =
             SessionConfiguration.prepare(session, %{"SWARM_MODEL_OVERRIDE" => "beta/b-model"})

    assert SessionConfiguration.override() == %{
             provider_id: b.id,
             model: "b-model",
             source: :flag
           }

    assert prepared.conversation.chat_provider_id == b.id
    assert prepared.conversation.swarm_model == "b-model"

    # The row is untouched; a turn gets the override from overlay/1.
    assert snapshot(conversation.id) == before
    fresh = Conversations.get!(conversation.id)
    assert fresh.chat_provider_id == a.id
    assert %{chat_provider_id: id, chat_model: "b-model"} = SessionConfiguration.overlay(fresh)
    assert id == b.id

    # A bare model id prefers the conversation's own provider.
    assert {:ok, _} = SessionConfiguration.prepare(session, %{"SWARM_MODEL_OVERRIDE" => "shared"})
    assert SessionConfiguration.override() == %{provider_id: a.id, model: "shared", source: :flag}

    # provider_id|model works too; an id nobody lists is refused.
    assert {:ok, _} =
             SessionConfiguration.prepare(session, %{"SWARM_MODEL_OVERRIDE" => "#{b.id}|shared"})

    assert SessionConfiguration.override() == %{provider_id: b.id, model: "shared", source: :flag}

    assert {:error, :unknown_model} =
             SessionConfiguration.prepare(session, %{"SWARM_MODEL_OVERRIDE" => "nobody-lists-it"})

    assert SessionConfiguration.override() == nil
    assert snapshot(conversation.id) == before

    SessionConfiguration.clear_override()
    assert SessionConfiguration.overlay(fresh) == fresh
  end

  # pass70 F: the dispatcher overlays only at the engine boundary, so an
  # explicit /model equal to the override is still written, and it ends the
  # override.
  test "a /model choice is persisted and ends the --model override", c do
    a = provider!(%{name: "Alpha", models: ["a-model"], default_model: "a-model"})

    b =
      provider!(%{
        name: "Beta",
        base_url: "https://beta.invalid/v1",
        models: ["b-model"],
        default_model: "b-model"
      })

    {:ok, conversation} =
      Conversations.update(c.session.conversation, %{
        chat_provider_id: a.id,
        chat_model: "a-model"
      })

    session = %{c.session | conversation: conversation}

    assert {:ok, _} =
             SessionConfiguration.prepare(session, %{"SWARM_MODEL_OVERRIDE" => "beta/b-model"})

    assert SessionConfiguration.override() == %{
             provider_id: b.id,
             model: "b-model",
             source: :flag
           }

    assert {:ok, _} =
             SwarmCode.Daemon.Service.CommandDispatcher.dispatch(
               conversation.id,
               "/model #{b.id}|b-model"
             )

    assert SessionConfiguration.override() == nil
    fresh = Conversations.get!(conversation.id)
    assert fresh.chat_provider_id == b.id
    assert fresh.chat_model == "b-model"
  end

  # cli021 qa: `/worker_model` (and the settings row and a profile that names
  # only the worker model) used to end the whole override, so a first-run
  # session (whose conversation stores no chat model) lost its chat model:
  # "no model provider" on the status line, and a refused next turn.
  test "a /worker_model choice ends only the worker half of the override", c do
    assert {:ok, prepared} = SessionConfiguration.prepare(c.session, @swarm_env)
    assert [provider] = Providers.list()

    {:ok, _} =
      Providers.update(provider, %{models: ["fixture-model", "worker-model"]})

    Cache.clear()
    id = prepared.conversation.id

    assert {:ok, _} =
             SwarmCode.Daemon.Service.CommandDispatcher.dispatch(
               id,
               "/worker_model #{provider.id}|worker-model"
             )

    fresh = Conversations.get!(id)
    assert fresh.swarm_model == "worker-model"
    assert fresh.chat_model == nil

    shown = SessionConfiguration.overlay(fresh)
    assert shown.chat_provider_id == provider.id
    assert shown.chat_model == "fixture-model"
    assert shown.swarm_model == "worker-model"
    assert SessionConfiguration.override_source(SessionConfiguration.override()) == :first_run_env

    # The chat choice still ends what is left.
    assert {:ok, _} =
             SwarmCode.Daemon.Service.CommandDispatcher.dispatch(
               id,
               "/model #{provider.id}|fixture-model"
             )

    assert SessionConfiguration.override() == nil
    assert SessionConfiguration.overlay(Conversations.get!(id)).swarm_model == "worker-model"
  end

  test "first run: no usable provider, SWARM_* create exactly one row and say so", c do
    before_conversation = Repo.query!("SELECT * FROM conversations").rows

    assert {:ok, prepared} = SessionConfiguration.prepare(c.session, @swarm_env)
    assert prepared.notice =~ "First run"
    assert [provider] = Providers.list()
    assert provider.base_url == "http://127.0.0.1:45678/v1"
    assert provider.default_model == "fixture-model"
    assert provider.api_key == "local-key"

    assert SessionConfiguration.override() ==
             %{provider_id: provider.id, model: "fixture-model", source: :first_run_env}

    assert Repo.query!("SELECT * FROM conversations").rows == before_conversation

    # The next launch finds a usable provider and writes nothing.
    Cache.clear()
    before = snapshot(c.session.conversation.id)
    assert {:ok, again} = SessionConfiguration.prepare(c.session, @swarm_env)
    refute Map.get(again, :notice)
    assert snapshot(c.session.conversation.id) == before
  end

  test "first run fills the key of a keyless row for the same endpoint instead of adding one",
       c do
    keyless =
      provider!(%{
        name: "Seeded",
        base_url: "http://127.0.0.1:45678/v1",
        api_key: "",
        models: ["seeded-model"],
        default_model: "seeded-model"
      })

    # Not usable (no key, and 127.0.0.1 would be, so use a remote endpoint).
    {:ok, keyless} = Providers.update(keyless, %{base_url: "https://seeded.invalid/v1"})
    Cache.clear()
    env = Map.put(@swarm_env, "SWARM_BASE_URL", "https://seeded.invalid/v1")

    assert {:ok, prepared} = SessionConfiguration.prepare(c.session, env)
    assert prepared.notice =~ "gave the provider Seeded the key"
    assert [provider] = Providers.list()
    assert provider.id == keyless.id
    assert provider.api_key == "local-key"
  end

  test "without a usable provider or SWARM_* the session refuses and writes nothing", c do
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

  # cli020 B13 (onboarding-4, onboarding-21, ux-live-11).
  test "a bare ANTHROPIC_API_KEY onboards Anthropic, named after the preset", c do
    env = %{"ANTHROPIC_API_KEY" => "sk-ant-fixture", "SWARM_MODEL" => "claude-fixture"}
    assert {:ok, prepared} = SessionConfiguration.prepare(c.session, env)
    assert prepared.notice =~ "added the provider Anthropic"
    assert [provider] = Providers.list()
    assert provider.kind == "anthropic"
    assert provider.base_url == "https://api.anthropic.com"
    assert provider.name == "Anthropic"
    assert provider.default_model == "claude-fixture"
    assert SessionConfiguration.override_source(SessionConfiguration.override()) == :first_run_env
  end

  test "a bare OPENAI_API_KEY onboards OpenAI at api.openai.com/v1", c do
    env = %{"OPENAI_API_KEY" => "sk-fixture", "SWARM_MODEL" => "gpt-fixture"}
    assert {:ok, _prepared} = SessionConfiguration.prepare(c.session, env)
    assert [provider] = Providers.list()
    assert provider.kind == "openai_compatible"
    assert provider.base_url == "https://api.openai.com/v1"
    assert provider.name == "OpenAI"
  end

  test "a key without a model is model_required; a generic key without a URL is endpoint_required",
       c do
    assert {:error, :model_required} =
             SessionConfiguration.prepare(c.session, %{"ANTHROPIC_API_KEY" => "sk-ant"})

    assert {:error, :model_required} =
             SessionConfiguration.prepare(c.session, %{"OPENAI_API_KEY" => "sk"})

    assert {:error, :endpoint_required} =
             SessionConfiguration.prepare(c.session, %{
               "SWARM_API_KEY" => "k",
               "SWARM_MODEL" => "m"
             })

    assert Providers.list() == []
  end

  test "a base URL that is no preset names the row after its host", c do
    assert {:ok, _} = SessionConfiguration.prepare(c.session, @swarm_env)
    assert [provider] = Providers.list()
    assert provider.name == "127.0.0.1"
  end

  test "override_source/1 says where an override came from", c do
    assert SessionConfiguration.override_source(nil) == nil

    saved = provider!(%{name: "Saved", models: ["saved-model"], default_model: "saved-model"})

    assert {:ok, _} =
             SessionConfiguration.prepare(c.session, %{"SWARM_MODEL_OVERRIDE" => "saved-model"})

    assert %{provider_id: id} = SessionConfiguration.override()
    assert id == saved.id
    assert SessionConfiguration.override_source(SessionConfiguration.override()) == :flag
    assert SessionConfiguration.override_source(%{provider_id: "x", model: "y"}) == :flag
  end
end
