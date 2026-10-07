defmodule SwarmCode.Domain.Conversations.Writes do
  @moduledoc """
  Turn-level write transactions (spec 55 T4/T5/T6, 55a A-P1): each function is one
  IMMEDIATE transaction under `SwarmCode.Domain.Repo.retry/3`, broadcasts only after the
  commit, and never raises for a busy database.

  Spec 60 T27: that holds for the run's status event and the goal text too — the
  row writes inside the transaction are silent (`broadcast: false`) and the
  after-commit order is `run_status` (when the status changed), `message_updated`,
  `message_created`…, `goals_updated`, `conversation_updated` (when the goal text
  changed), then the touch's `conversation_updated`. Spec 74 EFFICIENCY-14: the goal
  text is not a sidebar column, so no `{:projects_changed}` follows it.
  """
  import Ecto.Query, only: [from: 2]
  alias SwarmCode.Domain.Conversations
  alias SwarmCode.Domain.Conversations.{Conversation, Goal, Message, Run}
  alias SwarmCode.Domain.Repo

  @type turn :: %{user: Message.t() | nil, assistant: Message.t() | nil, run: Run.t()}

  @doc """
  spec 74 BUGS-33: adds a one-shot request's usage (the run label) to a run
  that has already finished — its RunServer, which owns the totals while it
  runs (`RunServer.add_usage/3`), is gone. An increment, so it composes with
  whatever the finish wrote; `{:run_totals}` (spec 74 EFFICIENCY-4) follows the commit.
  """
  @spec add_run_usage(String.t(), non_neg_integer(), non_neg_integer(), float() | nil) ::
          :ok | {:error, :database_busy}
  def add_run_usage(run_id, tokens_in, tokens_out, cost) do
    cost = cost || 0.0

    result =
      Repo.retry(:add_run_usage, fn ->
        Repo.update_all(
          from(r in Run,
            where: r.id == ^run_id,
            update: [
              set: [
                tokens_in: fragment("COALESCE(tokens_in, 0) + ?", ^tokens_in),
                tokens_out: fragment("COALESCE(tokens_out, 0) + ?", ^tokens_out),
                cost_usd: fragment("COALESCE(cost_usd, 0) + ?", ^cost)
              ]
            ]
          ),
          []
        )
      end)

    case result do
      {:error, :database_busy} = busy ->
        busy

      {1, _} ->
        # spec 74 EFFICIENCY-4: a token-only change is `{:run_totals}`.
        if run = Repo.get(Run, run_id),
          do:
            Conversations.broadcast(
              run.conversation_id,
              {:run_totals, run.id,
               %{
                 tokens_in: run.tokens_in || 0,
                 tokens_out: run.tokens_out || 0,
                 cost_usd: run.cost_usd
               }}
            )

        :ok

      _none ->
        :ok
    end
  end

  # spec 55 T4
  # spec 74 BUGS-56: `{:error, :already_resumed}` when `run_attrs` continue a
  # run that already has a live or successful continuation.
  @spec create_turn(String.t(), map() | nil, map() | nil, map()) ::
          {:ok, turn()}
          | {:error,
             :database_busy
             | :already_resumed
             | {:invalid_message, Ecto.Changeset.t()}
             | Ecto.Changeset.t()}
  def create_turn(conversation_id, user_attrs, assistant_attrs, run_attrs) do
    result =
      Repo.retry(:create_turn, fn ->
        Repo.transaction(
          fn ->
            with :ok <- not_resumed(run_attrs),
                 {:ok, run} <- Conversations.insert_run_row(run_attrs),
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

      {:error, :already_resumed} ->
        {:error, :already_resumed}

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
          | {:error,
             :database_busy
             | :already_resumed
             | {:invalid_message, Ecto.Changeset.t()}
             | Ecto.Changeset.t()}
  def resume_turn(conversation_id, %Message{} = user, assistant_attrs, run_attrs) do
    result =
      Repo.retry(:create_turn, fn ->
        Repo.transaction(
          fn ->
            with :ok <- not_resumed(run_attrs),
                 {:ok, run} <- Conversations.insert_run_row(run_attrs),
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

      {:error, :already_resumed} ->
        {:error, :already_resumed}

      {:error, {:invalid_message, _} = reason} ->
        {:error, reason}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  # spec 74 BUGS-56: the same stopped run could be resumed twice (two windows,
  # a double click, `/resume` beside the card's button) and ran two parallel
  # continuations. Checked inside the IMMEDIATE transaction that inserts the
  # continuation, so two launches serialise on the write lock and the second
  # sees the first. No unique index: a continuation that failed at start
  # (compensated to `failed`, no nodes) must not block a new resume.
  @blocking_continuation ~w(running paused waiting_user done)

  defp not_resumed(%{resumed_from_run_id: old_id}) when is_binary(old_id) do
    continued? =
      Repo.exists?(
        from(r in Run,
          where: r.resumed_from_run_id == ^old_id,
          where:
            r.status in @blocking_continuation or
              fragment("EXISTS (SELECT 1 FROM nodes AS n WHERE n.run_id = ?)", r.id)
        )
      )

    if continued?, do: {:error, :already_resumed}, else: :ok
  end

  defp not_resumed(_run_attrs), do: :ok

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

        # spec 74 EFFICIENCY-14 (O4's task, O1's line): no `Projects.broadcast/0`
        # — every open window reloaded its sidebar and the engine's project
        # cache was invalidated for a column the sidebar does not show.
        if goal_conv = out.goal_conv,
          do: Conversations.broadcast(conv_id, {:conversation_updated, goal_conv})

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
            # spec 74 BUGS-20: the caller's struct is the RunServer's boot-time
            # copy — the Runner writes phase, logs and admissions on its own.
            # The changeset only writes the changed columns, so the row was
            # right, but the struct returned (and broadcast) put the phase, the
            # logs and the admitted count back to their boot values.
            fresh = Repo.get(SwarmCode.Domain.Workflows.Run, wf.run_id) || wf

            wf =
              case fresh |> SwarmCode.Domain.Workflows.Run.changeset(wf_attrs) |> Repo.update() do
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
