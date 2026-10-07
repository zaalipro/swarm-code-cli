defmodule SwarmCode.Domain.Providers do
  @moduledoc """
  CRUD for LLM providers, seeding, model fetching and model resolution.
  """
  import Ecto.Query, warn: false, except: [update: 2]

  alias SwarmCode.Domain.Conversations.Conversation
  alias SwarmCode.Domain.LLM
  alias SwarmCode.Domain.Providers.Provider
  alias SwarmCode.Domain.Repo
  alias SwarmCode.Domain.Settings

  def list, do: Repo.all(from(p in Provider, order_by: p.name))

  def get(id), do: Repo.get(Provider, id)

  @doc """
  `get/1` through `SwarmCode.Domain.Cache` (spec 54 §1.3, 54a A2).

  For the engine's hot path only — `AgentServer.refresh_provider/1` runs once
  per LLM call, and under eight concurrent lanes that was 14 488 of 152 224
  queries. `broadcast/0` (every create, update and delete) drops the key, so a
  rotated key still reaches the next request, which is what spec 51 §6.8 asked
  for.
  """
  def get_cached(id), do: SwarmCode.Domain.Cache.fetch({:provider, id}, fn -> get(id) end)

  def get!(id), do: Repo.get!(Provider, id)

  def change(%Provider{} = provider, attrs \\ %{}), do: Provider.changeset(provider, attrs)

  def create(attrs) do
    case %Provider{} |> Provider.changeset(attrs) |> Repo.insert() do
      {:ok, provider} ->
        broadcast()
        {:ok, provider}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def update(%Provider{} = provider, attrs) do
    case provider |> Provider.changeset(attrs) |> Repo.update() do
      {:ok, provider} ->
        # spec 73 T82: an edited row starts over on what it was seen to reject.
        LLM.ProviderCaps.forget(provider)
        broadcast()
        {:ok, provider}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # Spec 51 §1.7: every Settings tier that can name a provider, with its model.
  # A deleted provider must not stay selected anywhere (the Settings page showed
  # a dead selection and research silently ran on the swarm default). Spec 45
  # §4.1: a deleted implementer provider means "planner implements".
  @tier_pairs [
    {:default_chat_provider_id, :default_chat_model},
    {:default_swarm_provider_id, :default_swarm_model},
    {:default_implementer_provider_id, :default_implementer_model},
    {:default_validator_provider_id, :default_validator_model},
    {:default_workflow_provider_id, :default_workflow_model},
    {:default_scheduled_provider_id, :default_scheduled_model},
    {:research_lead_provider_id, :research_lead_model},
    {:research_worker_provider_id, :research_worker_model},
    {:research_reporter_provider_id, :research_reporter_model}
  ]

  def delete(%Provider{} = provider) do
    {:ok, provider} = Repo.delete(provider)
    # spec 73 T82
    LLM.ProviderCaps.forget(provider)

    settings = Settings.get()

    attrs =
      Enum.reduce(@tier_pairs, %{}, fn {id_field, model_field}, acc ->
        if Map.get(settings, id_field) == provider.id,
          do: acc |> Map.put(id_field, nil) |> Map.put(model_field, nil),
          else: acc
      end)

    if attrs != %{}, do: Settings.update(attrs)

    clear_provider_refs(provider.id)
    broadcast()
    {:ok, provider}
  end

  defp clear_provider_refs(id) do
    Repo.update_all(from(c in Conversation, where: c.chat_provider_id == ^id),
      set: [chat_provider_id: nil, chat_model: nil]
    )

    Repo.update_all(from(c in Conversation, where: c.swarm_provider_id == ^id),
      set: [swarm_provider_id: nil, swarm_model: nil]
    )

    Repo.update_all(from(c in Conversation, where: c.implementer_provider_id == ^id),
      set: [implementer_provider_id: nil, implementer_model: nil]
    )

    # Spec 51 §1.7: the judge override too.
    Repo.update_all(from(c in Conversation, where: c.judge_provider_id == ^id),
      set: [judge_provider_id: nil, judge_model: nil]
    )

    # Spec 75 (pass 71): and the mission validator override.
    Repo.update_all(from(c in Conversation, where: c.validator_provider_id == ^id),
      set: [validator_provider_id: nil, validator_model: nil]
    )

    :ok
  end

  def broadcast do
    # Spec 54 §1.3: the cache is invalidated by the broadcast the writers
    # already send, so it needs no TTL and never goes stale.
    SwarmCode.Domain.Cache.invalidate(:provider)
    # spec 55 T14 (55a A9): the cached list `Workflows.resolve_model/3` reads.
    SwarmCode.Domain.Cache.invalidate(:providers)
    SwarmCode.Domain.PubSub.broadcast(SwarmCode.Domain.PubSub, "providers", {:providers_changed})
  end

  def subscribe, do: SwarmCode.Domain.PubSub.subscribe(SwarmCode.Domain.PubSub, "providers")

  # ncode ships with no provider; the first-run flow asks the user to add one
  # (BYOK). Existing rows are never touched. Kept as a function because
  # `SwarmCode.Domain.Bootstrap` runs it as a boot step and tests inject it.
  def seed_defaults, do: :ok

  def fetch_models(%Provider{} = provider) do
    case LLM.list_models(provider) do
      {:ok, ids} ->
        case update(provider, %{models: ids |> Enum.uniq() |> Enum.sort()}) do
          {:ok, p} -> {:ok, p.models}
          {:error, _cs} -> {:error, "could not save models"}
        end

      {:error, msg} ->
        # spec 60 T13: a gateway that echoes a non-`sk-` key in its error body.
        {:error, SwarmCode.Domain.LLM.HTTP.redact(msg, [provider.api_key || ""])}
    end
  end

  def model_options do
    for p <- list(), m <- p.models || [] do
      {"#{p.name} · #{m}", "#{p.id}|#{m}"}
    end
  end

  @doc """
  The same options as `model_options/0`, grouped by provider for the composer's
  model chooser: `[{provider_name, [{model, "provider_id|model"}]}]`.
  """
  def grouped_models do
    for p <- list(), (p.models || []) != [] do
      {p.name, for(m <- p.models, do: {m, "#{p.id}|#{m}"})}
    end
  end

  @doc "The `\"<provider_id>|<model>\"` option string of a pair, or nil when either is missing (spec 40 §1.2)."
  @spec option(String.t() | nil, String.t() | nil) :: String.t() | nil
  def option(provider_id, model) when is_binary(provider_id) and is_binary(model),
    do: provider_id <> "|" <> model

  def option(_provider_id, _model), do: nil

  def parse_option(value) when is_binary(value) do
    case String.split(value, "|", parts: 2) do
      [provider_id, model] when provider_id != "" and model != "" -> {provider_id, model}
      _ -> nil
    end
  end

  def parse_option(_), do: nil

  # Spec 37 §1.4: the judge falls back to the swarm model, then to the defaults —
  # a conversation that never picked a judge still gets a second opinion.
  def effective_model(%Conversation{} = conversation, :judge) do
    resolve(conversation.judge_provider_id, conversation.judge_model) ||
      effective_model(conversation, :swarm)
  end

  # Spec 45 §4.1: the implementer has no fallback — nil means "planner
  # implements", so a conversation without one never gets a third model.
  def effective_model(%Conversation{} = conversation, :implementer) do
    settings = Settings.get_cached()

    resolve(conversation.implementer_provider_id, conversation.implementer_model) ||
      resolve(settings.default_implementer_provider_id, settings.default_implementer_model)
  end

  # Spec 75 (pass 71): the validator — the conversation's pick, then the
  # Settings default, then the main (orchestrator) model, so an unconfigured
  # conversation validates on the model it plans with.
  def effective_model(%Conversation{} = conversation, :validator) do
    settings = Settings.get_cached()

    resolve(conversation.validator_provider_id, conversation.validator_model) ||
      resolve(settings.default_validator_provider_id, settings.default_validator_model) ||
      effective_model(conversation, :chat)
  end

  def effective_model(%Conversation{} = conversation, kind) when kind in [:chat, :swarm] do
    # Spec 54 §1.3: three of these ran at every run start (54a A2).
    settings = Settings.get_cached()

    {conv_provider_id, conv_model, default_provider_id, default_model} =
      case kind do
        :chat ->
          {conversation.chat_provider_id, conversation.chat_model,
           settings.default_chat_provider_id, settings.default_chat_model}

        :swarm ->
          {conversation.swarm_provider_id, conversation.swarm_model,
           settings.default_swarm_provider_id, settings.default_swarm_model}
      end

    resolve(conv_provider_id, conv_model) || resolve(default_provider_id, default_model) ||
      fallback()
  end

  @doc """
  The model and effort of a mission agent's slot (spec 75 §5.1): `opts[:role]`
  `:orchestrator` is the conversation's main model, `:worker` its worker model
  (the `swarm_*` slot), `:validator` its validator. Strings are accepted too
  (a role read back from JSON); nothing is converted to an atom. An explicit
  `model:`/`provider:` leaves the model to `Workflows.resolve_model/3` and an
  explicit `effort:` leaves the effort to the caller — both come back nil.
  """
  @spec role_model(keyword(), Conversation.t() | nil) ::
          {%{provider: Provider.t(), model: String.t()} | nil, String.t() | nil}
  def role_model(_opts, nil), do: {nil, nil}

  def role_model(opts, %Conversation{} = conversation) do
    case role_kind(opts[:role]) do
      nil ->
        {nil, nil}

      kind ->
        model =
          if opts[:model] || opts[:provider] do
            nil
          else
            case effective_model(conversation, kind) do
              {:ok, model} -> model
              _none -> nil
            end
          end

        effort = if opts[:effort], do: nil, else: role_effort(conversation, kind)
        {model, effort}
    end
  end

  defp role_kind(role) when role in [:orchestrator, "orchestrator"], do: :chat
  defp role_kind(role) when role in [:worker, "worker"], do: :swarm
  defp role_kind(role) when role in [:validator, "validator"], do: :validator
  defp role_kind(_role), do: nil

  defp role_effort(conversation, :chat) do
    settings = Settings.get_cached()
    conversation.effort || settings.default_effort || "medium"
  end

  defp role_effort(conversation, :swarm) do
    settings = Settings.get_cached()
    conversation.swarm_effort || settings.default_swarm_effort || "medium"
  end

  defp role_effort(conversation, :validator) do
    settings = Settings.get_cached()

    conversation.validator_effort || settings.default_validator_effort ||
      role_effort(conversation, :chat)
  end

  defp resolve(provider_id, model) when is_binary(provider_id) and is_binary(model) do
    case get_cached(provider_id) do
      nil -> nil
      provider -> {:ok, %{provider: provider, model: model}}
    end
  end

  defp resolve(_, _), do: nil

  defp fallback do
    case Enum.find(list(), fn p ->
           p.default_model not in [nil, ""] and is_binary(p.api_key) and
             String.trim(p.api_key) != ""
         end) do
      nil -> {:error, :not_configured}
      p -> {:ok, %{provider: p, model: p.default_model}}
    end
  end
end
