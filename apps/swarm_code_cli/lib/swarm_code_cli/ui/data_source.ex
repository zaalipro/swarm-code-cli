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
end
