defmodule SwarmCode.Domain.PubSub do
  @moduledoc "Local monitored topic registry for the standalone domain runtime."
  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :supervisor}

  def start_link(_opts), do: Registry.start_link(keys: :duplicate, name: __MODULE__)

  def subscribe(__MODULE__, topic) when is_binary(topic) do
    Registry.unregister(__MODULE__, topic)
    {:ok, _} = Registry.register(__MODULE__, topic, nil)
    :ok
  end

  def unsubscribe(__MODULE__, topic) when is_binary(topic) do
    Registry.unregister(__MODULE__, topic)
    :ok
  end

  def broadcast(__MODULE__, topic, event) when is_binary(topic) do
    Registry.dispatch(__MODULE__, topic, fn entries ->
      for {pid, _} <- entries, do: send(pid, event)
    end)

    :ok
  end
end
