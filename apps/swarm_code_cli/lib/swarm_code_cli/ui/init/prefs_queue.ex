defmodule SwarmCodeCLI.UI.Init.PrefsQueue do
  @moduledoc """
  The session runtime's queue of cli.json jobs (cli74, spec §3.8.2): FIFO,
  one job at a time, at most 32 in all — the one running and 31 waiting; a
  33rd answers `{:error, :busy}`. Two legacy saves in a row wait as one (the
  panel, then the theme: both land), as they did before the queue.
  """

  @max_jobs 32

  defstruct jobs: :queue.new(), size: 0

  @type t :: %__MODULE__{jobs: :queue.queue(), size: non_neg_integer()}

  @doc "An empty queue."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "The most jobs at once, the running one included."
  @spec max_jobs() :: pos_integer()
  def max_jobs, do: @max_jobs

  @doc "The jobs waiting."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{size: size}), do: size

  @doc "Queues `job` behind the running one, or `{:error, :busy}` when full."
  @spec push(t(), term()) :: {:ok, t()} | {:error, :busy}
  def push(%__MODULE__{} = queue, {:legacy, wanted} = job) do
    case :queue.peek_r(queue.jobs) do
      {:value, {:legacy, waiting}} ->
        jobs = :queue.in({:legacy, Map.merge(waiting, wanted)}, :queue.drop_r(queue.jobs))
        {:ok, %{queue | jobs: jobs}}

      _ ->
        append(queue, job)
    end
  end

  def push(%__MODULE__{} = queue, job), do: append(queue, job)

  @doc "The next job, or `:empty`."
  @spec pop(t()) :: {:ok, term(), t()} | :empty
  def pop(%__MODULE__{} = queue) do
    case :queue.out(queue.jobs) do
      {{:value, job}, jobs} -> {:ok, job, %{queue | jobs: jobs, size: queue.size - 1}}
      {:empty, _jobs} -> :empty
    end
  end

  defp append(%__MODULE__{size: size}, _job) when size >= @max_jobs - 1, do: {:error, :busy}

  defp append(%__MODULE__{} = queue, job),
    do: {:ok, %{queue | jobs: :queue.in(job, queue.jobs), size: queue.size + 1}}
end
