defmodule SwarmCode.Daemon.Service.RequestRouter do
  @moduledoc false
  alias SwarmCode.Protocol.ServiceRequest

  def call(backend, connection, id, scope, %ServiceRequest{operation: :watch} = request),
    do:
      GenServer.call(
        backend,
        {:service_watch, connection, id, scope, request},
        request.timeout_ms
      )

  def call(backend, _connection, id, scope, request),
    do: GenServer.call(backend, {:service_request, id, scope, request}, request.timeout_ms)
end
