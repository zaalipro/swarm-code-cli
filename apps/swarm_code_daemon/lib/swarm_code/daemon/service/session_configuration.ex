defmodule SwarmCode.Daemon.Service.SessionConfiguration do
  @moduledoc """
  Resolves which provider and model a saved session uses (pass70 B4, decision D3).

  The database decides, exactly like the desktop: the conversation's own choice,
  then the settings default, then the first usable provider
  (`Providers.effective_model/2`). Environment variables never create provider
  rows and never rewrite a conversation. Two exceptions, both in memory only:

  - `SWARM_MODEL_OVERRIDE` (`model` or `provider/model`, set only by
    `ncode --model`) is a session override resolved against the providers
    in the database. It is never persisted; `overlay/1` applies it to a
    conversation struct right before a turn starts.
  - First run: when the database has no usable provider at all and `SWARM_*`
    names an endpoint and a model, one provider row is created from them (or a
    matching row without a key gets the key), the session uses it, and the
    session carries a `:notice` saying so.
  """
  alias SwarmCode.Daemon.Runtime.Configuration
  alias SwarmCode.Domain.{Providers, Settings}

  @override_key :session_model_override
  @notice_key :session_provider_notice
  @first_run_keys ~w(SWARM_MODEL SWARM_BASE_URL OPENAI_MODEL ANTHROPIC_MODEL
                     OPENAI_API_KEY ANTHROPIC_API_KEY)

  @type override :: %{
          required(:provider_id) => String.t(),
          required(:model) => String.t(),
          optional(:source) => :flag | :first_run_env,
          optional(:roles) => [:chat | :swarm]
        }

  @doc """
  Prepares `session` (`%{project: _, conversation: _}`) for `env`. Returns the
  session, with the conversation overlaid by a session override when there is
  one and a `:notice` string when the first-run fallback wrote a provider.
  """
  @spec prepare(map(), map()) :: {:ok, map()} | {:error, atom()}
  def prepare(%{conversation: conversation, project: project} = session, env) when is_map(env) do
    clear_override()
    Application.delete_env(:swarm_code_daemon, @notice_key)

    result =
      case blank_to_nil(env["SWARM_MODEL_OVERRIDE"]) do
        nil -> from_database(session, conversation, project, env)
        override -> with_override(session, conversation, override)
      end

    with {:ok, session} <- result,
         do: {:ok, %{session | conversation: overlay(session.conversation)}}
  rescue
    _ -> {:error, :provider_configuration_failed}
  end

  def prepare(_, _), do: {:error, :invalid_session}

  @doc """
  The conversation as this session runs it: the session override (if any)
  replaces the chat and swarm provider/model in memory. Callers that start a
  turn from a freshly loaded conversation (the backend, the dispatcher) pass
  it through here; nothing is written.
  """
  @spec overlay(struct() | map()) :: struct() | map()
  def overlay(%{} = conversation), do: overlay(conversation, override())

  @doc """
  `overlay/1` for a given override (the settings values read it from their
  context). cli021 qa: an override whose worker half was released by an
  explicit worker choice (`release/1`) replaces only the chat fields.
  """
  @spec overlay(struct() | map(), override() | nil) :: struct() | map()
  def overlay(%{} = conversation, %{provider_id: id, model: model} = override) do
    roles = roles(override)

    conversation =
      if :chat in roles,
        do: %{conversation | chat_provider_id: id, chat_model: model},
        else: conversation

    if :swarm in roles,
      do: %{conversation | swarm_provider_id: id, swarm_model: model},
      else: conversation
  end

  def overlay(%{} = conversation, _override), do: conversation

  @doc "The model slots an override still covers (`:chat`, `:swarm`; both unless released)."
  @spec roles(map() | nil) :: [:chat | :swarm]
  def roles(%{roles: roles}) when is_list(roles), do: roles
  def roles(%{provider_id: _, model: _}), do: [:chat, :swarm]
  def roles(_override), do: []

  @doc """
  cli021 qa: an explicit choice for one slot ends the override for that slot
  only. A worker choice (`/worker_model`, the settings row, a profile naming
  only the worker model) used to drop the whole override, and a session whose
  conversation stores no chat model of its own (a first run from `NCODE_*`)
  then had no chat model at all. `release(:chat)` ends everything, as
  `/model` always did.
  """
  @spec release(:chat | :swarm) :: :ok
  def release(:chat), do: clear_override()

  def release(:swarm) do
    case override() do
      %{} = override ->
        case roles(override) -- [:swarm] do
          [] ->
            clear_override()

          left ->
            Application.put_env(
              :swarm_code_daemon,
              @override_key,
              Map.put(override, :roles, left)
            )
        end

      _ ->
        :ok
    end

    :ok
  end

  @doc "The active session override, or nil."
  @spec override() :: override() | nil
  def override, do: Application.get_env(:swarm_code_daemon, @override_key)

  @doc """
  The first-run sentence of this session ("First run: added the provider …"),
  or nil. The TUI shows it once as a toast; the exit summary repeats it.
  """
  @spec notice() :: String.t() | nil
  def notice, do: Application.get_env(:swarm_code_daemon, @notice_key)

  @doc """
  cli020 B13 (ux-live-11): where a session override came from: `:flag` for
  `ncode --model`, `:first_run_env` for the provider the first run made from
  `NCODE_*`/`SWARM_*`, nil without an override (Settings labels it, C13).
  """
  @spec override_source(map() | nil) :: :flag | :first_run_env | nil
  def override_source(nil), do: nil
  def override_source(%{source: source}) when source in [:flag, :first_run_env], do: source
  def override_source(%{}), do: :flag
  def override_source(_), do: nil

  @doc "Drops the session override (an explicit `/model` choice wins from then on)."
  @spec clear_override() :: :ok
  def clear_override do
    Application.delete_env(:swarm_code_daemon, @override_key)
    :ok
  end

  ## Database default

  defp from_database(session, conversation, project, env) do
    case Providers.effective_model(conversation, :chat) do
      {:ok, %{provider: provider}} ->
        if usable?(provider) or Enum.any?(Providers.list(), &usable?/1),
          do: {:ok, session},
          else: first_run(session, project, env, {:ok, session})

      _ ->
        first_run(session, project, env, {:error, :provider_required})
    end
  end

  @doc """
  pass74 D11: the one "usable" predicate of launch, dispatch and the settings
  attention: a provider can serve a turn when it has a non-blank key, or when its
  base URL is a private host (loopback, RFC 1918, link-local, `.local`,
  `.internal`, `.home.arpa` — `WebFetch.private_host?/1`) that needs none.
  """
  @spec usable?(map() | nil) :: boolean()
  def usable?(%{} = provider) do
    key = Map.get(provider, :api_key)
    url = Map.get(provider, :base_url)

    (is_binary(key) and String.trim(key) != "") or
      (is_binary(url) and String.trim(url) != "" and
         SwarmCode.Domain.Tools.WebFetch.private_host?(url))
  end

  def usable?(_provider), do: false

  ## Session override

  defp with_override(session, conversation, value) do
    case resolve_override(conversation, value) do
      {:ok, provider, model} ->
        put_override(provider.id, model, :flag)
        {:ok, session}

      :error ->
        {:error, :unknown_model}
    end
  end

  # `provider/model` (provider by name, case-insensitive, longest name first,
  # or by id), `provider_id|model`, or a bare model id listed by a provider:
  # the conversation's own provider first, then the settings default, then the
  # first by name. Like `/model`, an id no provider lists is refused.
  defp resolve_override(conversation, value) do
    providers = Providers.list()
    lists? = fn provider, model -> model in (provider.models || []) end

    prefixed =
      providers
      |> Enum.sort_by(&(-String.length(&1.name || "")))
      |> Enum.find_value(fn provider ->
        Enum.find_value([provider.name, provider.id], fn prefix ->
          if is_binary(prefix) and prefix != "" and
               String.starts_with?(String.downcase(value), String.downcase(prefix) <> "/") do
            model =
              binary_part(value, byte_size(prefix) + 1, byte_size(value) - byte_size(prefix) - 1)

            if model != "", do: {provider, model}
          end
        end)
      end)

    piped =
      case Providers.parse_option(value) do
        {id, model} -> Enum.find_value(providers, &(&1.id == id && {&1, model}))
        nil -> nil
      end

    case prefixed || piped do
      {provider, model} ->
        {:ok, provider, model}

      nil ->
        case Enum.filter(providers, &lists?.(&1, value)) do
          [] -> :error
          candidates -> {:ok, preferred(conversation, candidates), value}
        end
    end
  end

  defp preferred(conversation, candidates) do
    settings = Settings.get_cached()

    Enum.find(candidates, &(&1.id == conversation.chat_provider_id)) ||
      Enum.find(candidates, &(&1.id == settings.default_chat_provider_id)) ||
      hd(candidates)
  end

  defp put_override(provider_id, model, source),
    do:
      Application.put_env(:swarm_code_daemon, @override_key, %{
        provider_id: provider_id,
        model: model,
        source: source
      })

  ## First run

  defp first_run(session, project, env, otherwise) do
    if Enum.any?(@first_run_keys, &(blank_to_nil(env[&1]) != nil)) do
      env = standard_endpoint(env)

      with {:ok, config} <- Configuration.from_env(env, project.root_path),
           :ok <- explicit_endpoint(env),
           {:ok, provider, notice} <- onboard(config) do
        put_override(provider.id, config[:model], :first_run_env)
        if notice, do: Application.put_env(:swarm_code_daemon, @notice_key, notice)
        {:ok, Map.put(session, :notice, notice)}
      end
    else
      otherwise
    end
  end

  # cli020 B13 (onboarding-4): a provider's own key names its endpoint. With
  # no base URL given, a bare ANTHROPIC_API_KEY means Anthropic at
  # api.anthropic.com and a bare OPENAI_API_KEY OpenAI at api.openai.com/v1;
  # a generic NCODE_API_KEY/SWARM_API_KEY names none (`:endpoint_required`).
  defp standard_endpoint(env) do
    given? = fn name -> blank_to_nil(env[name]) != nil end
    provider = blank_to_nil(env["SWARM_PROVIDER"])

    cond do
      given?.("SWARM_BASE_URL") or given?.("OPENAI_BASE_URL") or given?.("ANTHROPIC_BASE_URL") ->
        env

      given?.("SWARM_API_KEY") ->
        env

      provider in [nil, "anthropic"] and given?.("ANTHROPIC_API_KEY") and
          (provider == "anthropic" or not given?.("OPENAI_API_KEY")) ->
        env
        |> Map.put("SWARM_PROVIDER", "anthropic")
        |> Map.put("SWARM_BASE_URL", "https://api.anthropic.com")

      provider in [nil, "openai"] and given?.("OPENAI_API_KEY") ->
        Map.put(env, "SWARM_BASE_URL", "https://api.openai.com/v1")

      true ->
        env
    end
  end

  defp explicit_endpoint(env) do
    key =
      if env["SWARM_PROVIDER"] == "anthropic", do: "ANTHROPIC_BASE_URL", else: "OPENAI_BASE_URL"

    case Map.get(env, "SWARM_BASE_URL", Map.get(env, key)) do
      value when is_binary(value) and byte_size(value) > 0 -> :ok
      _ -> {:error, :endpoint_required}
    end
  end

  # One row at most: reuse a row for the same endpoint (giving it the key only
  # when it has none), else create one.
  defp onboard(config) do
    endpoint = config[:provider]
    kind = if endpoint.kind == "anthropic", do: "anthropic", else: "openai_compatible"
    key = endpoint.api_key || ""

    case Enum.find(Providers.list(), &(&1.kind == kind and &1.base_url == endpoint.base_url)) do
      nil ->
        # cli020 B13 (onboarding-21): a preset's endpoint gets the preset's name.
        name =
          available_name(
            preset_name(endpoint.base_url) || URI.parse(endpoint.base_url).host || "provider"
          )

        with {:ok, provider} <-
               Providers.create(%{
                 name: name,
                 kind: kind,
                 base_url: endpoint.base_url,
                 api_key: key,
                 models: [config[:model]],
                 default_model: config[:model]
               }) do
          {:ok, provider,
           "First run: added the provider #{name} from your NCODE_*/SWARM_* settings; change it in ncode Settings."}
        end

      provider ->
        if String.trim(provider.api_key || "") == "" and key != "" do
          with {:ok, provider} <- Providers.update(provider, %{api_key: key}) do
            {:ok, provider,
             "First run: gave the provider #{provider.name} the key from your SWARM_* settings."}
          end
        else
          {:ok, provider, nil}
        end
    end
    |> case do
      {:ok, provider, nil} -> {:ok, provider, nil}
      {:ok, _provider, _notice} = ok -> ok
      _ -> {:error, :provider_configuration_failed}
    end
  end

  defp preset_name(base_url) do
    normalize = fn url ->
      url |> String.trim() |> String.trim_trailing("/") |> String.downcase()
    end

    wanted = normalize.(base_url || "")

    Enum.find_value(SwarmCode.Settings.Registry.Actions.provider_presets(), fn preset ->
      if is_binary(preset[:base_url]) and normalize.(preset.base_url) == wanted, do: preset.name
    end)
  rescue
    _ -> nil
  end

  defp available_name(base) do
    taken = MapSet.new(Providers.list(), & &1.name)

    Enum.find(
      [base | Enum.map(2..20, &"#{base} (#{&1})")],
      "#{base} #{System.unique_integer([:positive])}",
      &(not MapSet.member?(taken, &1))
    )
  end

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(_), do: nil
end
