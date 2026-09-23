defmodule SwarmCode.Domain.Search.Provider do
  @moduledoc """
  What a search engine or a page reader has to do (spec 24 §4.1).

  A provider is a stateless module: `cfg` is the `search_providers` row (or a
  synthetic map), so nothing is cached between calls.
  """

  @type result :: %{
          title: String.t(),
          url: String.t(),
          content: String.t(),
          score: float() | nil,
          published: String.t() | nil
        }

  @type opts :: [
          max_results: pos_integer(),
          recency_days: pos_integer() | nil,
          include_domains: [String.t()],
          exclude_domains: [String.t()],
          timeout: pos_integer()
        ]

  @callback search(cfg :: map(), query :: String.t(), opts :: opts()) ::
              {:ok, [result()]} | {:error, String.t()}

  @callback read(cfg :: map(), url :: String.t(), opts :: opts()) ::
              {:ok, String.t()} | {:error, String.t()}

  @optional_callbacks search: 3, read: 3

  @doc "The shared error mapping every provider uses, so failures read the same."
  @spec error(String.t(), term()) :: {:error, String.t()}
  def error(name, %{status: 401}), do: {:error, "#{name} rejected the API key (401)"}
  def error(name, %{status: 403}), do: {:error, "#{name} refused the request (403)"}

  def error(name, %{status: status}) when status in [429, 432, 433],
    do: {:error, "#{name} rate or plan limit (#{status})"}

  def error(name, %{status: status}), do: {:error, "#{name} error (#{status})"}

  def error(name, %{__exception__: true} = exception),
    do: {:error, "#{name} request failed: " <> Exception.message(exception)}

  def error(name, other),
    do: {:error, "#{name} request failed: " <> String.slice(inspect(other), 0, 200)}

  @doc """
  The JSON a bounded response carried (spec 73 T90): the engines collect
  through `Body.collector/0` like the readers, so a proxy or a misbehaving
  endpoint behind a custom `base_url` cannot make an op task buffer and decode
  an arbitrarily large body. `:error` for a refused, truncated or non-JSON body.
  """
  @spec decode_json(Req.Response.t()) :: {:ok, term()} | :error
  def decode_json(response) do
    with {:ok, body} <- SwarmCode.Domain.Search.Body.read(response),
         {:ok, json} <- Jason.decode(body) do
      {:ok, json}
    else
      _other -> :error
    end
  end

  @doc "A result map with every key present, whatever the wire gave us."
  @spec result(map()) :: result()
  def result(fields) do
    %{
      title: string(fields[:title]),
      url: string(fields[:url]),
      content: string(fields[:content]),
      score: number(fields[:score]),
      published: nilable(fields[:published])
    }
  end

  defp string(value) when is_binary(value), do: value
  defp string(nil), do: ""
  defp string(value), do: to_string(value)

  defp nilable(value) when is_binary(value) and value != "", do: value
  defp nilable(_value), do: nil

  defp number(value) when is_number(value), do: value / 1
  defp number(_value), do: nil
end
