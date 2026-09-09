defmodule SwarmCode.Domain.LLM.ProviderCaps do
  @moduledoc """
  What an OpenAI-compatible provider turned out not to support.

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
