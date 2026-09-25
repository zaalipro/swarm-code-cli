defmodule SwarmCode.Daemon.Service.Settings.Headless do
  @moduledoc """
  What `swarmcode config` (pass 74, spec §3.10.3) needs from the service
  beside the facade: the project of a folder, a conversation of it, a
  context, and tasks run in the calling process's own supervised child with
  the spec's timeout and stop rules (§3.3.8 rule 10). Nothing here is kept
  between calls.
  """

  import Ecto.Query, only: [from: 2]

  alias SwarmCode.Daemon.Service.Settings
  alias SwarmCode.Daemon.Service.Settings.{Command, Context, Error, Result, TaskSpec, Tasks}
  alias SwarmCode.Domain.Conversations.Conversation
  alias SwarmCode.Domain.Projects.Project
  alias SwarmCode.Domain.Repo

  @doc "The known project whose root is `dir` (its real path)."
  @spec project(String.t()) :: {:ok, struct()} | {:error, :not_a_project}
  def project(dir) when is_binary(dir) do
    with {:ok, root} <- SwarmCode.Domain.Tools.Path.real_path(Path.expand(dir)),
         %Project{} = project <-
           Repo.one(from(p in Project, where: p.root_path == ^root, limit: 1)) do
      {:ok, project}
    else
      _ -> {:error, :not_a_project}
    end
  end

  @doc "A conversation of `project`: `latest` or an id."
  @spec conversation(struct(), String.t()) :: {:ok, struct()} | {:error, :no_conversation}
  def conversation(%Project{id: project_id}, "latest") do
    case Repo.one(
           from(c in Conversation,
             where:
               c.project_id == ^project_id and is_nil(c.research_id) and
                 is_nil(c.scheduled_task_id),
             order_by: [desc: c.updated_at, desc: c.id],
             limit: 1
           )
         ) do
      nil -> {:error, :no_conversation}
      conversation -> {:ok, conversation}
    end
  end

  def conversation(%Project{id: project_id}, id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        case Repo.one(
               from(c in Conversation,
                 where: c.id == ^uuid and c.project_id == ^project_id,
                 limit: 1
               )
             ) do
          nil -> {:error, :no_conversation}
          conversation -> {:ok, conversation}
        end

      :error ->
        {:error, :no_conversation}
    end
  end

  @doc "A headless context for `project` and `conversation`."
  @spec context(struct() | nil, struct() | nil) :: Context.t()
  def context(project, conversation),
    do:
      Context.new(
        project: project,
        conversation: conversation,
        override: nil,
        origin: :headless
      )

  @doc """
  Run a settings command; a task it starts runs here to its end. Answers
  `{:ok, result}`, `{:task, result, {:ok, value} | {:error, words}}` or
  `{:error, error}`.
  """
  @spec command(Command.t(), Context.t(), keyword()) ::
          {:ok, Result.t()}
          | {:task, Result.t(), {:ok, term()} | {:error, String.t()}}
          | {:error, Error.t()}
  def command(%Command{} = command, %Context{} = ctx, opts \\ []) do
    case Settings.command(command, ctx) do
      {:task, %TaskSpec{} = spec, %Result{} = result} -> {:task, result, run_task(spec, opts)}
      other -> other
    end
  end

  @doc """
  Run a task in a supervised child of this process (rule 10). A cancellable
  task past its timeout is stopped by its kind (`no answer in N s`); one that
  is not cancellable is waited for, `:on_report` hearing `still running after
  N s` each time its reporting deadline passes.
  """
  @spec run_task(TaskSpec.t(), keyword()) :: {:ok, term()} | {:error, String.t()}
  def run_task(%TaskSpec{} = spec, opts \\ []) do
    supervisor = Keyword.get(opts, :supervisor, SwarmCode.Domain.TaskSupervisor)
    on_report = Keyword.get(opts, :on_report, fn _words -> :ok end)
    id = Ecto.UUID.generate()
    task = Tasks.run(spec, id, self(), supervisor)
    started = System.monotonic_time(:millisecond)
    await(task, spec, id, started, on_report)
  end

  defp await(task, spec, id, started, on_report) do
    ref = task.ref

    receive do
      {^ref, result} ->
        Process.demonitor(ref, [:flush])
        flush_progress(id)
        answer(result, spec)

      {:DOWN, ^ref, :process, _pid, _reason} ->
        flush_progress(id)
        {:error, "the check stopped without an answer"}

      {:settings_task_progress, ^id, _progress} ->
        await(task, spec, id, started, on_report)
    after
      remaining(spec, started) ->
        if spec.cancellable? do
          Tasks.stop(task, spec)
          flush_progress(id)
          {:error, "no answer in #{div(spec.timeout_ms + 999, 1_000)} s"}
        else
          elapsed = div(System.monotonic_time(:millisecond) - started + 500, 1_000)
          on_report.("still running after #{elapsed} s")
          await(task, spec, id, System.monotonic_time(:millisecond), on_report)
        end
    end
  end

  defp remaining(spec, started),
    do: max(spec.timeout_ms - (System.monotonic_time(:millisecond) - started), 0)

  defp answer({:ok, value}, _spec), do: {:ok, value}

  defp answer({:error, words}, spec) when is_binary(words),
    do: {:error, Tasks.redact(words, spec.redact || [])}

  defp answer(_other, _spec), do: {:error, "the check stopped without an answer"}

  defp flush_progress(id) do
    receive do
      {:settings_task_progress, ^id, _} -> flush_progress(id)
    after
      0 -> :ok
    end
  end
end
