defmodule SwarmCode.Domain.Workflows.Runner.Watchdog do
  @moduledoc """
  Brings runs that parked themselves on an unreachable provider back to life
  (spec 11 §7.4).

  One process for the whole app: every 30 s it looks for workflow runs paused
  with `pause_kind: "infrastructure"`, sends a one-token probe to the provider
  that run would use and resumes the run as soon as the probe comes back. A
  toast says so. With no such run it does nothing at all, and because it reads
  the state from the database it also picks up runs that were parked before the
  app restarted.
  """
  use GenServer
  require Logger

  alias SwarmCode.Domain.Engine.Events
  alias SwarmCode.Domain.LLM
  alias SwarmCode.Domain.LLM.{Gate, Request}
  alias SwarmCode.Domain.Workflows
  alias SwarmCode.Domain.{Conversations, Settings}

  @interval 30_000
  # pass76 llm-watchdog: runs parked on one model come back one by one, so
  # they do not all hit the limit that parked them in the same second.
  @stagger 5_000
  @probe_timeout 60_000
  @cooldown_slack 120_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Runs one round now (tests and the resume button), without staggering."
  @spec check() :: [String.t()]
  def check, do: resume_reachable()

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    interval = opts[:interval] || @interval

    {:ok,
     %{
       interval: interval,
       stagger: Keyword.get(opts, :stagger, @stagger),
       probe_timeout: opts[:probe_timeout] || @probe_timeout,
       sup: opts[:supervisor] || SwarmCode.Domain.TaskSupervisor,
       funs: funs(opts),
       jobs: %{},
       timer: schedule(interval)
     }}
  end

  @impl true
  def handle_info(:tick, state) do
    state = %{state | timer: schedule(state.interval)}

    # A round still in flight (a long staggered resume) owns the parked runs.
    if map_size(state.jobs) == 0 do
      funs = state.funs
      {:noreply, start_job(state, :list, state.probe_timeout, fn -> funs.list.() end)}
    else
      {:noreply, state}
    end
  end

  def handle_info({ref, result}, %{jobs: jobs} = state) when is_map_key(jobs, ref) do
    Process.demonitor(ref, [:flush])
    {job, state} = pop_job(state, ref)
    {:noreply, handle_result(job.kind, result, state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{jobs: jobs} = state)
      when is_map_key(jobs, ref) do
    {job, state} = pop_job(state, ref)
    Logger.warning("workflow watchdog #{kind_name(job.kind)} stopped: #{inspect(reason)}")
    {:noreply, state}
  end

  def handle_info({:job_timeout, ref}, %{jobs: jobs} = state) when is_map_key(jobs, ref) do
    Process.demonitor(ref, [:flush])
    {job, state} = pop_job(state, ref)
    Task.Supervisor.terminate_child(state.sup, job.pid)
    Logger.warning("workflow watchdog #{kind_name(job.kind)} timed out")
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    for {_ref, job} <- state.jobs, do: Task.Supervisor.terminate_child(state.sup, job.pid)
    :ok
  end

  defp schedule(interval), do: Process.send_after(self(), :tick, interval)

  defp kind_name(:list), do: "listing"
  defp kind_name({:probe, _}), do: "probe"
  defp kind_name({:resume, _}), do: "resume"

  defp start_job(state, kind, timeout, fun) do
    # pass76 fix-m3-watchdog (M3-R1-010): linked, so an untrappable kill of the
    # watchdog takes every job with it. The watchdog traps exits and a job's
    # own crash still arrives as :DOWN.
    task = Task.Supervisor.async(state.sup, fun)
    timer = Process.send_after(self(), {:job_timeout, task.ref}, timeout)
    put_in(state.jobs[task.ref], %{kind: kind, pid: task.pid, timer: timer})
  end

  defp pop_job(state, ref) do
    {job, jobs} = Map.pop(state.jobs, ref)
    Process.cancel_timer(job.timer)
    {job, %{state | jobs: jobs}}
  end

  defp handle_result(:list, groups, state) when is_list(groups) do
    Enum.reduce(groups, state, fn group, state ->
      funs = state.funs
      start_job(state, {:probe, group}, state.probe_timeout, fn -> run_probe(funs, group) end)
    end)
  end

  defp handle_result({:probe, group}, :ok, state) do
    funs = state.funs
    stagger = state.stagger
    timeout = state.probe_timeout + length(group.wfs) * (stagger + @cooldown_slack)
    start_job(state, {:resume, group}, timeout, fn -> resume_group(funs, group, stagger) end)
  end

  defp handle_result({:probe, _group}, {:error, message}, state) do
    Logger.debug("workflow watchdog probe failed: #{inspect(message)}")
    state
  end

  defp handle_result(_kind, _result, state), do: state

  defp funs(opts) do
    %{
      list: opts[:list_fun] || (&list_groups/0),
      probe: opts[:probe_fun] || (&probe/1),
      resume: opts[:resume_fun] || (&resume/1),
      sleep: opts[:sleep_fun] || (&Process.sleep/1)
    }
  end

  # A probe may raise, throw or exit (a dead gate, a transport process dying);
  # none of those may take the caller down.
  defp run_probe(funs, group) do
    funs.probe.(group.model)
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
  end

  defp list_groups do
    Workflows.list_parked_infrastructure()
    |> Enum.map(fn %{wf: wf, conversation: conversation} -> {wf, model_for(wf, conversation)} end)
    |> Enum.group_by(fn {_wf, model} -> model_key(model) end)
    |> Enum.map(fn {key, [{_wf, model} | _] = group} ->
      %{key: key, model: model, wfs: Enum.map(group, &elem(&1, 0))}
    end)
  end

  # The first run goes at once; every further run of the group waits `stagger`
  # ms (and the provider's rate-limit cooldown, when the gate has one).
  defp resume_group(funs, group, stagger) do
    gate_key = group.model && LLM.gate_key(group.model.provider)

    group.wfs
    |> Enum.with_index()
    |> Enum.flat_map(fn {wf, index} ->
      if index > 0 and stagger > 0, do: funs.sleep.(stagger)
      wait_cooldown(gate_key, funs.sleep)

      if funs.resume.(wf) == :ok do
        Events.ui_broadcast({:toast, "Workflow #{wf.display_name} resumed"})
        [wf.run_id]
      else
        []
      end
    end)
  end

  defp wait_cooldown(nil, _sleep), do: :ok

  defp wait_cooldown(key, sleep) do
    case Gate.cooldown_until(key) do
      nil ->
        :ok

      until ->
        remaining = until - System.monotonic_time(:millisecond)

        if remaining > 0 do
          sleep.(remaining)
          wait_cooldown(key, sleep)
        else
          :ok
        end
    end
  end

  @doc """
  Probes and resumes every infrastructure-paused run now, all at once, in the
  caller; returns the resumed ids. The periodic round does the same work in
  owned tasks and staggers the resumes. Spec 51 §5.9 (f): the parked rows come
  from one query and every run on the same model shares one probe.
  """
  @spec resume_reachable() :: [String.t()]
  def resume_reachable do
    funs = funs([])

    list_groups()
    |> Enum.flat_map(fn group ->
      if run_probe(funs, group) == :ok, do: resume_group(funs, group, 0), else: []
    end)
  rescue
    _error ->
      Logger.warning("workflow watchdog check failed")
      []
  end

  defp model_for(wf, conversation) do
    conversation = conversation || (wf.conversation_id && Conversations.get(wf.conversation_id))
    Workflows.resolve_model([], Settings.get(), conversation)
  end

  defp model_key(nil), do: nil
  defp model_key(%{provider: provider, model: model}), do: {provider.id, model}

  # pass76 fix-m3-watchdog (M3-R1-009): the claim is a conditional update, so a
  # run the user stopped while the resume waited is no longer eligible.
  defp resume(wf), do: Workflows.resume_parked_infrastructure(wf.run_id)

  # One token, one attempt: a probe must fail fast, not sit in the transport
  # backoff. An answer that is not transport-shaped (a 400 about `max_tokens`,
  # say) still proves the provider is reachable.
  defp probe(model) do
    case model do
      nil ->
        {:error, "no model configured"}

      model ->
        request = %Request{
          provider: model.provider,
          model: model.model,
          system: "",
          messages: [%{role: "user", content: "ping"}],
          tools: [],
          max_tokens: 1,
          effort: nil
        }

        case LLM.stream_once(request, nil) do
          {:ok, _result} -> :ok
          {:error, message} -> if unreachable?(message), do: {:error, message}, else: :ok
        end
    end
  end

  defp unreachable?(message), do: SwarmCode.Domain.Workflows.Runner.infrastructure?(message)
end
