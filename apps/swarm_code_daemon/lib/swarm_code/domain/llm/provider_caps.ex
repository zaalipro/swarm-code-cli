defmodule SwarmCode.Domain.LLM.ProviderCaps do
  @moduledoc """
  What a provider turned out not to support: `reasoning_effort` on an
  OpenAI-compatible server, the prefix-cache field (`prompt_cache_key`, or the
  `cache_control` markers of a gateway in front of the Messages API) and the
  `fallbacks` beta.

  Sakana task 14: the capability table used to be created lazily by whichever
  LLM operation task discovered a rejection. That task is transient, so the
  table died with it and the very next operation paid for another rejected
  request; two concurrent first accesses could also race on table creation.
  A supervised owner keeps the table for the application's lifetime.
  """
  use GenServer

  @table __MODULE__

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @doc "False once this provider has 400'd on `reasoning_effort` in this session."
  @spec effort?(term()) :: boolean()
  def effort?(provider), do: :ets.lookup(@table, {:no_effort, key(provider)}) == []

  @doc "Remembers that `provider` rejects `reasoning_effort`."
  @spec remember_no_effort(term()) :: :ok
  def remember_no_effort(provider) do
    :ets.insert(@table, {{:no_effort, key(provider)}, true})
    :ok
  end

  @doc """
  False once this provider has 400'd on the prefix-cache field in this session:
  `prompt_cache_key` (OpenAI-compatible) or the `cache_control` markers
  (Anthropic gateways).

  spec 67 B37: the flag used to be `Process.put/2` in the op task that made the
  call, so it died with the call and every later turn paid the 400 and the
  retry again. One provider row is one kind, so the two meanings share a key.
  """
  @spec cache_key?(term()) :: boolean()
  def cache_key?(provider), do: :ets.lookup(@table, {:no_cache_key, key(provider)}) == []

  @doc "Remembers that `provider` rejects the prefix-cache field."
  @spec remember_no_cache_key(term()) :: :ok
  def remember_no_cache_key(provider) do
    :ets.insert(@table, {{:no_cache_key, key(provider)}, true})
    :ok
  end

  @doc "False once this provider has 400'd on the `fallbacks` beta (spec 53b §3) in this session."
  @spec fallbacks?(term()) :: boolean()
  def fallbacks?(provider), do: :ets.lookup(@table, {:no_fallbacks, key(provider)}) == []

  @doc "Remembers that `provider` rejects `fallbacks`."
  @spec remember_no_fallbacks(term()) :: :ok
  def remember_no_fallbacks(provider) do
    :ets.insert(@table, {{:no_fallbacks, key(provider)}, true})
    :ok
  end

  @doc """
  Forgets what was remembered about one provider (spec 73 T82): the row was
  edited or deleted — a `base_url` pointed at the real endpoint again must
  get its effort level, cache markers and fallbacks back without a restart.
  """
  @spec forget(term()) :: :ok
  def forget(provider) do
    :ets.match_delete(@table, {{:_, key(provider)}, :_})
    :ok
  end

  @doc "Forgets every remembered capability (tests)."
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc "The cache key of a provider."
  @spec key(term()) :: String.t()
  def key(%{id: id}) when is_binary(id), do: id
  def key(%{name: name}) when is_binary(name), do: name
  def key(other), do: inspect(other)
end
