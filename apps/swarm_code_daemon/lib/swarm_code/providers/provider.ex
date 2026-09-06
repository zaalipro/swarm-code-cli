defmodule SwarmCode.Providers.Provider do
  @moduledoc "Validated daemon-owned configuration for a credentialed LLM endpoint."
  @derive {Inspect, except: [:api_key, :effort_levels, :model_effort_levels]}
  defstruct [
    :id,
    :name,
    :default_model,
    :effort_levels,
    kind: "openai",
    base_url: nil,
    api_key: "",
    models: [],
    model_effort_levels: %{},
    fallbacks: true
  ]

  @type t :: %__MODULE__{}
  @fields ~w(id name kind base_url api_key models default_model effort_levels model_effort_levels fallbacks)a

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs),
      do: new(Map.new(attrs)),
      else: {:error, "provider must be a map or keyword list"}
  end

  def new(attrs) when is_map(attrs) do
    values =
      Map.new(@fields, fn field ->
        {field,
         Map.get(
           attrs,
           field,
           Map.get(attrs, Atom.to_string(field), Map.get(%__MODULE__{}, field))
         )}
      end)

    provider = struct!(__MODULE__, values)

    provider = %{
      provider
      | id: provider.id || Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    }

    with :ok <- required_string(provider.name, "name"),
         :ok <- required_string(provider.id, "id"),
         :ok <- valid_kind(provider.kind),
         {:ok, url} <- valid_url(provider.base_url),
         :ok <- strings(provider),
         {:ok, levels} <- valid_levels(provider.effort_levels),
         {:ok, model_levels} <- valid_model_levels(provider.model_effort_levels) do
      {:ok, %{provider | base_url: url, effort_levels: levels, model_effort_levels: model_levels}}
    end
  end

  def new(_), do: {:error, "provider must be a map or keyword list"}

  defp required_string(value, _field) when is_binary(value) and byte_size(value) > 0 do
    if String.trim(value) != "", do: :ok, else: {:error, "provider field must not be blank"}
  end

  defp required_string(_, field), do: {:error, "provider #{field} must be a nonempty string"}
  defp valid_kind(kind) when kind in ["openai", "anthropic"], do: :ok
  defp valid_kind(_), do: {:error, "provider kind must be openai or anthropic"}

  defp valid_url(value) when is_binary(value) do
    url = value |> String.trim() |> String.trim_trailing("/")
    uri = URI.parse(url)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
         is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) and
         not String.contains?(url, ["\n", "\r", " "]) do
      {:ok, url}
    else
      {:error, "base_url must be an HTTP(S) endpoint without credentials, query or fragment"}
    end
  rescue
    _ -> {:error, "invalid base_url"}
  end

  defp valid_url(_), do: {:error, "base_url must be an HTTP(S) endpoint"}

  defp strings(p) do
    cond do
      not is_binary(p.api_key) or String.contains?(p.api_key, ["\r", "\n"]) ->
        {:error, "api_key must be a string without newlines"}

      not (is_nil(p.default_model) or
               (is_binary(p.default_model) and String.trim(p.default_model) != "")) ->
        {:error, "default_model must be a nonempty string"}

      not (is_list(p.models) and Enum.all?(p.models, &(is_binary(&1) and String.trim(&1) != ""))) ->
        {:error, "models must be a list of nonempty strings"}

      not is_boolean(p.fallbacks) ->
        {:error, "fallbacks must be a boolean"}

      true ->
        :ok
    end
  end

  defp valid_levels(nil), do: {:ok, nil}

  defp valid_levels(levels) when is_list(levels) do
    case SwarmCode.LLM.Efforts.validate(levels) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, _} -> {:error, "invalid effort levels"}
    end
  rescue
    _ in [ArgumentError, Protocol.UndefinedError] -> {:error, "invalid effort levels"}
  end

  defp valid_levels(_), do: {:error, "effort levels must be a list"}

  defp valid_model_levels(levels) when is_map(levels) do
    Enum.reduce_while(levels, {:ok, %{}}, fn {model, levels}, {:ok, acc} ->
      with true <- is_binary(model) and is_list(levels),
           {:ok, normalized} <- valid_levels(levels) do
        {:cont, {:ok, Map.put(acc, model, normalized)}}
      else
        _ -> {:halt, {:error, "invalid model effort levels"}}
      end
    end)
  end

  defp valid_model_levels(_), do: {:error, "model_effort_levels must be a map"}

  def models_text(provider), do: Enum.join(provider.models || [], "\n")

  def parse_models(text) when is_binary(text) do
    text
    |> String.split([",", "\n", "\r"])
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def parse_models(_), do: []
end
