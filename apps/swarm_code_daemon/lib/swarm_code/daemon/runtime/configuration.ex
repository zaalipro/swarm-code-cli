defmodule SwarmCode.Daemon.Runtime.Configuration do
  @moduledoc "Builds an ephemeral runtime configuration from environment values."

  alias SwarmCode.Providers.Provider
  alias SwarmCode.Tools.Path, as: ProjectPath

  @doc "Translate launcher environment variables into ephemeral `Run` options."
  @spec from_env(map(), String.t()) :: {:ok, keyword()} | {:error, term()}
  def from_env(env, project_root) when is_map(env) and is_binary(project_root) do
    with {:ok, root} <- valid_project(project_root),
         {:ok, provider_kind} <- provider_kind(value(env, "SWARM_PROVIDER", "openai")),
         {:ok, model} <-
           required_model(
             Map.get(env, "SWARM_MODEL", Map.get(env, base_key(provider_kind, "MODEL")))
           ),
         {:ok, approval} <- approval(value(env, "SWARM_APPROVAL", "ask")),
         {:ok, effort} <- effort(value(env, "SWARM_EFFORT", "medium")),
         {:ok, provider} <- provider(env, provider_kind) do
      {:ok,
       [
         provider: provider,
         model: model,
         project_root: root,
         approval: approval,
         effort: effort
       ]}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_configuration}
    end
  rescue
    _ -> {:error, :invalid_configuration}
  end

  def from_env(_, _), do: {:error, :invalid_configuration}

  defp provider(env, kind) do
    {base_default, key_name} =
      case kind do
        "anthropic" -> {"https://api.anthropic.com", "ANTHROPIC_API_KEY"}
        _ -> {"https://api.openai.com/v1", "OPENAI_API_KEY"}
      end

    base_url =
      cond do
        Map.has_key?(env, "SWARM_BASE_URL") -> Map.get(env, "SWARM_BASE_URL")
        Map.has_key?(env, base_key(kind, "BASE_URL")) -> Map.get(env, base_key(kind, "BASE_URL"))
        true -> base_default
      end

    api_key =
      if Map.has_key?(env, "SWARM_API_KEY"),
        do: Map.get(env, "SWARM_API_KEY"),
        else: value(env, key_name, "")

    if is_binary(api_key) and is_binary(base_url) and
         not Regex.match?(~r/[\x00-\x1f\x7f]/, api_key) and
         not Regex.match?(~r/[\x00-\x20\x7f]/, base_url) do
      Provider.new(kind: kind, name: "environment", base_url: base_url, api_key: api_key)
    else
      {:error, :invalid_provider}
    end
    |> case do
      {:ok, provider} -> {:ok, provider}
      {:error, _} -> {:error, :invalid_provider}
    end
  end

  defp base_key("anthropic", suffix), do: "ANTHROPIC_" <> suffix
  defp base_key(_, suffix), do: "OPENAI_" <> suffix

  defp valid_project(root) do
    with {:ok, real} <- ProjectPath.real_path(root), true <- File.dir?(real) do
      {:ok, real}
    else
      _ -> {:error, :invalid_project}
    end
  end

  defp provider_kind(value) when value in ["openai", "anthropic"], do: {:ok, value}
  defp provider_kind(_), do: {:error, :invalid_provider}

  defp required_model(value) when is_binary(value) and byte_size(value) in 1..1_024 do
    if String.trim(value) != "" and String.valid?(value) and
         not Regex.match?(~r/[\x00-\x1f\x7f]/, value),
       do: {:ok, value},
       else: {:error, :model_required}
  end

  defp required_model(_), do: {:error, :model_required}

  defp approval(value) when value in ["auto", "ask", "read-only"],
    do: {:ok, if(value == "read-only", do: :read_only, else: String.to_atom(value))}

  defp approval(_), do: {:error, :invalid_approval}

  defp effort(value) when is_binary(value) do
    if String.valid?(value) and not String.contains?(value, ["\r", "\n"]) and
         Regex.match?(SwarmCode.LLM.Efforts.key_format(), value),
       do: {:ok, value},
       else: {:error, :invalid_effort}
  end

  defp effort(_), do: {:error, :invalid_effort}

  defp value(env, key, default) do
    case Map.get(env, key, default) do
      value when is_binary(value) -> if value == "", do: default, else: value
      value -> value
    end
  end
end
