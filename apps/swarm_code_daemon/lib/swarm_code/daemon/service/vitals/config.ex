defmodule SwarmCode.Daemon.Service.Vitals.Config do
  @moduledoc """
  cli021 C2: the model names the vitals panel lists for a conversation, read by
  one owned task of `Vitals` (database reads, never in the process itself).

  `mode` follows the desktop's speed monitor (`SpeedMonitor.mode/3`): an Ultra
  conversation lists three slots, a consensus conversation or one whose newest
  run is a swarm lists two, anything else one. `main`, `worker` and `validator`
  are the effective models of those slots (a `--model` session override
  included, as the status line shows); `others` are the models its recent runs
  used outside them (at most 3).
  """
  import Ecto.Query, only: [from: 2]

  alias SwarmCode.Daemon.Service.SessionConfiguration
  alias SwarmCode.Domain.{Conversations, Providers, Repo}
  alias SwarmCode.Domain.Conversations.Run

  @recent_runs 20
  @max_others 3

  @type t :: %{
          optional(:mode) => :single | :two | :ultra,
          optional(:main) => String.t() | nil,
          optional(:worker) => String.t() | nil,
          optional(:validator) => String.t() | nil,
          optional(:others) => [String.t()]
        }

  @spec read(String.t()) :: t()
  def read(conversation_id) do
    case Conversations.get(conversation_id) do
      nil ->
        %{}

      conversation ->
        conversation = SessionConfiguration.overlay(conversation)
        runs = recent_runs(conversation_id)

        slots = %{
          main: model(conversation, :chat),
          worker: model(conversation, :swarm),
          validator: model(conversation, :validator)
        }

        Map.merge(slots, %{mode: mode(conversation, runs), others: others(runs, slots)})
    end
  rescue
    _ -> %{}
  end

  defp recent_runs(conversation_id) do
    Repo.all(
      from(r in Run,
        where: r.conversation_id == ^conversation_id,
        order_by: [desc: r.started_at],
        limit: @recent_runs,
        select: {r.kind, r.model}
      )
    )
  end

  defp mode(%{ultra: true}, _runs), do: :ultra
  defp mode(%{consensus: true}, _runs), do: :two
  defp mode(_conversation, [{"swarm", _model} | _]), do: :two
  defp mode(_conversation, _runs), do: :single

  defp others(runs, slots) do
    known = Map.values(slots)

    runs
    |> Enum.map(&elem(&1, 1))
    |> Enum.filter(&(is_binary(&1) and &1 != "" and &1 not in known))
    |> Enum.uniq()
    |> Enum.take(@max_others)
  end

  defp model(conversation, role) do
    case Providers.effective_model(conversation, role) do
      {:ok, %{model: model}} when is_binary(model) -> model
      _ -> nil
    end
  end
end
