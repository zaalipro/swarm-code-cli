defmodule SwarmCode.Daemon.Service.SessionConfiguration do
  @moduledoc "Applies explicit CLI provider settings to a selected persisted conversation."
  import Ecto.Query
  alias SwarmCode.Daemon.Runtime.Configuration
  alias SwarmCode.Domain.{Conversations, Providers, Repo}
  alias SwarmCode.Domain.Providers.Provider

  @override_keys ~w(SWARM_PROVIDER SWARM_MODEL SWARM_BASE_URL OPENAI_MODEL ANTHROPIC_MODEL)

  def prepare(%{conversation: conversation, project: project} = session, env) when is_map(env) do
    if Enum.any?(@override_keys, &Map.has_key?(env, &1)) do
      with :ok <- explicit_endpoint(env),
           {:ok, config} <- Configuration.from_env(env, project.root_path) do
        Repo.retry(:session_configuration, fn ->
          Repo.transaction(
            fn ->
              with {:ok, provider} <- provider(config, env),
                   {:ok, conversation} <-
                     Conversations.update(conversation, %{
                       chat_provider_id: provider.id,
                       chat_model: config[:model],
                       swarm_provider_id: provider.id,
                       swarm_model: config[:model],
                       effort: config[:effort],
                       swarm_effort: config[:effort]
                     }) do
                %{session | conversation: conversation}
              else
                _ -> Repo.rollback(:provider_configuration_failed)
              end
            end,
            mode: :immediate
          )
        end)
      end
    else
      case Providers.effective_model(conversation, :chat) do
        {:ok, _} -> {:ok, session}
        _ -> {:error, :provider_required}
      end
    end
  rescue
    _ -> {:error, :provider_configuration_failed}
  end

  def prepare(_, _), do: {:error, :invalid_session}

  defp explicit_endpoint(env) do
    key =
      if env["SWARM_PROVIDER"] == "anthropic", do: "ANTHROPIC_BASE_URL", else: "OPENAI_BASE_URL"

    case Map.get(env, "SWARM_BASE_URL", Map.get(env, key)) do
      value when is_binary(value) and byte_size(value) > 0 -> :ok
      _ -> {:error, :endpoint_required}
    end
  end

  defp provider(config, env) do
    endpoint = config[:provider]
    kind = if endpoint.kind == "anthropic", do: "anthropic", else: "openai_compatible"
    digest = :crypto.hash(:sha256, [kind, "\n", endpoint.base_url]) |> Base.encode16(case: :lower)
    name = "CLI " <> kind <> " " <> binary_part(digest, 0, 16)
    existing = Repo.one(from(p in Provider, where: p.name == ^name, limit: 1))

    attrs = %{
      name: name,
      kind: kind,
      base_url: endpoint.base_url,
      default_model: config[:model],
      models: [config[:model]]
    }

    key = if endpoint.kind == "anthropic", do: "ANTHROPIC_API_KEY", else: "OPENAI_API_KEY"

    attrs =
      if Map.has_key?(env, "SWARM_API_KEY") or Map.has_key?(env, key),
        do: Map.put(attrs, :api_key, endpoint.api_key),
        else: attrs

    case existing do
      nil ->
        Providers.create(attrs)

      %{kind: ^kind, base_url: url} = provider when url == endpoint.base_url ->
        Providers.update(
          provider,
          Map.put(attrs, :models, Enum.uniq((provider.models || []) ++ [config[:model]]))
        )

      _ ->
        {:error, :provider_identity_conflict}
    end
  end
end
