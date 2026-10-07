defmodule SwarmCode.Daemon.Service.Rewind do
  @moduledoc """
  cli020 C16 (competitors-8, decision 4h): rewind the conversation, its files,
  or both, to before one of its turns.

  `turns/1` lists what can be rewound to: every user message of the
  conversation that is not superseded and not a steer (a steer carries the run
  it steers in both `run_id` and `reply_to_run_id`), newest first, at most 200,
  each with the turn number `Checkpoints.for_conversation/2` gives its run
  (every run of the conversation, superseded ones included, by start, from 1)
  and how many files that turn changed.

  `run/3` rewinds to before a message, in this order: (1) stop the live runs
  of the conversation launched at or after it, waiting for them (10 s at
  most); (2) for `:both`/`:conversation`, supersede the message and everything
  after it (`Conversations.supersede_from/2`, F2; a local stand-in until it is
  synced); (3) for `:both`/`:files`, `Checkpoints.restore_run_report/2` for the
  message's run (or the first later run with checkpoints), which takes every
  file of that turn or a later one back to its earliest snapshot and records
  the "Rewound N file(s)…" message. The answer carries the message's text and
  images so they can go back into the composer (nil text for `:files`).

  Everything here reads and writes the Repo: the backend runs it as owned work.
  """
  import Ecto.Query, only: [from: 2]
  alias SwarmCode.Domain.{Checkpoints, Conversations, Engine, Repo}
  alias SwarmCode.Domain.Conversations.{Message, Run}

  @limit 200
  @stop_wait_ms 10_000

  @doc "The turns of `conversation_id` that can be rewound to, newest first."
  @spec turns(String.t()) :: [map()]
  def turns(conversation_id) do
    runs = Conversations.list_runs(conversation_id)
    numbers = turn_numbers(runs)

    files =
      conversation_id
      |> Checkpoints.for_conversation(runs)
      |> Map.new(&{&1.run_id, length(&1.files)})

    conversation_id
    |> user_messages()
    |> Enum.map(fn m ->
      %{
        message_id: m.id,
        position: m.position,
        turn: m.run_id && numbers[m.run_id],
        prompt: prompt_line(m.prompt),
        at: m.inserted_at && DateTime.to_unix(m.inserted_at, :millisecond),
        run_id: m.run_id,
        files: (m.run_id && Map.get(files, m.run_id)) || 0
      }
    end)
  end

  # `Checkpoints.for_conversation/2`'s numbering: every run, by start, from 1.
  defp turn_numbers(runs) do
    runs
    |> Enum.sort_by(&(&1.started_at || &1.inserted_at), DateTime)
    |> Enum.with_index(1)
    |> Map.new(fn {run, n} -> {run.id, n} end)
  end

  defp user_messages(conversation_id) do
    Repo.all(
      from(m in Message,
        where:
          m.conversation_id == ^conversation_id and m.role == "user" and
            is_nil(m.superseded_at) and
            not (not is_nil(m.reply_to_run_id) and m.run_id == m.reply_to_run_id),
        order_by: [desc: m.position],
        limit: @limit,
        select: %{
          id: m.id,
          position: m.position,
          run_id: m.run_id,
          inserted_at: m.inserted_at,
          prompt: fragment("substr(coalesce(?, ''), 1, 512)", m.content)
        }
      )
    )
  end

  defp prompt_line(text) do
    text |> to_string() |> String.split("\n", parts: 2) |> hd() |> String.slice(0, 120)
  end

  @doc "The newest user message that can be rewound to (`/undo`), or nil."
  @spec newest(String.t()) :: String.t() | nil
  def newest(conversation_id) do
    case user_messages(conversation_id) do
      [m | _] -> m.id
      [] -> nil
    end
  end

  @doc """
  Rewinds `conversation` to before `message_id` (`scope` `:both`,
  `:conversation` or `:files`): `{:ok, %{text, attachments, restored,
  skipped, superseded}}` or `{:error, reason}` (`:not_found`, `:busy` while a
  compaction runs, `:database_busy`, or a restore sentence when the files
  could not be put back; `superseded` says whether the conversation part was
  already done).
  """
  @spec run(struct(), String.t(), :both | :conversation | :files) ::
          {:ok, map()} | {:error, term()}
  def run(conversation, message_id, scope) when scope in [:both, :conversation, :files] do
    with %Message{} = message <- target(conversation.id, message_id),
         :ok <- no_compaction(conversation.id),
         :ok <- stop_later_runs(conversation.id, message) do
      superseded? = scope in [:both, :conversation]

      with :ok <- if(superseded?, do: supersede(conversation, message), else: :ok),
           {:ok, restored, skipped} <- restore(conversation.id, message, scope) do
        {:ok,
         %{
           text: if(superseded?, do: message.content),
           attachments: if(superseded?, do: message.attachments || [], else: []),
           restored: restored,
           skipped: skipped,
           superseded: superseded?
         }}
      else
        {:error, reason} when superseded? -> {:error, {:restore_failed, reason, :superseded}}
        {:error, reason} -> {:error, reason}
      end
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp target(conversation_id, message_id) do
    Repo.one(
      from(m in Message,
        where:
          m.id == ^message_id and m.conversation_id == ^conversation_id and m.role == "user" and
            is_nil(m.superseded_at)
      )
    )
  rescue
    Ecto.Query.CastError -> nil
  end

  defp no_compaction(conversation_id) do
    if Enum.any?(live_runs(conversation_id), &(&1.kind == "compact")),
      do: {:error, :busy},
      else: :ok
  end

  defp live_runs(conversation_id) do
    case Engine.running_runs(conversation_id) do
      [] -> []
      ids -> Repo.all(from(r in Run, where: r.id in ^ids))
    end
  end

  # (1) Every live run launched at or after the message stops first.
  defp stop_later_runs(conversation_id, message) do
    ids =
      for run <- live_runs(conversation_id),
          run.id == message.run_id or
            DateTime.compare(run.inserted_at, message.inserted_at) != :lt,
          do: run.id

    Enum.each(ids, &Engine.stop_run/1)
    wait_stopped(conversation_id, ids, System.monotonic_time(:millisecond) + @stop_wait_ms)
  end

  defp wait_stopped(_conversation_id, [], _deadline), do: :ok

  defp wait_stopped(conversation_id, ids, deadline) do
    live = Engine.running_runs(conversation_id)

    cond do
      not Enum.any?(ids, &(&1 in live)) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :busy}

      true ->
        receive do
        after
          50 -> wait_stopped(conversation_id, ids, deadline)
        end
    end
  end

  # (2) F2's `Conversations.supersede_from/2` (synced at desktop 7b8f379f):
  # this message, every later one and the runs they launched.
  defp supersede(conversation, message) do
    case Conversations.supersede_from(conversation, message) do
      {:ok, _runs} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # (3) The files: the message's run, or the first later run with checkpoints.
  defp restore(_conversation_id, _message, :conversation), do: {:ok, 0, []}

  defp restore(conversation_id, message, _scope) do
    runs = Conversations.list_runs(conversation_id)
    numbers = turn_numbers(runs)
    with_files = Checkpoints.for_conversation(conversation_id, runs)
    from_turn = (message.run_id && numbers[message.run_id]) || turn_after(runs, numbers, message)

    candidate =
      with_files
      |> Enum.filter(&(is_binary(&1.run_id) and from_turn != nil and &1.turn >= from_turn))
      |> Enum.min_by(& &1.turn, fn -> nil end)

    case candidate do
      nil ->
        {:ok, 0, []}

      %{run_id: run_id} ->
        case Checkpoints.restore_run_report(conversation_id, run_id) do
          {:ok, %{restored: n, skipped: skipped}} ->
            {:ok, n, Enum.map(skipped, fn {path, reason} -> "#{path} (#{reason})" end)}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # A message that launched no run: the first run started after it.
  defp turn_after(runs, numbers, message) do
    runs
    |> Enum.filter(&(DateTime.compare(&1.inserted_at, message.inserted_at) != :lt))
    |> Enum.map(&numbers[&1.id])
    |> Enum.min(fn -> nil end)
  end
end
