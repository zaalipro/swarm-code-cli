defmodule SwarmCode.Domain.Engine.Telemetry do
  @moduledoc """
  Structured `:telemetry` spans for the engine process tree.

  Emits span start/stop/exception events for runs, agents, and operations,
  and sets Logger metadata so a single run's lifecycle can be followed
  in the log by filtering on `sc_run_id`.
  """

  # spec 70 E2

  require Logger

  @prefix [:swarm_code_daemon, :engine]

  @doc "Event name prefix for run spans."
  def run_span, do: @prefix ++ [:run]

  @doc "Event name prefix for agent spans."
  def agent_span, do: @prefix ++ [:agent]

  @doc "Event name prefix for operation spans."
  def op_span, do: @prefix ++ [:op]

  @doc "Attach Logger metadata for the run's process tree."
  def put_run_metadata(run_id),
    do: Logger.metadata(sc_run_id: run_id)

  @doc "Attach Logger metadata for an agent within the run."
  def put_agent_metadata(run_id, agent_id),
    do: Logger.metadata(sc_run_id: run_id, sc_agent_id: agent_id)

  @doc "Attach Logger metadata for an operation within an agent."
  def put_op_metadata(run_id, agent_id, op_id),
    do: Logger.metadata(sc_run_id: run_id, sc_agent_id: agent_id, sc_op_id: op_id)

  @doc "Emit a span start event. Returns the start monotonic time."
  def span_start(name, meta) do
    start = System.monotonic_time()
    :telemetry.execute(name ++ [:start], %{system_time: System.system_time()}, meta)
    start
  end

  @doc "Emit a span stop event with duration."
  def span_stop(name, start, meta) do
    duration = System.monotonic_time() - start
    :telemetry.execute(name ++ [:stop], %{duration: duration}, meta)
  end

  @doc "Emit a span exception event."
  def span_exception(name, start, kind, reason, meta) do
    duration = System.monotonic_time() - start

    :telemetry.execute(
      name ++ [:exception],
      %{duration: duration},
      Map.merge(meta, %{kind: kind, reason: reason})
    )
  end
end
