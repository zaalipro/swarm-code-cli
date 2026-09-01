defmodule SqliteQueryFake do
  @moduledoc false

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts) do
    owner = Keyword.fetch!(opts, :owner)
    responses = Keyword.fetch!(opts, :responses)
    bind_response = Keyword.get(opts, :bind_response, :ok)

    Agent.start_link(fn ->
      %{owner: owner, responses: responses, bind_response: bind_response}
    end)
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: make_ref(),
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def prepare(agent, _sql) do
    statement = make_ref()
    owner = Agent.get(agent, & &1.owner)
    send(owner, {:prepared, statement})
    {:ok, {agent, statement}}
  end

  def bind({agent, _statement}, _parameters), do: Agent.get(agent, & &1.bind_response)

  def step(_agent, {agent, _statement}) do
    Agent.get_and_update(agent, fn
      %{responses: [response | rest]} = state -> {response, %{state | responses: rest}}
      %{responses: []} = state -> {:done, state}
    end)
  end

  def release(_agent, {agent, statement}) do
    owner = Agent.get(agent, & &1.owner)
    send(owner, {:released, statement})
    :ok
  end
end
