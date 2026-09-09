defmodule SwarmCodeCLI.UI.DataSource do
  @moduledoc """
  Client-owned typed boundary between UI state and a fake or daemon source.

  Implementations start unbound and must fail admission closed until one
  reference-correlated owner bind succeeds.
  """

  alias SwarmCodeCLI.UI.DataSource.{AdmissionError, Request, Watch}

  @type server :: GenServer.server()
  @type owner_handle :: GenServer.server()
  @type binding_ref :: binary()
  @type watch_ref :: binary()
  @type request_id :: binary()

  @callback start_link(options :: keyword()) :: GenServer.on_start()

  @callback bind_owner(server(), owner_handle(), binding_ref()) ::
              {:ok, binding_ref()} | {:error, :already_bound | :closed | :binding_failed}

  @callback watch(server(), Watch.t()) :: :ok | {:error, AdmissionError.t()}
  @callback unwatch(server(), watch_ref()) :: :ok
  @callback query(server(), Request.t()) :: :ok | {:error, AdmissionError.t()}
  @callback command(server(), Request.t()) :: :ok | {:error, AdmissionError.t()}
  @callback cancel(server(), request_id()) :: :ok | {:error, AdmissionError.t()}
  @callback close(server()) :: :ok
  @callback consume(server(), reference(), :applied | :discarded) ::
              :ok | {:error, AdmissionError.t()}

  @doc "Bind the UI owner through the common adapter process protocol."
  def bind_owner(server, owner, ref), do: GenServer.call(server, {:bind, owner, ref}, :infinity)
  def watch(server, watch), do: GenServer.call(server, {:watch, watch}, :infinity)
  def unwatch(server, ref), do: GenServer.call(server, {:unwatch, ref})
  def query(server, request), do: GenServer.call(server, {:request, :query, request}, :infinity)

  def command(server, request),
    do: GenServer.call(server, {:request, :command, request}, :infinity)

  def cancel(server, id), do: GenServer.call(server, {:cancel, id})
  def close(server), do: GenServer.call(server, :close)

  def consume(server, receipt, disposition),
    do: GenServer.call(server, {:consume, receipt, disposition})
end
