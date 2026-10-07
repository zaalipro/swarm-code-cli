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

  # ------------------------------------------ per model (pass74 BUGS-51/52)

  # pass74 (spec 74) BUGS-51: one model's 400 used to turn effort off for every
  # model and every level of the provider until restart. Only an
  # "unknown parameter" rejection is about the server (`remember_no_effort/1`);
  # anything else is about one model, or one level of one model.

  @doc "False once `model` on this provider has 400'd on its effort keys (not as unknown)."
  @spec model_effort?(term(), String.t() | nil) :: boolean()
  def model_effort?(provider, model),
    do: :ets.lookup(@table, {:no_effort, key(provider), model}) == []

  @doc "Remembers that `model` on this provider rejects the effort keys."
  @spec remember_no_model_effort(term(), String.t() | nil) :: :ok
  def remember_no_model_effort(provider, model) do
    :ets.insert(@table, {{:no_effort, key(provider), model}, true})
    :ok
  end

  @doc "True once `model` on this provider has refused the value of level `level_key`."
  @spec level_rejected?(term(), String.t() | nil, String.t() | nil) :: boolean()
  def level_rejected?(provider, model, level_key),
    do: :ets.lookup(@table, {:no_level, key(provider), model, level_key}) != []

  @doc "Remembers that `model` refuses level `level_key` (it falls back to its default level)."
  @spec remember_rejected_level(term(), String.t() | nil, String.t() | nil) :: :ok
  def remember_rejected_level(provider, model, level_key) do
    :ets.insert(@table, {{:no_level, key(provider), model, level_key}, true})
    :ok
  end

  @doc """
  pass74 (spec 74) EFFICIENCY-41: false once `model` on this provider (an
  Anthropic gateway) 400'd on `thinking` with no continuation state in the
  request. Model-scoped: another model on the same provider keeps its level.
  """
  @spec thinking?(term(), String.t() | nil) :: boolean()
  def thinking?(provider, model),
    do: :ets.lookup(@table, {:no_thinking, key(provider), model}) == []

  @doc "Remembers that `model` rejects the `thinking` parameter."
  @spec remember_no_thinking(term(), String.t() | nil) :: :ok
  def remember_no_thinking(provider, model) do
    :ets.insert(@table, {{:no_thinking, key(provider), model}, true})
    :ok
  end

  @doc """
  pass74 (spec 74) BUGS-52: true once `model` answered "use
  `max_completion_tokens`" (OpenAI o-series, gpt-5.x): the key is renamed on
  every later request to it.
  """
  @spec max_completion_tokens?(term(), String.t() | nil) :: boolean()
  def max_completion_tokens?(provider, model),
    do: :ets.lookup(@table, {:max_completion_tokens, key(provider), model}) != []

  @doc "Remembers that `model` takes `max_completion_tokens` instead of `max_tokens`."
  @spec remember_max_completion_tokens(term(), String.t() | nil) :: :ok
  def remember_max_completion_tokens(provider, model) do
    :ets.insert(@table, {{:max_completion_tokens, key(provider), model}, true})
    :ok
  end

  @doc "pass74 (spec 74) BUGS-52: false once `model` refused a non-default `temperature`."
  @spec temperature?(term(), String.t() | nil) :: boolean()
  def temperature?(provider, model),
    do: :ets.lookup(@table, {:no_temperature, key(provider), model}) == []

  @doc "Remembers that `model` only takes its default `temperature`."
  @spec remember_no_temperature(term(), String.t() | nil) :: :ok
  def remember_no_temperature(provider, model) do
    :ets.insert(@table, {{:no_temperature, key(provider), model}, true})
    :ok
  end

  @doc """
  pass74 (spec 74) BUGS-77: false once `model` 400'd on the continuation state
  echoed back to it (`reasoning_content`, `extra_content`).
  """
  @spec continuation?(term(), String.t() | nil) :: boolean()
  def continuation?(provider, model),
    do: :ets.lookup(@table, {:no_continuation, key(provider), model}) == []

  @doc "Remembers that `model` refuses the echoed continuation state."
  @spec remember_no_continuation(term(), String.t() | nil) :: :ok
  def remember_no_continuation(provider, model) do
    :ets.insert(@table, {{:no_continuation, key(provider), model}, true})
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
    id = key(provider)
    :ets.match_delete(@table, {{:_, id}, :_})
    # pass74 (spec 74) BUGS-51/52: the per-model and per-level entries.
    :ets.match_delete(@table, {{:_, id, :_}, :_})
    :ets.match_delete(@table, {{:_, id, :_, :_}, :_})
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
