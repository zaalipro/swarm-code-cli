defmodule SwarmCodeCLI.Demo.Plain do
  @moduledoc "Renderer-free, process-local fake demo with a fixed finite driver and monitored cleanup."
  alias SwarmCodeCLI.Demo.{ApplicationFence, FiniteInput, FiniteScript}
  alias SwarmCodeCLI.Plain.{Options, Session}
  alias SwarmCodeCLI.UI.DataSource.Fake
  alias SwarmCodeCLI.UI.DataSource.Fake.{Script, Source}
  @external_resource Path.expand("../../../test/fixtures/fake/three_run_script.json", __DIR__)
  @fixture File.read!(@external_resource)
  @audit_key {__MODULE__, :audit}
  @epoch "plain-demo-epoch"

  def last_audit,
    do: Process.get(@audit_key, %{children_started: 0, children_after: 0, invariants: []})

  def run(:complete, options) when is_list(options) do
    if Keyword.keyword?(options) and
         Enum.sort(Keyword.keys(options)) == [:error, :output, :timeout] and
         is_integer(options[:timeout]) and options[:timeout] > 0 do
      execute(options)
    else
      {:error, :script_failed}
    end
  end

  def run(_, _), do: {:error, :script_failed}

  defp execute(options) do
    deadline = System.monotonic_time(:millisecond) + options[:timeout]
    {:ok, supervisor} = Supervisor.start_link([], strategy: :one_for_all, max_restarts: 0)
    root_monitor = Process.monitor(supervisor)
    correlation = make_ref()
    Process.put(@audit_key, %{children_started: 0, children_after: 0, invariants: []})

    try do
      ApplicationFence.track_tree(supervisor)
      Process.unlink(supervisor)
      {:ok, script} = Script.decode(@fixture)
      source = child!(supervisor, Source, script: script, source_epoch: @epoch)

      client =
        child!(supervisor, Fake,
          source: source,
          source_epoch: @epoch,
          client_id: "plain-demo-client"
        )

      input = child!(supervisor, FiniteInput, max_lines: 32, max_bytes: 16_385)

      session =
        child!(supervisor, Session,
          options: %Options{},
          data_source: client,
          input: input,
          output: options[:output],
          error: options[:error],
          source_epoch: @epoch,
          conversation_id: Script.id(:a),
          now: Script.clock_ms(),
          observer: self()
        )

      Process.put({__MODULE__, :session}, session)

      driver =
        child!(supervisor, FiniteScript,
          source: source,
          input: input,
          coordinator: self(),
          correlation: correlation
        )

      monitors = Map.new([source, client, input, session, driver], &{Process.monitor(&1), &1})
      ApplicationFence.track_tree(supervisor)
      result = coordinate(session, driver, correlation, monitors, root_monitor, deadline)
      Enum.each(monitors, fn {monitor, _} -> Process.demonitor(monitor, [:flush]) end)
      result
    rescue
      _ -> {:error, :session_failed}
    catch
      _, _ -> {:error, :session_failed}
    after
      cleanup(supervisor, root_monitor)
      flush_session_events(Process.delete({__MODULE__, :session}), correlation)
    end
  end

  defp child!(supervisor, module, options) do
    spec = Supervisor.child_spec({module, options}, restart: :temporary, shutdown: 2_000)
    {:ok, pid} = Supervisor.start_child(supervisor, spec)
    Process.put(@audit_key, Map.update!(last_audit(), :children_started, &(&1 + 1)))
    pid
  end

  defp coordinate(session, driver, correlation, monitors, root_monitor, deadline) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    if remaining == 0 do
      {:error, :timeout}
    else
      receive do
        {:plain_session, ^session, {:closed, reason} = event} when reason != :detach ->
          FiniteScript.event(driver, event)
          {:error, :session_failed}

        {:plain_session, ^session, event} ->
          FiniteScript.event(driver, event)
          coordinate(session, driver, correlation, monitors, root_monitor, deadline)

        {:finite_script, ^correlation, ^driver, {:complete, invariants}} ->
          Process.put(@audit_key, %{last_audit() | invariants: invariants})
          :ok

        {:finite_script, ^correlation, ^driver, :failed} ->
          {:error, :script_failed}

        {:DOWN, ^root_monitor, :process, _, _} ->
          {:error, :session_failed}

        {:DOWN, monitor, :process, _, _} when is_map_key(monitors, monitor) ->
          {:error, :session_failed}
      after
        remaining -> {:error, :timeout}
      end
    end
  end

  defp cleanup(supervisor, root_monitor) do
    members =
      if Process.alive?(supervisor),
        do:
          Supervisor.which_children(supervisor)
          |> Enum.map(&elem(&1, 1))
          |> Enum.filter(&is_pid/1),
        else: []

    monitors = Enum.map(members, &{&1, Process.monitor(&1)})
    if Process.alive?(supervisor), do: Supervisor.stop(supervisor, :normal, 5_000)

    for {pid, monitor} <- [{supervisor, root_monitor} | monitors] do
      receive do
        {:DOWN, ^monitor, :process, ^pid, _} -> :ok
      after
        2_000 ->
          if Process.alive?(pid), do: raise("demo child did not terminate")
          Process.demonitor(monitor, [:flush])
      end
    end

    alive = Enum.count([supervisor | members], &Process.alive?/1)
    Process.put(@audit_key, %{last_audit() | children_after: alive})
  end

  defp flush_session_events(session, correlation) do
    receive do
      {:plain_session, ^session, _} -> flush_session_events(session, correlation)
      {:finite_script, ^correlation, _, _} -> flush_session_events(session, correlation)
    after
      0 -> :ok
    end
  end
end
