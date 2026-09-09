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
  alias SwarmCode.Domain.LLM.Request
  alias SwarmCode.Domain.Workflows
  alias SwarmCode.Domain.{Conversations, Settings}

  @interval 30_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Runs one round now (tests and the resume button)."
  @spec check() :: [String.t()]
  def check, do: resume_reachable()

  @impl true
  def init(opts) do
    interval = opts[:interval] || @interval
    {:ok, %{interval: interval, timer: schedule(interval)}}
  end

  @impl true
  def handle_info(:tick, state) do
    safe_check()
    {:noreply, %{state | timer: schedule(state.interval)}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp schedule(interval), do: Process.send_after(self(), :tick, interval)

  defp safe_check do
    resume_reachable()
  rescue
    _error ->
      Logger.warning("workflow watchdog check failed")
      []
  end

  @doc """
  Probes and resumes every infrastructure-paused run; returns the resumed ids.
  Spec 51 §5.9 (f): the parked rows come from one query and every run on the
  same model shares one probe.
  """
  @spec resume_reachable() :: [String.t()]
  def resume_reachable do
    Workflows.list_parked_infrastructure()
    |> Enum.map(fn %{wf: wf, conversation: conversation} -> {wf, model_for(wf, conversation)} end)
    |> Enum.group_by(fn {_wf, model} -> model_key(model) end)
    |> Enum.flat_map(fn {_key, [{_wf, model} | _] = group} ->
      if probe(model) == :ok do
        for {wf, _model} <- group, resume(wf) == :ok do
          Events.ui_broadcast({:toast, "Workflow #{wf.display_name} resumed"})
          wf.run_id
        end
      else
        []
      end
    end)
  end

  defp model_for(wf, conversation) do
    conversation = conversation || (wf.conversation_id && Conversations.get(wf.conversation_id))
    Workflows.resolve_model([], Settings.get(), conversation)
  end

  defp model_key(nil), do: nil
  defp model_key(%{provider: provider, model: model}), do: {provider.id, model}

  defp resume(wf) do
    case Workflows.control(wf.run_id, :resume, []) do
      :ok -> :ok
      other -> other
    end
  end

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
