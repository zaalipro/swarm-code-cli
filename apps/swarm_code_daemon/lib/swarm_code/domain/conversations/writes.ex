defmodule SwarmCode.Domain.Conversations.Writes do
  @moduledoc """
  Turn-level write transactions (spec 55 T4/T5/T6, 55a A-P1): each function is one
  IMMEDIATE transaction under `SwarmCode.Domain.Repo.retry/3`, broadcasts only after the
  commit, and never raises for a busy database.

  Spec 60 T27: that holds for the run's status event and the goal text too — the
  row writes inside the transaction are silent (`broadcast: false`) and the
  after-commit order is `run_status` (when the status changed), `message_updated`,
  `message_created`…, `goals_updated`, `conversation_updated` (+ `Projects.broadcast/0`
  when the goal text changed), then the touch's `conversation_updated`.
  """
  import Ecto.Query, only: [from: 2]
  alias SwarmCode.Domain.Conversations
  alias SwarmCode.Domain.Conversations.{Conversation, Goal, Message, Run}
  alias SwarmCode.Domain.Repo

  @type turn :: %{user: Message.t() | nil, assistant: Message.t() | nil, run: Run.t()}

  # spec 55 T4
  @spec create_turn(String.t(), map() | nil, map() | nil, map()) ::
          {:ok, turn()}
          | {:error, :database_busy | {:invalid_message, Ecto.Changeset.t()} | Ecto.Changeset.t()}
  def create_turn(conversation_id, user_attrs, assistant_attrs, run_attrs) do
    result =
      Repo.retry(:create_turn, fn ->
        Repo.transaction(
          fn ->
            with {:ok, run} <- Conversations.insert_run_row(run_attrs),
                 {:ok, user} <- insert_or_nil(conversation_id, user_attrs, run.id),
                 {:ok, assistant} <- insert_or_nil(conversation_id, assistant_attrs, run.id) do
              %{user: user, assistant: assistant, run: run}
            else
              {:error, reason} -> Repo.rollback(reason)
            end
          end,
          mode: :immediate
        )
      end)

    case result do
      {:ok, %{user: user, assistant: assistant, run: run} = turn} ->
        if user, do: Conversations.broadcast(conversation_id, {:message_created, user})
        if assistant, do: Conversations.broadcast(conversation_id, {:message_created, assistant})
        Conversations.broadcast_run_created(run)
        {:ok, turn}

      {:error, :database_busy} ->
        {:error, :database_busy}

      {:error, {:invalid_message, _} = reason} ->
        {:error, reason}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  `create_turn/4` around a user row that is already in the transcript
  (spec 67 T9).

  An automatic compaction stores the typed message before the compact run
  starts and chains the chat turn onto it, so by the time the run row exists the
  user row is minutes old and only needs its `run_id`. Same transaction, same
  retry, same broadcasts — except the user row, which every window already has.
  """
  @spec resume_turn(String.t(), Message.t(), map(), map()) ::
          {:ok, %{user: Message.t(), assistant: Message.t() | nil, run: Run.t()}}
          | {:error, :database_busy | {:invalid_message, Ecto.Changeset.t()} | Ecto.Changeset.t()}
  def resume_turn(conversation_id, %Message{} = user, assistant_attrs, run_attrs) do
    result =
      Repo.retry(:create_turn, fn ->
        Repo.transaction(
          fn ->
            with {:ok, run} <- Conversations.insert_run_row(run_attrs),
                 {:ok, user} <- link_message(user, run.id),
                 {:ok, assistant} <- insert_or_nil(conversation_id, assistant_attrs, run.id) do
              %{user: user, assistant: assistant, run: run}
            else
              {:error, reason} -> Repo.rollback(reason)
            end
          end,
          mode: :immediate
        )
      end)

    case result do
      {:ok, %{user: user, assistant: assistant, run: run} = turn} ->
        Conversations.broadcast(conversation_id, {:message_updated, user})
        if assistant, do: Conversations.broadcast(conversation_id, {:message_created, assistant})
        Conversations.broadcast_run_created(run)
        {:ok, turn}

      {:error, :database_busy} ->
        {:error, :database_busy}

      {:error, {:invalid_message, _} = reason} ->
        {:error, reason}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  # Silent inside the transaction, like every other write here; the
  # `message_updated` event goes out after the commit.
  defp link_message(%Message{} = message, run_id) do
    case message |> Message.changeset(%{run_id: run_id}) |> Repo.update() do
      {:ok, updated} -> {:ok, updated}
      {:error, changeset} -> {:error, {:invalid_message, changeset}}
    end
  end

  defp insert_or_nil(_conversation_id, nil, _run_id), do: {:ok, nil}

  defp insert_or_nil(conversation_id, attrs, run_id) do
    case Conversations.insert_message(Map.put(attrs, :run_id, run_id), conversation_id) do
      {:ok, message} -> {:ok, message}
      {:error, changeset} -> {:error, {:invalid_message, changeset}}
    end
  end

  # spec 55 T5
  @type finish_opt ::
          {:update_message, {Message.t(), map()}}
          | {:create_messages, [map()]}
          | {:goal, {Goal.t(), map()}}
          | {:touch, String.t()}

  @spec finish_turn(Run.t(), map(), [finish_opt()]) ::
          {:ok,
           %{
             run: Run.t(),
             message: Message.t() | nil,
             created: [Message.t()],
             goal: Goal.t() | nil
           }}
          | {:error, :database_busy | Ecto.Changeset.t()}
  def finish_turn(%Run{} = run, run_attrs, opts) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    result =
      Repo.retry(:finish_turn, fn ->
        Repo.transaction(
          fn ->
            message = update_message!(opts[:update_message])
            created = Enum.map(opts[:create_messages] || [], &create_message!/1)
            written = update_run!(run, run_attrs)
            {goal, goal_conv} = settle_goal!(opts[:goal])
            touch!(opts[:touch], now)

            %{
              run: written,
              message: message,
              created: created,
              goal: goal,
              # spec 60 T27: what to announce after the commit.
              status_changed?: written.status != run.status,
              goal_conv: goal_conv
            }
          end,
          mode: :immediate
        )
      end)

    case result do
      {:ok, %{run: written, message: message, created: created, goal: goal} = out} ->
        conv_id = written.conversation_id
        # spec 60 T27: after the commit, in this order.
        if out.status_changed?, do: Conversations.broadcast_run_status(written)
        if message, do: Conversations.broadcast(conv_id, {:message_updated, message})
        Enum.each(created, &Conversations.broadcast(conv_id, {:message_created, &1}))
        if goal, do: Conversations.broadcast(conv_id, {:goals_updated, conv_id})

        if goal_conv = out.goal_conv do
          Conversations.broadcast(conv_id, {:conversation_updated, goal_conv})
          SwarmCode.Domain.Projects.broadcast()
        end

        if id = opts[:touch] do
          if conv = Repo.get(Conversation, id),
            do: Conversations.broadcast(id, {:conversation_updated, conv})
        end

        {:ok, Map.drop(out, [:status_changed?, :goal_conv])}

      {:error, :database_busy} ->
        {:error, :database_busy}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  # spec 55 T6
  @spec finish_workflow_run(SwarmCode.Domain.Workflows.Run.t(), map(), Run.t(), map()) ::
          {:ok, {SwarmCode.Domain.Workflows.Run.t(), Run.t()}}
          | {:error, :database_busy | Ecto.Changeset.t()}
  def finish_workflow_run(
        %SwarmCode.Domain.Workflows.Run{} = wf,
        wf_attrs,
        %Run{} = run,
        run_attrs
      ) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    result =
      Repo.retry(:finish_workflow_run, fn ->
        Repo.transaction(
          fn ->
            wf =
              case wf |> SwarmCode.Domain.Workflows.Run.changeset(wf_attrs) |> Repo.update() do
                {:ok, wf} -> wf
                {:error, changeset} -> Repo.rollback(changeset)
              end

            written = update_run!(run, run_attrs)
            touch!(run.conversation_id, now)
            {wf, written, written.status != run.status}
          end,
          mode: :immediate
        )
      end)

    case result do
      {:ok, {wf, written, status_changed?}} ->
        # spec 60 T27: the status first, after the commit.
        if status_changed?, do: Conversations.broadcast_run_status(written)

        if conv = Repo.get(Conversation, written.conversation_id),
          do: Conversations.broadcast(conv.id, {:conversation_updated, conv})

        {:ok, {wf, written}}

      {:error, :database_busy} ->
        {:error, :database_busy}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  defp update_message!(nil), do: nil

  defp update_message!({%Message{} = message, attrs}) do
    case message |> Message.changeset(attrs) |> Repo.update() do
      {:ok, updated} -> updated
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp create_message!(attrs) do
    case Conversations.insert_message(attrs, attrs.conversation_id) do
      {:ok, message} -> message
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp update_run!(run, attrs) do
    # spec 60 T27: silent inside the transaction.
    case Conversations.update_run_row(run, attrs, broadcast: false) do
      {:ok, updated} -> updated
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  # `{goal, conversation | nil}` — the conversation when its goal text changed.
  defp settle_goal!(nil), do: {nil, nil}

  defp settle_goal!({%Goal{} = goal, attrs}) do
    case goal |> Goal.changeset(attrs) |> Repo.update() do
      {:ok, updated} ->
        # spec 60 T27: silent here; announced after the commit.
        {:ok, goal_conv} = Conversations.sync_goal_text(updated.conversation_id, broadcast: false)
        {updated, goal_conv}

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  defp touch!(nil, _now), do: :ok

  defp touch!(conversation_id, now) do
    Repo.update_all(from(c in Conversation, where: c.id == ^conversation_id),
      set: [updated_at: now]
    )

    :ok
  end
end
