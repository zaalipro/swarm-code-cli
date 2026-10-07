defmodule SwarmCode.Domain.Conversations do
  @moduledoc """
  Conversations, messages, runs and nodes (persistence + PubSub).
  """
  import Ecto.Query, warn: false, except: [update: 2, update: 3]

  require Logger

  alias SwarmCode.Domain.Conversations.{Conversation, Goal, LaunchPairing, Message, Node, Run}
  alias SwarmCode.Domain.Engine
  alias SwarmCode.Domain.Projects
  alias SwarmCode.Domain.Repo

  # spec 36 §A11: one implementation of the `"conversation:<id>"` topic, in
  # `Engine.Events`. These three names stay so callers do not have to change.
  defdelegate topic(conversation_id), to: Engine.Events
  defdelegate subscribe(conversation_id), to: Engine.Events
  defdelegate broadcast(conversation_id, event), to: Engine.Events

  @runs_topic "runs"
  # Spec 41 §3.4 (browser check 2): three tries, 100 ms apart.
  # Spec 54 §1.1 (54a A1): five tries, 20–150 ms apart and jittered. Under the
  # eight-lane load the writers arrived in convoys, so three fixed 100 ms
  # sleeps put every retry of every writer back on the lock in the same
  # millisecond; the jitter spreads them and the two extra tries cover a lock
  # held past `busy_timeout`.
  @busy_attempts 5

  # spec 60 T19: what the history window loads — never `reasoning`, the persisted
  # extended thinking every turn start used to read and discard.
  # spec 74 EFFICIENCY-3: the columns the sidebar reads from a listed row
  # (Frame's conv_row, project_nodes, matches?, row_statuses, unread_markers;
  # WorkspaceLive's conv_map_and_loose and reload_sidebar). `inserted_at` is
  # left out on purpose: a nil there marks a projected row, which `update/2`
  # re-reads before it writes and broadcasts.
  @sidebar_row_fields ~w(id project_id title pinned_at scheduled_task_id updated_at last_seen_at queued research_id)a

  # spec 74 EFFICIENCY-14: the columns the sidebar renders or filters on. A
  # write that changes one of them re-lists every window's sidebar.
  @nav_fields ~w(title project_id pinned_at research_id scheduled_task_id queued)a

  # spec 74 UX-12: per-conversation settings. A write that changes only these
  # keeps `updated_at` and sends no list broadcast.
  @settings_fields ~w(mode chat_provider_id chat_model swarm_provider_id swarm_model effort
                      swarm_effort ultra authoring_workflow consensus consensus_checks
                      consensus_rounds judge_provider_id judge_model judge_effort
                      implementer_provider_id implementer_model implementer_effort
                      validator_provider_id validator_model validator_effort compact_due)a

  # SQLite's default SQLITE_MAX_VARIABLE_NUMBER is 32 766; stay below it. Not
  # the 900 spec 74 suggests: at 2 000 conversations three chunks measured
  # 26–28 ms against 20 ms for the one query, and one query is what every
  # sidebar below the cliff runs today.
  @id_chunk 30_000

  @history_fields ~w(id conversation_id role content run_id reply_to_run_id position attachments research_ids superseded_at inserted_at updated_at)a

  @doc """
  Runs `fun` again when SQLite says the database is busy (spec 41 §3.4,
  browser check 2).

  Since spec 51 §1.2 the repo runs IMMEDIATE transactions — a transaction
  that reads and then writes takes the writer lock at BEGIN and *waits* on
  `busy_timeout` instead of being refused outright — so this wrapper remains
  for the residual case of a writer holding the lock longer than
  `busy_timeout` (15 s). It now sits inside `create_message/1`.

  Anything that is not a busy error is re-raised. When the attempts run out
  the caller gets `{:error, :database_busy}` instead of an exception, so a
  LiveView is never killed by one contended write.

  Spec 54 §1.1 (54a A1): also every write of the engine's hot path — the
  RunServer's per-flush transaction and its node INSERTs. The sleep happens
  **outside** the transaction, so a retry never holds the writer lock while it
  waits.
  """
  @spec with_busy_retry((-> result), pos_integer()) :: result | {:error, :database_busy}
        when result: term()
  # spec 55 T3: the body moved down into `Repo.retry/3`; this is the delegate.
  def with_busy_retry(fun, attempts \\ @busy_attempts), do: Repo.retry(:legacy, fun, attempts)

  @doc """
  Every run status change of every conversation (spec 07 §6).

  The per-conversation topic only reaches the conversation that is open; the
  sidebar has to know about all of them to spin the right rows.
  """
  def subscribe_runs, do: SwarmCode.Domain.PubSub.subscribe(SwarmCode.Domain.PubSub, @runs_topic)

  defp broadcast_run(%Run{} = run) do
    SwarmCode.Domain.PubSub.broadcast(
      SwarmCode.Domain.PubSub,
      @runs_topic,
      {:run_status, run.conversation_id, run.status}
    )
  end

  def list_for_project(project_id) do
    Repo.all(
      from(c in Conversation,
        where: c.project_id == ^project_id and is_nil(c.research_id),
        order_by: [desc: :updated_at]
      )
    )
  end

  @doc """
  Every conversation the sidebar can list, newest first, in one query (spec 51
  §1.10): `list_for_project/1`'s predicate without the project filter. Callers
  group by `project_id` in Elixir (`Enum.group_by(& &1.project_id)`).
  """
  #
  # spec 74 EFFICIENCY-3: projected to the columns the sidebar reads
  # (`@sidebar_row_fields`); a row taken from it is re-read by `update/2`.
  @spec list_visible() :: [Conversation.t()]
  def list_visible do
    Repo.all(
      from(c in Conversation,
        where: is_nil(c.research_id),
        order_by: [desc: :updated_at],
        select: struct(c, ^@sidebar_row_fields)
      )
    )
  end

  @doc "Ids of the projects that have a run going right now (panel status dots)."
  @spec running_project_ids() :: [String.t()]
  def running_project_ids do
    case Engine.running_run_ids() do
      [] ->
        []

      ids ->
        Repo.all(
          from(r in Run,
            join: c in Conversation,
            on: c.id == r.conversation_id,
            where: r.id in ^ids,
            distinct: true,
            select: c.project_id
          )
        )
    end
  end

  @doc "Whether a run of this conversation is live right now (spec 21 §3.4)."
  @spec live_run?(String.t()) :: boolean()
  def live_run?(conversation_id) do
    case Engine.running_run_ids() do
      [] ->
        false

      ids ->
        Repo.exists?(
          from(r in Run, where: r.conversation_id == ^conversation_id and r.id in ^ids)
        )
    end
  end

  @doc """
  The marker each sidebar row shows (spec 07 §6), keyed by conversation id:

    * `:running` — the newest run of the conversation is still going (spinner)
    * `:queued`  — messages are waiting to be sent (amber dot)
    * `:failed`  — the newest run failed (red dot)

  Conversations whose newest run is done (or that never ran) are absent, which
  is what "done → nothing" means in the sidebar.
  """
  @spec row_statuses([Conversation.t()]) ::
          %{String.t() => :running | :queued | :failed | :waiting}
  def row_statuses(conversations) when is_list(conversations),
    do: row_statuses(conversations, latest_run_rows(conversations))

  def row_statuses(_conversations), do: %{}

  def row_statuses(conversations, latest) when is_list(conversations) and is_map(latest) do
    waiting = SwarmCode.Domain.Engine.Questions.waiting()

    for conversation <- conversations,
        {status, _finished_at} = Map.get(latest, conversation.id, {nil, nil}),
        marker =
          if(MapSet.member?(waiting, conversation.id),
            do: :waiting,
            else: row_status(status, conversation.queued)
          ),
        marker != nil,
        into: %{},
        do: {conversation.id, marker}
  end

  def row_statuses(_conversations, _latest), do: %{}

  @doc """
  The unread marker of every conversation in `conversations` (spec 08 §9):
  `:done` or `:failed` when its newest run finished after the conversation was
  last seen. Conversations that are still running are not unread — the row
  keeps its spinner.
  """
  @spec unread_markers([Conversation.t()]) :: %{binary() => :done | :failed}
  def unread_markers(conversations) when is_list(conversations),
    do: unread_markers(conversations, latest_run_rows(conversations))

  def unread_markers(_conversations), do: %{}

  def unread_markers(conversations, latest) when is_list(conversations) and is_map(latest) do
    for conversation <- conversations,
        {status, finished} = Map.get(latest, conversation.id, {nil, nil}),
        status in ["done", "failed"],
        unread?(conversation.last_seen_at, finished),
        into: %{},
        do: {conversation.id, if(status == "failed", do: :failed, else: :done)}
  end

  def unread_markers(_conversations, _latest), do: %{}

  def latest_run_rows([]), do: %{}

  # spec 74 EFFICIENCY-3: one `?` per id, so past 32 766 conversations the
  # single IN list raised and the workspace could not mount. Chunked; the
  # groups are per conversation, so the merged map is the same.
  def latest_run_rows(conversations) when is_list(conversations) do
    conversations
    |> Enum.map(& &1.id)
    |> Enum.uniq()
    |> Enum.chunk_every(@id_chunk)
    |> Enum.reduce(%{}, fn ids, acc ->
      Repo.all(
        from(r in Run,
          where: r.conversation_id in ^ids,
          group_by: r.conversation_id,
          # SQLite's bare-column rule: with max() in the select list, the
          # non-aggregated columns come from the row that holds the maximum
          # (spec 51 §1.10) — one row per conversation instead of every run.
          # Not portable; this app has one database.
          select: {r.conversation_id, r.status, r.finished_at, max(r.started_at)}
        )
      )
      |> Enum.reduce(acc, fn {id, status, finished_at, _started_at}, acc ->
        Map.put(acc, id, {status, finished_at})
      end)
    end)
  end

  def latest_run_rows(_conversations), do: %{}

  @doc """
  `latest_run_rows/1` for every row `list_visible/0` returns, with no bound
  id list (spec 74 EFFICIENCY-3): no parameter per conversation, whatever
  their number.

  Spec 74 UI-SPEED-9 step 3: one seek per visible conversation on
  `runs_conversation_id_started_at_desc_index` (a correlated `LIMIT 1`
  subquery) instead of grouping every run of every conversation. Two runs
  started in the same microsecond are ordered by `id`, the higher one being
  the newest — the grouped `max()` left that choice to SQLite.
  """
  @spec latest_run_rows_visible() :: %{String.t() => {String.t(), DateTime.t() | nil}}
  def latest_run_rows_visible do
    Repo.all(
      from(c in Conversation,
        join: r in Run,
        on:
          r.id ==
            fragment(
              "(SELECT r2.id FROM runs AS r2 WHERE r2.conversation_id = ? ORDER BY r2.started_at DESC, r2.id DESC LIMIT 1)",
              c.id
            ),
        where: is_nil(c.research_id),
        select: {c.id, r.status, r.finished_at}
      )
    )
    |> Map.new(fn {id, status, finished_at} -> {id, {status, finished_at}} end)
  end

  defp unread?(_seen, nil), do: false
  defp unread?(nil, _finished), do: true
  defp unread?(seen, finished), do: DateTime.compare(finished, seen) == :gt

  @doc """
  Marks a conversation as seen right now (spec 08 §9). `update_all` on purpose:
  reading a conversation must not bump `updated_at` and reshuffle the sidebar.
  """
  def mark_seen(%Conversation{id: id}), do: mark_seen(id)

  def mark_seen(id) when is_binary(id) do
    now = DateTime.utc_now()

    {count, _} =
      Repo.update_all(from(c in Conversation, where: c.id == ^id), set: [last_seen_at: now])

    if count == 1, do: {:ok, now}, else: {:error, :not_found}
  end

  def mark_seen(_other), do: {:error, :not_found}

  @doc """
  Marks one run's thread as seen right now (spec 12 §1): the run card's unread
  badge clears and every open LiveView is told.
  """
  @spec mark_run_seen(Run.t() | String.t()) :: {:ok, Run.t()} | {:error, :not_found}
  def mark_run_seen(%Run{} = run), do: mark_run_seen(run.id)

  def mark_run_seen(run_id) when is_binary(run_id) do
    case get_run(run_id) do
      nil -> {:error, :not_found}
      run -> update_run(run, %{seen_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)})
    end
  end

  def mark_run_seen(_other), do: {:error, :not_found}

  defp row_status("running", _queued), do: :running
  defp row_status(_status, queued) when is_list(queued) and queued != [], do: :queued
  defp row_status("failed", _queued), do: :failed
  defp row_status(_status, _queued), do: nil

  @doc "The most recently updated conversations across every project (sidebar Recents)."
  def list_recent(limit \\ 12) do
    Repo.all(
      from(c in Conversation,
        where: is_nil(c.research_id),
        order_by: [desc: :updated_at],
        limit: ^limit
      )
    )
  end

  # spec 68 T24: count_for_project/1 removed — zero callers in the codebase.

  def latest_for_project(project_id) do
    Repo.one(
      from(c in Conversation,
        where: c.project_id == ^project_id and is_nil(c.research_id),
        order_by: [desc: :updated_at],
        limit: 1
      )
    )
  end

  # Spec 36 §B6: the id comes off a URL (`/c/:id`), so it is whatever the user
  # typed. A non-UUID raised `Ecto.Query.CastError` inside `handle_params` and
  # took the LiveView down; it is a miss like any other now.
  def get(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Conversation |> Repo.get(uuid) |> Repo.preload(:project)
      :error -> nil
    end
  end

  def get!(id), do: Conversation |> Repo.get!(id) |> Repo.preload(:project)

  def create(project_id) do
    case %Conversation{project_id: project_id}
         |> Conversation.changeset(%{project_id: project_id})
         |> Repo.insert() do
      {:ok, conversation} ->
        Projects.broadcast()
        {:ok, Repo.preload(conversation, :project)}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  A conversation that belongs to no project (spec 21 §2.4). It lives in the
  hidden scratch project, so every "a run has a root" invariant of the engine
  holds — the agent's sandbox is `<config dir>/scratch` until the user picks a
  real project in the composer's switcher.
  """
  def create_without_project, do: create(Projects.scratch!().id)

  @doc """
  The hidden conversation a deep research owns (spec 24 §3.1).

  It lives in the scratch project so every "a run has a conversation and a
  project" invariant of the engine holds, and `research_id` keeps it out of
  every sidebar list.
  """
  @spec create_for_research(integer(), String.t()) :: {:ok, Conversation.t()}
  def create_for_research(research_id, title) do
    {:ok, conversation} = create(Projects.scratch!().id)
    update(conversation, %{research_id: research_id, title: title})
  end

  @doc "The conversations that belong to no project, newest first (spec 21 §2.4)."
  def list_without_project do
    Repo.all(
      from(c in Conversation,
        join: p in assoc(c, :project),
        where: p.scratch == true and is_nil(c.research_id),
        order_by: [desc: c.updated_at],
        preload: [project: p]
      )
    )
  end

  @doc "The pinned conversations of every project, newest pin first (spec 21 §4.3)."
  def list_pinned do
    Repo.all(
      from(c in Conversation,
        where: not is_nil(c.pinned_at) and is_nil(c.research_id),
        order_by: [desc: c.pinned_at],
        preload: [:project]
      )
    )
  end

  @doc "Pins an unpinned conversation, unpins a pinned one (spec 21 §4.6)."
  def toggle_pin(%Conversation{} = conversation),
    do:
      update(conversation, %{
        pinned_at: if(conversation.pinned_at, do: nil, else: DateTime.utc_now())
      })

  def toggle_pin(id) when is_binary(id), do: id |> get!() |> toggle_pin()

  @doc """
  Moves a conversation to another project (spec 21 §3.3). Refused while a run of
  it is live: an agent holding a checkout of the old root must not have the root
  swapped under it (§3.4).
  """
  def set_project(%Conversation{} = conversation, project_id) do
    cond do
      conversation.project_id == project_id ->
        {:ok, conversation}

      live_run?(conversation.id) ->
        {:error, :running}

      true ->
        case update(conversation, %{project_id: project_id}) do
          {:ok, moved} -> {:ok, Repo.preload(moved, :project, force: true)}
          other -> other
        end
    end
  end

  # spec 74 EFFICIENCY-3: a row from the projected `list_visible/0` (no
  # `inserted_at`) is re-read first, so the broadcast carries the whole row.
  def update(%Conversation{id: id, inserted_at: nil}, attrs) when is_binary(id) do
    case get(id) do
      %Conversation{} = full -> update(full, attrs)
      nil -> {:error, :not_found}
    end
  end

  def update(%Conversation{} = conversation, attrs) do
    changeset = Conversation.changeset(conversation, attrs)
    changed = Map.keys(changeset.changes)

    if changeset.valid? and changed != [] and Enum.all?(changed, &(&1 in @settings_fields)) do
      quiet_update(conversation, changeset)
    else
      case Repo.update(changeset) do
        {:ok, conversation} ->
          broadcast(conversation.id, {:conversation_updated, conversation})
          # spec 74 EFFICIENCY-14: every window re-lists its sidebar only when a
          # column the sidebar shows or filters on changed — and a conversation
          # write never invalidates the engine's project cache.
          if Enum.any?(changed, &(&1 in @nav_fields)), do: Projects.broadcast_list()
          {:ok, conversation}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  # spec 74 EFFICIENCY-14 / UX-12 (decision EFF-D7 = UX-D8, accepted): a model,
  # effort, mode or consensus pick is not activity. `update_all` leaves
  # `updated_at` alone — the row keeps its sidebar place and its "3 h ago" in
  # every window — and the re-read is the row as stored (the held struct may be
  # older than the row: `touch/1` writes `updated_at` with `update_all` too).
  defp quiet_update(conversation, changeset) do
    set = Map.to_list(changeset.changes)

    case Repo.update_all(from(c in Conversation, where: c.id == ^conversation.id), set: set) do
      {1, _} ->
        case Repo.get(Conversation, conversation.id) do
          %Conversation{} = fresh ->
            fresh = %{fresh | project: conversation.project}
            broadcast(fresh.id, {:conversation_updated, fresh})
            {:ok, fresh}

          nil ->
            {:error, Ecto.Changeset.add_error(changeset, :id, "no longer exists")}
        end

      {0, _} ->
        {:error, Ecto.Changeset.add_error(changeset, :id, "no longer exists")}
    end
  end

  @doc """
  Renames a conversation (the inline rename of spec 06 §10). A blank title
  leaves the old one in place.
  """
  def rename(%Conversation{} = conversation, title) do
    case title |> to_string() |> String.trim() do
      "" -> {:ok, conversation}
      trimmed -> update(conversation, %{title: trimmed})
    end
  end

  def rename(id, title) when is_binary(id) do
    case get(id) do
      nil -> {:error, :not_found}
      conversation -> rename(conversation, title)
    end
  end

  def set_title_from(%Conversation{} = conversation, text) do
    collapsed =
      text
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()
      # The sidebar title is the text, not the command (spec 07 §14).
      |> String.replace(~r{^/[A-Za-z0-9_.-]+ }, "")

    cond do
      conversation.title != "New conversation" ->
        {:ok, conversation}

      collapsed == "" ->
        {:ok, conversation}

      true ->
        title =
          if String.length(collapsed) > 60,
            do: String.slice(collapsed, 0, 60) <> "…",
            else: collapsed

        # Spec 54 §1.1 (54a A1): the first write of every turn, and it raised
        # `Database busy` into `start_swarm/3` under load. Retried, and its
        # `{:error, :database_busy}` is a `with` clause at both entry points.
        with_busy_retry(fn -> update(conversation, %{title: title}) end)
    end
  end

  @doc """
  spec 67 T9 (B34): the running turn asks for a compaction instead of starting
  one. `AgentServer.maybe_auto_compact/2` raises the flag; the next
  `Engine.start_chat_turn/4` compacts *before* it reserves its own two rows and
  clears it again, so a summary can never land above the answer of a turn that
  is still running.

  A bare `update_all` on purpose: no changeset, no broadcast, no read-back —
  the flag is engine bookkeeping, not something a window renders.
  """
  @spec mark_compact_due(String.t() | Conversation.t()) :: :ok
  def mark_compact_due(%Conversation{id: id}), do: mark_compact_due(id)

  def mark_compact_due(id) when is_binary(id), do: set_compact_due(id, true)

  @doc "Clears the flag `mark_compact_due/1` raised (spec 67 T9)."
  @spec clear_compact_due(String.t() | Conversation.t()) :: :ok
  def clear_compact_due(%Conversation{id: id}), do: clear_compact_due(id)

  def clear_compact_due(id) when is_binary(id), do: set_compact_due(id, false)

  defp set_compact_due(id, value) do
    Repo.update_all(from(c in Conversation, where: c.id == ^id), set: [compact_due: value])
    :ok
  end

  @doc """
  spec 74 BUGS-10: takes the flag `mark_compact_due/1` raised — true for
  exactly one caller. `Engine.start_chat_turn/4` used to read `compact_due`
  from the struct the window handed it, which the window never refreshes
  (the flag is written without a broadcast), so an open window never compacted
  and a window mounted with the flag set compacted on every send. The row is
  the only truth, and the conditional UPDATE makes two windows sending at once
  compact once.

  The common case (no flag) is one indexed read and takes no write lock; a
  busy database counts as "not claimed" — the flag stays for the next send.
  """
  @spec claim_compact_due(String.t() | Conversation.t()) :: boolean()
  def claim_compact_due(%Conversation{id: id}), do: claim_compact_due(id)

  def claim_compact_due(id) when is_binary(id) do
    due = from(c in Conversation, where: c.id == ^id and c.compact_due == true)

    with true <- Repo.exists?(due),
         {1, _} <-
           Repo.retry(:compact_due, fn -> Repo.update_all(due, set: [compact_due: false]) end) do
      true
    else
      _ -> false
    end
  end

  @doc """
  Bumps `updated_at` and broadcasts the row as it is *now* (spec 51 §1.5).
  The RunServer hands in the struct it was given at run start; a rename or a
  mode flip during the run must not snap back when the run finishes, so the
  write is by id and the broadcast carries the fresh row.
  """
  @spec touch(Conversation.t() | String.t()) :: {:ok, Conversation.t()} | {:error, :not_found}
  def touch(%Conversation{id: id}), do: touch(id)

  def touch(id) when is_binary(id) do
    Repo.update_all(from(c in Conversation, where: c.id == ^id), set: [updated_at: now()])

    case Repo.get(Conversation, id) do
      nil ->
        {:error, :not_found}

      conversation ->
        # Spec 54 §1.4 (54a A3): no `Projects.broadcast()`. A touch changes only
        # `updated_at`, and that broadcast made *every* open window run
        # `refresh_nav/1` + `assign_panel/1` — ten queries, applied immediately,
        # outside the coalescer — at every run start, every run finish and every
        # steer (6.9 events per second under eight lanes, each of them taking a
        # pool connection the engine's writers were waiting for). The rows a
        # touch reorders are re-read from `{:conversation_updated}` here and,
        # in every other window, from the `{:run_status, …}` the run's own
        # status write broadcasts on the "runs" topic, once per 120 ms flush.
        broadcast(id, {:conversation_updated, conversation})
        {:ok, conversation}
    end
  end

  def delete(%Conversation{} = conversation) do
    Engine.stop_all(conversation.id)
    # Cache ownership is by message id, so collect/delete its entries while
    # the conversation's messages still exist. Evicting early is harmless if
    # the database delete subsequently fails: Markdown is exactly recomputed.
    SwarmCode.Domain.MarkdownCache.delete_conversation(conversation.id)
    result = Repo.delete(conversation)

    if match?({:ok, _}, result) do
      SwarmCode.Domain.UIState.delete(conversation.id)
      broadcast_deleted(conversation.id)
    end

    Projects.broadcast()
    result
  end

  @doc """
  The data layer's delete notice (spec 74 ARCHITECTURE-21): `{:conversation_deleted, id}`
  on the `"conversations"` topic, after a successful delete. Web-side caches
  (UIState, MarkdownCache) can subscribe and evict there instead of being
  called from here; until they do, `delete/1` still calls them directly.
  """
  @spec deleted_topic() :: String.t()
  def deleted_topic, do: "conversations"

  @doc false
  def broadcast_deleted(conversation_id),
    do:
      SwarmCode.Domain.PubSub.broadcast(
        SwarmCode.Domain.PubSub,
        deleted_topic(),
        {:conversation_deleted, conversation_id}
      )

  def list_messages(conversation_id) do
    Repo.all(
      from(m in Message,
        where: m.conversation_id == ^conversation_id,
        order_by: [asc: m.position, asc: m.inserted_at]
      )
    )
  end

  @transcript_fields Message.__schema__(:fields) -- [:reasoning]

  @doc """
  `list_messages/1` for the transcript (spec 74 EFFICIENCY-33): every column
  but `reasoning`, which stays `nil`, plus the virtual `has_reasoning`. The
  disclosure fetches the text with `message_reasoning/1` (or
  `messages_reasoning/1` for a window) when it is shown. `fork/2` and Export
  keep their own readers.
  """
  @spec list_transcript(String.t()) :: [Message.t()]
  def list_transcript(conversation_id) do
    Repo.all(
      from(m in Message,
        where: m.conversation_id == ^conversation_id,
        order_by: [asc: m.position, asc: m.inserted_at],
        select: %{
          struct(m, ^@transcript_fields)
          | has_reasoning:
              type(fragment("coalesce(octet_length(?), 0) > 0", m.reasoning), :boolean)
        }
      )
    )
  end

  @doc "One message's reasoning, or nil (spec 74 EFFICIENCY-33)."
  @spec message_reasoning(String.t()) :: String.t() | nil
  def message_reasoning(id) when is_binary(id),
    do: Repo.one(from(m in Message, where: m.id == ^id, select: m.reasoning))

  @doc "The reasoning of the messages in `ids` that have any, as `%{id => text}`."
  @spec messages_reasoning([String.t()]) :: %{String.t() => String.t()}
  def messages_reasoning([]), do: %{}

  def messages_reasoning(ids) when is_list(ids) do
    ids
    |> Enum.chunk_every(500)
    |> Enum.flat_map(fn chunk ->
      Repo.all(
        from(m in Message,
          where: m.id in ^chunk and not is_nil(m.reasoning) and m.reasoning != "",
          select: {m.id, m.reasoning}
        )
      )
    end)
    |> Map.new()
  end

  # spec 68 T5: targeted query for the assistant message of a specific run,
  # replacing the unbounded list_messages + Enum.find in compensate_start_failure.
  @doc false
  def assistant_message_for_run(conversation_id, run_id) do
    Repo.one(
      from(m in Message,
        where:
          m.conversation_id == ^conversation_id and
            m.run_id == ^run_id and
            m.role == "assistant",
        limit: 1
      )
    )
  end

  @doc """
  The history a new turn reads (spec 50 §1.2): the same byte-budget window as
  `list_messages_window/2`, but never reaching back past the newest non-empty
  `compact` message — that message *is* everything before it, in one page. The
  older rows stay in the database and in the transcript; only the model stops
  being shown them.
  """
  @spec list_history_window(String.t(), non_neg_integer()) :: [Message.t()]
  def list_history_window(conversation_id, byte_budget) do
    list_messages_window(conversation_id, byte_budget, compact_floor(conversation_id))
  end

  @doc """
  How many messages `list_history_window/2` could have reached (spec 51 §6.6).

  The same floor logic, without the byte budget: the compactor compares it with
  what it actually got, so its summary can say how much of the conversation it
  never read instead of implying it read all of it.
  """
  @spec count_history_since_floor(String.t()) :: non_neg_integer()
  def count_history_since_floor(conversation_id) do
    scope =
      case compact_floor(conversation_id) do
        position when is_integer(position) -> from(m in Message, where: m.position >= ^position)
        nil -> from(m in Message)
      end

    # Spec 52 §1.3: a superseded turn is not history any more.
    Repo.one(
      from(m in scope,
        where: m.conversation_id == ^conversation_id and is_nil(m.superseded_at),
        select: count()
      )
    ) || 0
  end

  @doc "The `position` of the newest compact message of a conversation, or nil (spec 50 §1.2)."
  @spec compact_floor(String.t()) :: integer() | nil
  def compact_floor(conversation_id) do
    Repo.one(
      from(m in Message,
        where:
          m.conversation_id == ^conversation_id and m.role == "compact" and m.content != "" and
            is_nil(m.superseded_at),
        order_by: [desc: m.position, desc: m.inserted_at],
        limit: 1,
        select: m.position
      )
    )
  end

  @doc """
  A newest-first byte-budget selection, returned in transcript order.

  Spec 50 §1.2: `floor_position` bounds the window at the bottom as well — no
  row before that `position` is read at all, which is how a compaction shrinks
  what the model sees without deleting anything.
  """
  def list_messages_window(conversation_id, byte_budget, floor_position \\ nil) do
    # Context charges every message at least four tokens even when its content
    # is empty. Give those rows a byte-equivalent cost too, and bound the SQL
    # result itself so a conversation containing millions of empty rows cannot
    # defeat what is meant to be a bounded history read.
    row_overhead = 16
    byte_budget = max(byte_budget, 0)
    row_limit = div(byte_budget, row_overhead) + 1

    scope =
      if is_integer(floor_position),
        do: from(m in Message, where: m.position >= ^floor_position),
        else: from(m in Message)

    rows =
      Repo.all(
        from(m in scope,
          # Spec 52 §1.3: an edited-and-resent turn is out of the history —
          # in both selects, so the budget and the load agree.
          where: m.conversation_id == ^conversation_id and is_nil(m.superseded_at),
          order_by: [desc: m.position, desc: m.inserted_at],
          select: {m.id, fragment("coalesce(octet_length(?), 0)", m.content)},
          limit: ^row_limit
        )
      )

    {ids, _bytes} =
      Enum.reduce_while(rows, {[], 0}, fn {id, bytes}, {ids, total} ->
        total = total + (bytes || 0) + row_overhead
        selected = {[id | ids], total}
        if total > byte_budget, do: {:halt, selected}, else: {:cont, selected}
      end)

    case ids do
      [] ->
        []

      ids ->
        Repo.all(
          from(m in Message,
            where: m.id in ^ids and is_nil(m.superseded_at),
            order_by: [asc: m.position, asc: m.inserted_at],
            # spec 60 T19
            select: struct(m, ^@history_fields)
          )
        )
    end
  end

  @doc """
  Appends a message at the next position of its conversation.

  Returns `{:error, :database_busy}` — never raises — when a writer holds the
  lock past `busy_timeout` (spec 51 §1.2).
  """
  @spec create_message(map()) ::
          {:ok, Message.t()} | {:error, Ecto.Changeset.t() | :database_busy | term()}
  def create_message(attrs) do
    conversation_id = attrs.conversation_id

    # Spec 51 §1.2: IMMEDIATE per call as well as by config — the SELECT max(position)
    # below can never be upgraded to a write under a concurrent writer otherwise.
    with_busy_retry(fn ->
      case Repo.transaction(fn -> insert_message(attrs, conversation_id) end, mode: :immediate) do
        {:ok, {:ok, message}} ->
          broadcast(conversation_id, {:message_created, message})
          {:ok, message}

        {:ok, {:error, changeset}} ->
          {:error, changeset}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  # One SELECT, one INSERT: an IMMEDIATE transaction cannot race another writer
  # on the unique `{conversation_id, position}` index (spec 51 §1.2).
  # spec 55 T4: public (undocumented) so `Conversations.Writes` can use it inside its transaction.
  @doc false
  def insert_message(attrs, conversation_id) do
    position =
      Repo.one(
        from(m in Message,
          where: m.conversation_id == ^conversation_id,
          select: coalesce(max(m.position), 0)
        )
      ) + 1

    %Message{} |> Message.changeset(Map.put(attrs, :position, position)) |> Repo.insert()
  end

  @doc "One message by id, or nil."
  def get_message(id) when is_binary(id), do: Repo.get(Message, id)
  def get_message(_id), do: nil

  def update_message(%Message{} = message, attrs) do
    case message |> Message.changeset(attrs) |> Repo.update() do
      {:ok, message} ->
        broadcast(message.conversation_id, {:message_updated, message})
        {:ok, message}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Spec 52 §1.2: the message is being edited and resent — it, its run and every
  message of that run (the assistant reply, side-chat follow-ups, error rows)
  drop out of the history the model reads. Nothing is deleted; the transcript
  folds them (§1.5). Returns the run that was superseded, or nil.
  """
  @spec supersede(Conversation.t(), Message.t()) ::
          {:ok, Run.t() | nil} | {:error, :database_busy | term()}
  def supersede(%Conversation{id: conv_id}, %Message{} = message) do
    old_run_id = launched_run_id(conv_id, message)
    at = now()

    # Spec 51 §1.2: IMMEDIATE — this reads the run back after writing it.
    result =
      with_busy_retry(fn ->
        Repo.transaction(
          fn ->
            Repo.update_all(supersede_scope(conv_id, message.id, old_run_id),
              set: [superseded_at: at]
            )

            if is_binary(old_run_id) do
              Repo.update_all(from(r in Run, where: r.id == ^old_run_id),
                set: [superseded_at: at]
              )

              Repo.get(Run, old_run_id)
            end
          end,
          mode: :immediate
        )
      end)

    case result do
      {:ok, run} ->
        # Outside the transaction: `clear_goal/1` broadcasts, and a broadcast
        # from inside a write that can still roll back is a lie. `cleared`, not
        # `finish_goal/1`'s `done` — the goal was abandoned mid-flight, not
        # reached; a resent `/goal …` adds the edited goal fresh.
        if run && is_binary(run.goal_id) do
          case Repo.get(Goal, run.goal_id) do
            %Goal{} = goal -> clear_goal(goal)
            nil -> :ok
          end
        end

        # Re-read both rows so every open view folds the card at once.
        if m = Repo.get(Message, message.id), do: broadcast(conv_id, {:message_updated, m})
        if run, do: broadcast(conv_id, {:run_updated, run})

        {:ok, run}

      {:error, :database_busy} = busy ->
        busy

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The run this message *launched*, or nil. A steer carries the run it steers
  # in both `run_id` and `reply_to_run_id` (`Engine.steer/4`, engine.ex:349) and
  # launched nothing: editing it re-steers (§1.4) and must not stop somebody
  # else's run. The same rule `Chat.launch_message/4` pairs cards with.
  defp launched_run_id(conv_id, %Message{} = message) do
    cond do
      is_binary(message.run_id) and message.run_id != message.reply_to_run_id -> message.run_id
      is_nil(message.run_id) -> legacy_run_id(conv_id, message)
      true -> nil
    end
  end

  defp supersede_scope(conv_id, message_id, old_run_id) when is_binary(old_run_id) do
    from(m in Message,
      where:
        m.conversation_id == ^conv_id and is_nil(m.superseded_at) and
          (m.id == ^message_id or m.run_id == ^old_run_id or
             m.reply_to_run_id == ^old_run_id)
    )
  end

  defp supersede_scope(conv_id, message_id, _old_run_id) do
    from(m in Message,
      where: m.conversation_id == ^conv_id and m.id == ^message_id and is_nil(m.superseded_at)
    )
  end

  # Legacy rows only (spec 52 §1.2): before pass 13 a user message did not carry
  # its `run_id`, so the run that message launched is found the way the
  # transcript pairs them — the pairing inverted. spec 74 ARCHITECTURE-21: the
  # fold lives in the data layer (`LaunchPairing.pair/3`), not in `Chat`.
  defp legacy_run_id(conv_id, %Message{} = message) do
    messages = list_messages(conv_id)
    runs = list_runs(conv_id)

    messages
    |> LaunchPairing.pair(runs, %{})
    |> Enum.find_value(fn {run_id, m} -> is_map(m) and m.id == message.id and run_id end)
  end

  @doc """
  Copies this conversation up to (but excluding) `before_position` into a new one.

  Attachments are referenced, not copied; runs and their nodes are not copied —
  the fork starts from a clean transcript.

  Spec 52 §3: a fork is a transcript, not a workspace (spec 52 §1.4 gave
  editing its own path), but it must be faithful: every model, consensus and
  effort setting comes along, a row that was still streaming when the fork was
  taken does not, nor does a superseded one, and the title carries one
  `Fork: ` prefix however many times a fork is forked.
  """
  @spec fork(Conversation.t(), integer()) :: {:ok, Conversation.t()} | {:error, term()}
  def fork(%Conversation{} = conversation, before_position) do
    attrs = %{
      project_id: conversation.project_id,
      title: "Fork: " <> String.replace_prefix(to_string(conversation.title), "Fork: ", ""),
      goal: conversation.goal,
      mode: conversation.mode,
      chat_provider_id: conversation.chat_provider_id,
      chat_model: conversation.chat_model,
      swarm_provider_id: conversation.swarm_provider_id,
      swarm_model: conversation.swarm_model,
      # Spec 52 §3: what the next turn of the fork will be run with.
      effort: conversation.effort,
      swarm_effort: conversation.swarm_effort,
      ultra: conversation.ultra,
      consensus: conversation.consensus,
      consensus_checks: conversation.consensus_checks,
      consensus_rounds: conversation.consensus_rounds,
      judge_provider_id: conversation.judge_provider_id,
      judge_model: conversation.judge_model,
      judge_effort: conversation.judge_effort,
      implementer_provider_id: conversation.implementer_provider_id,
      implementer_model: conversation.implementer_model,
      implementer_effort: conversation.implementer_effort,
      # Spec 75 (pass 71): the validator travels with the other model picks.
      validator_provider_id: conversation.validator_provider_id,
      validator_model: conversation.validator_model,
      validator_effort: conversation.validator_effort
    }

    # spec 36 §A5: one transaction. The message copies used to be an
    # `Enum.each(… |> Repo.insert())` that discarded every result, so a failure
    # half way through left a fork with half a transcript and told nobody.
    result =
      Repo.transaction(fn ->
        fork =
          case %Conversation{} |> Conversation.changeset(attrs) |> Repo.insert() do
            {:ok, fork} -> fork
            {:error, cs} -> Repo.rollback(cs)
          end

        conversation.id
        |> list_messages()
        |> Enum.filter(&fork_row?(&1, before_position))
        |> Enum.each(fn m ->
          %Message{}
          |> Message.changeset(%{
            conversation_id: fork.id,
            role: m.role,
            content: m.content,
            reasoning: m.reasoning,
            attachments: m.attachments,
            tokens_in: m.tokens_in,
            tokens_out: m.tokens_out,
            cost_usd: m.cost_usd,
            position: m.position,
            # Spec 52 §3: the researches the turn was answered from travel with
            # it, so the fork's transcript still says where the answer came from.
            research_ids: m.research_ids
          })
          |> Repo.insert!()
        end)

        fork
      end)

    case result do
      {:ok, fork} ->
        Projects.broadcast()
        {:ok, Repo.preload(fork, :project)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Spec 52 §3: what a fork copies — a user, assistant or swarm row before the
  # cut, that the user has not superseded (§1.2) and that had something to say.
  # An assistant row still streaming when the fork was taken copied as an empty
  # bubble with a model name and a time, and nothing else.
  defp fork_row?(m, before_position) do
    m.position < before_position and m.role in ["user", "assistant", "swarm"] and
      is_nil(m.superseded_at) and
      not (m.role in ["assistant", "swarm"] and to_string(m.content) == "")
  end

  @doc """
  The newest run of `conversation_id` when it was cut short by an app restart,
  together with the titles of the ops that had already finished.
  """
  @spec interrupted_run(String.t()) :: {Run.t(), [String.t()]} | nil
  def interrupted_run(conversation_id) do
    # spec 74 EFFICIENCY-32: only the head run matters — one row, not the list.
    head =
      Repo.all(
        from(r in Run,
          where: r.conversation_id == ^conversation_id,
          order_by: [desc: :started_at],
          limit: 1
        )
      )

    interrupted_run(conversation_id, head)
  end

  @doc """
  `interrupted_run/1` over runs the caller already holds, newest first (the
  order of `list_runs/1`), so opening a conversation reads the runs once
  (spec 74 EFFICIENCY-32).
  """
  @spec interrupted_run(String.t(), [Run.t()]) :: {Run.t(), [String.t()]} | nil
  def interrupted_run(_conversation_id, runs) when is_list(runs) do
    case runs do
      [%Run{status: "stopped", interrupted: true} = run | _] ->
        titles =
          Repo.all(
            from(n in Node,
              where:
                n.run_id == ^run.id and n.kind == "op" and n.status == "done" and
                  n.op_type != "llm",
              order_by: [asc: n.position],
              limit: 20,
              select: n.title
            )
          )

        {run, titles}

      _ ->
        nil
    end
  end

  @doc "Marks a run as no longer needing the resume banner."
  def clear_interrupted(%Run{} = run), do: update_run(run, %{interrupted: false})

  @doc "The most recent distinct user prompts across every conversation, newest first."
  @spec recent_prompts(pos_integer()) :: [String.t()]
  def recent_prompts(limit \\ 200) do
    Repo.all(
      from(m in Message,
        where: m.role == "user" and m.content != "",
        order_by: [desc: m.inserted_at, desc: m.position],
        limit: ^(limit * 3),
        select: m.content
      )
    )
    |> Enum.uniq()
    |> Enum.take(limit)
  end

  @doc "Replaces the queue of pending messages of a conversation."
  def set_queued(%Conversation{} = conversation, queued) do
    case conversation |> Conversation.changeset(%{queued: queued}) |> Repo.update() do
      {:ok, updated} ->
        # spec 60 T64: every window sees the queue it now is.
        broadcast(updated.id, {:conversation_updated, updated})
        {:ok, updated}

      error ->
        error
    end
  end

  @doc "Whether messages wait in the queue — a plain read, no transaction (spec 74 EFFICIENCY-15)."
  @spec queued?(String.t()) :: boolean()
  def queued?(id) when is_binary(id) do
    case Repo.one(from(c in Conversation, where: c.id == ^id, select: c.queued)) do
      [_ | _] -> true
      _empty -> false
    end
  end

  @doc """
  Takes the head of `queued` in one IMMEDIATE transaction (spec 60 T64).

  Every open window runs its own `start_next_queued/1` when a chat turn
  finishes; the pop is what decides which of them launches the message, so the
  head is never started twice.
  """
  @spec pop_queued(String.t()) ::
          {:ok, String.t(), Conversation.t()} | :empty | {:error, :database_busy}
  def pop_queued(id) when is_binary(id) do
    outcome =
      Repo.retry(:pop_queued, fn ->
        Repo.transaction(
          fn ->
            case Repo.get(Conversation, id) do
              %Conversation{queued: [head | rest]} = conversation ->
                {:ok, updated} =
                  conversation |> Conversation.changeset(%{queued: rest}) |> Repo.update()

                {:ok, head, Repo.preload(updated, :project)}

              _ ->
                :empty
            end
          end,
          mode: :immediate
        )
      end)

    case outcome do
      {:ok, {:ok, head, conversation}} ->
        broadcast(conversation.id, {:conversation_updated, conversation})
        {:ok, head, conversation}

      {:ok, :empty} ->
        :empty

      _busy ->
        {:error, :database_busy}
    end
  end

  @doc """
  Appends `text` to the stored queue in one IMMEDIATE transaction (spec 74
  BUGS-67): every window pops, appends and removes, so the edit is made against
  the row, never a view's copy.
  """
  @spec append_queued(String.t(), String.t()) ::
          {:ok, Conversation.t()} | {:error, :not_found | :database_busy}
  def append_queued(id, text) when is_binary(id) and is_binary(text),
    do: edit_queued(:append_queued, id, fn queued -> {:ok, queued ++ [text]} end)

  @doc """
  Removes the item at `index` only while it is still `expected` (spec 74
  BUGS-67) — another window may have popped or removed since the chip was
  drawn.
  """
  @spec remove_queued(String.t(), non_neg_integer(), String.t()) ::
          {:ok, Conversation.t()} | {:error, :stale | :not_found | :database_busy}
  def remove_queued(id, index, expected) when is_binary(id) and is_integer(index) do
    edit_queued(:remove_queued, id, fn queued ->
      if Enum.at(queued, index) == expected,
        do: {:ok, List.delete_at(queued, index)},
        else: {:error, :stale}
    end)
  end

  @doc "Puts `text` back at the head of the stored queue (spec 74 BUGS-67)."
  @spec requeue_head(String.t(), String.t()) ::
          {:ok, Conversation.t()} | {:error, :not_found | :database_busy}
  def requeue_head(id, text) when is_binary(id) and is_binary(text),
    do: edit_queued(:requeue_head, id, fn queued -> {:ok, [text | queued]} end)

  defp edit_queued(label, id, fun) do
    outcome =
      Repo.retry(label, fn ->
        Repo.transaction(
          fn ->
            with %Conversation{} = conversation <- Repo.get(Conversation, id),
                 {:ok, queued} <- fun.(conversation.queued || []) do
              {:ok, updated} =
                conversation |> Conversation.changeset(%{queued: queued}) |> Repo.update()

              {:ok, Repo.preload(updated, :project)}
            else
              nil -> {:error, :not_found}
              {:error, reason} -> {:error, reason}
            end
          end,
          mode: :immediate
        )
      end)

    case outcome do
      {:ok, {:ok, conversation}} ->
        broadcast(conversation.id, {:conversation_updated, conversation})
        {:ok, conversation}

      {:ok, {:error, reason}} ->
        {:error, reason}

      _busy ->
        {:error, :database_busy}
    end
  end

  ## Goals (spec 10 §19 — several at once)

  @goal_open ~w(active paused)

  @doc """
  Adds a goal to a conversation. `mode` is `"chat"` or `"swarm"` and decides how
  every run of this goal is started (spec 10 §7).

  `conversations.goal` stays as the denormalised newest open goal text so the
  breadcrumb, search and the prompt suffix keep working.
  """
  @spec add_goal(Conversation.t() | String.t(), String.t(), String.t()) ::
          {:ok, Goal.t()} | {:error, Ecto.Changeset.t()}
  def add_goal(conversation, text, mode \\ "chat")

  def add_goal(%Conversation{} = conversation, text, mode),
    do: add_goal(conversation.id, text, mode)

  def add_goal(conversation_id, text, mode) when is_binary(conversation_id) do
    attrs = %{
      conversation_id: conversation_id,
      text: String.trim(to_string(text)),
      mode: if(mode in ["chat", "swarm"], do: mode, else: "chat"),
      status: "active",
      inserted_at: now()
    }

    case %Goal{} |> Goal.changeset(attrs) |> Repo.insert() do
      {:ok, goal} ->
        sync_goal_text(conversation_id)
        broadcast(conversation_id, {:goals_updated, conversation_id})
        {:ok, goal}

      other ->
        other
    end
  end

  @doc "Every goal of a conversation, oldest first."
  def list_goals(conversation_id) do
    Repo.all(
      from(g in Goal, where: g.conversation_id == ^conversation_id, order_by: [asc: :inserted_at])
    )
  end

  @doc "The goals shown above the composer: active or paused, oldest first."
  def open_goals(conversation_id) do
    Repo.all(
      from(g in Goal,
        where: g.conversation_id == ^conversation_id and g.status in ^@goal_open,
        order_by: [asc: :inserted_at]
      )
    )
  end

  @doc "The newest open goal of a conversation (the one a bare `/goal` acts on)."
  def newest_goal(conversation_id) do
    conversation_id |> open_goals() |> List.last()
  end

  def get_goal(nil), do: nil
  def get_goal(id) when is_binary(id), do: Repo.get(Goal, id)

  @doc """
  This conversation's own goal.

  Spec 32 §5: a goal id arrives from the browser and can be stale — a row the
  user has since navigated away from — or simply belong to somebody else's
  conversation. Editing it would steer a run nobody is looking at.
  """
  @spec get_goal(String.t(), String.t()) :: Goal.t() | nil
  def get_goal(conversation_id, goal_id) when is_binary(conversation_id) and is_binary(goal_id),
    do: Repo.get_by(Goal, id: goal_id, conversation_id: conversation_id)

  def get_goal(_conversation_id, _goal_id), do: nil

  @spec update_goal(Goal.t(), map()) :: {:ok, Goal.t()} | {:error, Ecto.Changeset.t()}
  def update_goal(%Goal{} = goal, attrs) do
    case goal |> Goal.changeset(attrs) |> Repo.update() do
      {:ok, goal} ->
        sync_goal_text(goal.conversation_id)
        broadcast(goal.conversation_id, {:goals_updated, goal.conversation_id})
        {:ok, goal}

      other ->
        other
    end
  end

  @doc """
  The goal is reached: its run finished with `done` (spec 13 §10). A `done`
  goal is not an open goal any more, so the composer's goal bar disappears —
  the line on the run itself stays, as a finished goal.
  """
  @spec finish_goal(Goal.t()) :: {:ok, Goal.t()} | {:error, Ecto.Changeset.t()}
  def finish_goal(%Goal{} = goal),
    do: update_goal(goal, %{status: "done", finished_at: now()})

  @doc "Clears one goal (it disappears from the composer, its runs stay)."
  def clear_goal(%Goal{} = goal),
    do: update_goal(goal, %{status: "cleared", finished_at: now()})

  @doc "Remembers which run currently pursues this goal."
  def set_goal_run(%Goal{} = goal, run_id), do: update_goal(goal, %{run_id: run_id})

  # `conversations.goal` mirrors the newest open goal (or nil).
  # spec 55 T5: public (undocumented) so `Conversations.Writes.finish_turn/3` can settle a goal.
  # spec 60 T27: `broadcast: false` (inside a transaction) writes without
  # announcing and returns `{:ok, conversation | nil}` — the conversation when
  # the text changed — so the caller can announce it after the commit; an
  # invalid row rolls the transaction back. The default path keeps `:ok`.
  @doc false
  def sync_goal_text(conversation_id, opts \\ []) do
    text =
      case newest_goal(conversation_id) do
        nil -> nil
        goal -> goal.text
      end

    quiet? = opts[:broadcast] == false

    case Repo.get(Conversation, conversation_id) do
      nil ->
        if quiet?, do: {:ok, nil}, else: :ok

      %Conversation{goal: ^text} ->
        if quiet?, do: {:ok, nil}, else: :ok

      conversation when quiet? ->
        case conversation |> Conversation.changeset(%{goal: text}) |> Repo.update() do
          {:ok, c} -> {:ok, c}
          {:error, cs} -> Repo.rollback(cs)
        end

      conversation ->
        {:ok, _} = update(conversation, %{goal: text})
        :ok
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  ## Runs

  def list_runs(conversation_id) do
    Repo.all(
      from(r in Run, where: r.conversation_id == ^conversation_id, order_by: [desc: :started_at])
    )
  end

  def get_run!(id), do: Repo.get!(Run, id)

  @doc "The run, or `nil` when it has been deleted."
  @spec get_run(String.t() | nil) :: Run.t() | nil
  def get_run(nil), do: nil
  def get_run(id) when is_binary(id), do: Repo.get(Run, id)

  @doc "The status of a run without loading it, or `nil` when it is gone."
  @spec run_status(String.t()) :: String.t() | nil
  def run_status(id) do
    Run |> where([r], r.id == ^id) |> select([r], r.status) |> Repo.one()
  end

  def create_run(attrs) do
    case insert_run_row(attrs) do
      {:ok, run} ->
        broadcast_run_created(run)
        {:ok, run}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Inserts a run row without announcing it (spec 13 §11 A-4). A caller that
  creates several rows in one transaction broadcasts with
  `broadcast_run_created/1` once the transaction has committed, so nothing in
  the UI ever sees a run that a rollback took away again.
  """
  @spec insert_run_row(map()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def insert_run_row(attrs), do: %Run{} |> Run.changeset(attrs) |> Repo.insert()

  @doc "Announces a run that `insert_run_row/1` created."
  def broadcast_run_created(%Run{} = run) do
    broadcast(run.conversation_id, {:run_created, run})
    broadcast_run(run)
    :ok
  end

  def update_run(%Run{} = run, attrs) do
    case update_run_row(run, attrs) do
      {:ok, updated} ->
        broadcast(updated.conversation_id, {:run_updated, updated})
        {:ok, updated}

      error ->
        error
    end
  end

  @doc """
  Claims a plan gate (spec 60 T62).

  Writes `plan_state` only while it is still `nil`, so of two windows — or of a
  double click — exactly one gets `{:ok, 1}` and launches the implementation;
  everyone else gets `{:ok, 0}` and the plan reads as no longer open.
  """
  @spec claim_plan(String.t(), String.t()) :: {:ok, 0 | 1} | {:error, :database_busy}
  def claim_plan(run_id, state) when is_binary(run_id) and is_binary(state) do
    Repo.retry(:claim_plan, fn ->
      {n, _} =
        Repo.update_all(
          from(r in Run, where: r.id == ^run_id and is_nil(r.plan_state)),
          set: [plan_state: state]
        )

      {:ok, n}
    end)
  end

  @doc """
  The same write without the conversation announcement (spec 33 §4).

  `RunServer` writes a run on every token (`recompute_totals`) and announces it
  itself, from the dirty flush, *after* the node and delta events of the same
  slice — so announcing again from inside the write meant every subscriber
  re-rendered two or three times for one logical update. The sidebar's global
  status event still goes out immediately: it is the one thing that must not
  wait for a flush.
  """
  @spec update_run_row(Run.t(), map(), keyword()) ::
          {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def update_run_row(%Run{} = run, attrs, opts \\ []) do
    case run |> Run.changeset(attrs) |> Repo.update() do
      {:ok, updated} ->
        # The sidebar only cares about the status. A run is updated on every
        # token of every agent (`recompute_totals`), and each of those used to
        # cost every open LiveView six queries (spec 12 §11.2).
        # spec 60 T27: `broadcast: false` inside a transaction — the caller
        # announces the status after the commit (`broadcast_run_status/1`).
        if updated.status != run.status and Keyword.get(opts, :broadcast, true),
          do: broadcast_run(updated)

        {:ok, updated}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # spec 60 T27: the sidebar's status event, for a write made with `broadcast: false`.
  @doc false
  def broadcast_run_status(%Run{} = run), do: broadcast_run(run)

  ## Usage

  @doc """
  One row per run for the usage table: newest first, optionally limited to the
  last `days` days and capped at `limit` rows.

  Options: `:days` (default 30, `nil` for everything), `:limit` (default 50,
  `nil` for everything), `:before` — spec 74 EFFICIENCY-61: the
  `{started_at, id}` of the last row shown, for the next keyset page.
  """
  @spec usage_rows(keyword()) :: [map()]
  def usage_rows(opts \\ []) do
    Run
    |> usage_scope(opts)
    |> usage_before(Keyword.get(opts, :before))
    |> join(:inner, [r], c in Conversation, on: c.id == r.conversation_id)
    |> join(:left, [r, c], p in SwarmCode.Domain.Projects.Project, on: p.id == c.project_id)
    |> order_by([r], desc: r.started_at, desc: r.id)
    |> select([r, c, p], %{
      id: r.id,
      conversation_id: r.conversation_id,
      conversation: c.title,
      project: p.name,
      model: r.model,
      chat_model: c.chat_model,
      swarm_model: c.swarm_model,
      kind: r.kind,
      label: r.label,
      status: r.status,
      at: r.started_at,
      tokens_in: r.tokens_in,
      tokens_out: r.tokens_out,
      cost_usd: r.cost_usd
    })
    |> maybe_limit(Keyword.get(opts, :limit, 50))
    |> Repo.all()
  end

  @doc """
  Totals for the same window: `%{runs:, conversations:, tokens:, tokens_in:,
  tokens_out:, cost:, month_cost:, best_month_cost:}`.
  """
  @spec usage_summary(keyword()) :: map()
  def usage_summary(opts \\ []) do
    totals =
      Run
      |> usage_scope(opts)
      |> select([r], %{
        runs: count(r.id),
        conversations: count(r.conversation_id, :distinct),
        tokens_in: coalesce(sum(r.tokens_in), 0),
        tokens_out: coalesce(sum(r.tokens_out), 0),
        cost: sum(r.cost_usd)
      })
      |> Repo.one() || %{}

    totals =
      Map.merge(%{runs: 0, conversations: 0, tokens_in: 0, tokens_out: 0, cost: nil}, totals)

    Map.merge(totals, %{
      tokens: totals.tokens_in + totals.tokens_out,
      month_cost: month_cost(),
      best_month_cost: best_month_cost()
    })
  end

  defp usage_scope(query, opts) do
    case Keyword.get(opts, :days, 30) do
      nil ->
        query

      days ->
        since = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)
        where(query, [r], r.started_at >= ^since)
    end
  end

  # spec 74 EFFICIENCY-61: rows strictly after `{at, id}` in `started_at desc,
  # id desc` order (a NULL `started_at` sorts last).
  defp usage_before(query, nil), do: query

  defp usage_before(query, {nil, id}),
    do: where(query, [r], is_nil(r.started_at) and r.id < ^id)

  defp usage_before(query, {at, id}) do
    where(
      query,
      [r],
      r.started_at < ^at or (r.started_at == ^at and r.id < ^id) or is_nil(r.started_at)
    )
  end

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, n), do: limit(query, ^n)

  # Spend since the first of the current month, and the biggest month ever —
  # the fallback scale for the budget bar when no budget is set.
  defp month_cost do
    first =
      DateTime.utc_now()
      |> DateTime.to_date()
      |> Date.beginning_of_month()
      |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    Run |> where([r], r.started_at >= ^first) |> select([r], sum(r.cost_usd)) |> Repo.one()
  end

  # spec 68 T23: single SQL query with ORDER BY + LIMIT 1 instead of loading
  # every monthly aggregate into Elixir just to find the max.
  defp best_month_cost do
    Run
    |> group_by([r], fragment("strftime('%Y-%m', ?)", r.started_at))
    |> select([r], sum(r.cost_usd))
    |> order_by([r], desc: sum(r.cost_usd))
    |> limit(1)
    |> Repo.one()
  end

  ## Nodes

  @doc "One node by id, or nil (spec 40 §1.6)."
  @spec get_node(String.t() | nil) :: Node.t() | nil
  def get_node(nil), do: nil
  def get_node(id), do: Repo.get(Node, id)

  @doc """
  The direct children of a node in position order (spec 40 §1.6). By run as
  well as by parent (spec 51 §1.6): `parent_id` alone is a full table scan and
  a temporary sort; with the run the `{run_id, position}` index serves it.
  """
  @spec child_nodes(String.t(), String.t()) :: [Node.t()]
  def child_nodes(run_id, parent_id),
    do:
      Repo.all(
        from(n in Node,
          where: n.run_id == ^run_id and n.parent_id == ^parent_id,
          order_by: n.position
        )
      )

  @doc """
  The children of a node without their results (spec 73 T86): `op_type`,
  `status`, `title` and `position`, in position order — what a summary needs
  without the result column, which is most of a node row.
  """
  @spec child_ops_summary(String.t(), String.t()) :: [map()]
  def child_ops_summary(run_id, parent_id),
    do:
      Repo.all(
        from(n in Node,
          where: n.run_id == ^run_id and n.parent_id == ^parent_id,
          order_by: n.position,
          select: map(n, [:op_type, :status, :title, :position])
        )
      )

  @doc "The non-empty result of the last `op_type` child of a node, or nil (spec 73 T86)."
  @spec last_child_result(String.t(), String.t(), String.t()) :: String.t() | nil
  def last_child_result(run_id, parent_id, op_type),
    do:
      Repo.one(
        from(n in Node,
          where:
            n.run_id == ^run_id and n.parent_id == ^parent_id and n.op_type == ^op_type and
              not is_nil(n.result) and n.result != "",
          order_by: [desc: n.position],
          limit: 1,
          select: n.result
        )
      )

  def list_nodes(run_id) do
    Repo.all(from(n in Node, where: n.run_id == ^run_id, order_by: [asc: :position]))
  end

  @node_light_fields Node.__schema__(:fields) -- [:prompt, :result, :input]

  @doc """
  The first node of `run_id` (in position order) whose id or branch is
  `id_or_branch`, without its prompt, result and input — one narrow read
  instead of `list_nodes/1` plus a scan (spec 74 EFFICIENCY-49, workflow
  `integrate/1`).
  """
  @spec find_run_node(String.t(), String.t()) :: Node.t() | nil
  def find_run_node(run_id, id_or_branch) do
    Repo.one(
      from(n in Node,
        where: n.run_id == ^run_id and (n.id == ^id_or_branch or n.branch == ^id_or_branch),
        order_by: [asc: n.position],
        limit: 1,
        select: struct(n, ^@node_light_fields)
      )
    )
  end

  @doc """
  All nodes for the requested runs, keyed by run id in position order.

  `:full` is every column; `:light` (spec 51 §1.10) is the row as the UI keeps
  it — a tool op's `result` cut to 4 000 chars in SQL and its `input` dropped,
  the exact shape of `Node.light/1` (`hot_path_test.exs` holds the two
  together). Agents, workflow/research nodes and the ops whose result is
  rendered whole (`Node.whole_ops/0`) keep every field either way.
  """
  @spec list_nodes_for_runs([String.t()], :full | :light) :: %{String.t() => [Node.t()]}
  def list_nodes_for_runs(run_ids, shape \\ :full)

  def list_nodes_for_runs([], _shape), do: %{}

  def list_nodes_for_runs(run_ids, shape) when is_list(run_ids) and shape in [:full, :light] do
    grouped =
      from(n in Node,
        where: n.run_id in ^run_ids,
        order_by: [asc: n.run_id, asc: n.position]
      )
      |> node_shape(shape)
      |> Repo.all()
      |> Enum.group_by(& &1.run_id)

    Map.new(run_ids, &{&1, Map.get(grouped, &1, [])})
  end

  @doc """
  Spec 54 §3.1 (54a B2): the same rows as `list_nodes_for_runs/2`, but the `op`
  rows of `ops_run_ids` only — every other run yields its agent, workflow and
  research nodes.

  Ops are 89 % of a swarm run's rows (56 of 63) and are drawn only while the run
  is live or its card, tree or drawer is open, yet a window used to load and
  hold every one of them for every run of the conversation: 13.3 MB and
  0.5–0.8 s of SQLite per open on the reviewer's stressed lane. Almost all of
  that is the rows themselves — `:erts_debug.flat_size` counts a node at ~2.9 KB
  whatever its `result` is — so the rows are what a window must not keep.
  `list_nodes_for_runs([run_id], :light)` fetches one run's ops back on the
  click that shows them.
  """
  @spec list_nodes_for_runs([String.t()], [String.t()], :full | :light) ::
          %{String.t() => [Node.t()]}
  def list_nodes_for_runs([], _ops_run_ids, _shape), do: %{}

  def list_nodes_for_runs(run_ids, ops_run_ids, shape)
      when is_list(run_ids) and shape in [:full, :light] do
    with_ops = run_ids -- (run_ids -- List.wrap(ops_run_ids))

    if length(with_ops) == length(run_ids) do
      list_nodes_for_runs(run_ids, shape)
    else
      grouped =
        from(n in Node,
          where: n.run_id in ^run_ids,
          where: n.kind != "op" or n.run_id in ^with_ops,
          order_by: [asc: n.run_id, asc: n.position]
        )
        |> node_shape(shape)
        |> Repo.all()
        |> Enum.group_by(& &1.run_id)

      Map.new(run_ids, &{&1, Map.get(grouped, &1, [])})
    end
  end

  defp node_shape(query, :full), do: query

  # The literal list mirrors `Node.whole_ops/0`; SQLite's `substr` counts
  # characters on TEXT, matching `String.slice/3`. A nil `op_type` is cut like
  # any other tool op (`coalesce`), as `Node.light/1`'s guard does.
  #
  # spec 74 EFFICIENCY-1: the query selects every column but the two blobs, then
  # merges the cut ones. Without the explicit `select`, the generated SQL read
  # the full `result` and `input` next to the CASE columns (2.2–3.6× the bytes
  # through the NIF), and Ecto then dropped them.
  defp node_shape(query, :light) do
    from(n in query,
      select: struct(n, ^light_node_fields()),
      select_merge: %{
        result:
          fragment(
            "CASE WHEN ? = 'op' AND coalesce(?, '') NOT IN ('llm','submit_plan','write_spec') THEN substr(?, 1, 4000) ELSE ? END",
            n.kind,
            n.op_type,
            n.result,
            n.result
          ),
        input:
          fragment(
            "CASE WHEN ? = 'op' AND coalesce(?, '') NOT IN ('llm','submit_plan','write_spec') THEN NULL ELSE ? END",
            n.kind,
            n.op_type,
            n.input
          )
      }
    )
  end

  defp light_node_fields, do: Node.__schema__(:fields) -- [:result, :input]

  @doc """
  The window of one op's result an expanded op row shows (spec 74
  EFFICIENCY-27): the first `chars` characters (SQLite `substr`, like
  `String.slice/3`) and the stored size in bytes, read on demand so the
  light node the wire and the assigns carry can keep a preview only.
  `nil` when the node is gone.
  """
  @spec op_window(String.t(), pos_integer()) ::
          %{result: String.t() | nil, result_bytes: non_neg_integer()} | nil
  def op_window(op_id, chars \\ 4_000) when is_binary(op_id) do
    Repo.one(
      from(n in Node,
        where: n.id == ^op_id,
        select: %{
          result: fragment("substr(?, 1, ?)", n.result, ^chars),
          result_bytes: fragment("coalesce(octet_length(?), 0)", n.result)
        }
      )
    )
  end

  def insert_node(attrs), do: %Node{} |> Node.changeset(attrs) |> Repo.insert()

  def update_node(%Node{} = node, attrs), do: node |> Node.changeset(attrs) |> Repo.update()

  @doc """
  Writes the given columns of one node row (spec 51 §2.5): `{1, nil}` when the
  row exists, `{0, nil}` when it does not. Ecto casts the values through the
  schema's field types; the caller (`RunServer.normalize/1`) has already capped
  the text columns the way `Node.changeset/2` would.
  """
  @spec update_node_fields(String.t(), keyword()) :: {non_neg_integer(), nil}
  def update_node_fields(id, set) when is_binary(id) and is_list(set) do
    Repo.update_all(from(n in Node, where: n.id == ^id), set: set)
  end

  @doc """
  Everything one `RunServer` flush has to write, in one IMMEDIATE transaction
  (spec 54 §1.1, 54a A1).

  `inserts` are whole node attribute maps whose INSERT a busy database refused
  earlier, `updates` are `{node_id, set}` pairs of changed columns, `run_totals`
  is `{run, attrs}` or `nil`. Returns the run row as written (`{:ok, run | nil}`)
  or `{:error, :database_busy}` after `with_busy_retry/2` gave up — in which case
  nothing was written and the caller keeps its pending columns for the next
  flush. Before this, each of those was its own autocommit statement and its own
  acquisition of SQLite's single writer lock: 322 write statements per second
  under eight concurrent lanes, `UPDATE nodes` averaging 7 ms for a 0.3 ms
  statement, and a raise past `busy_timeout` that killed the run's sole state
  owner.
  """
  @spec flush_run_writes([map()], [{String.t(), keyword()}], {Run.t(), map()} | nil) ::
          {:ok, Run.t() | nil} | {:error, :database_busy | term()}
  def flush_run_writes(inserts, updates, run_totals) do
    # spec 60 T27: the sidebar's status event goes out after the commit, not
    # from inside a transaction a busy retry may still roll back.
    before =
      case run_totals do
        {run, _} -> run.status
        _ -> nil
      end

    result =
      Repo.retry(:flush_run_writes, fn ->
        Repo.transaction(
          fn ->
            Enum.each(inserts, fn attrs ->
              case insert_node(attrs) do
                {:ok, _} -> :ok
                {:error, cs} -> log_write_failure(inspect(cs.errors))
              end
            end)

            Enum.each(updates, fn {id, set} ->
              case update_node_fields(id, set) do
                {1, _} -> :ok
                {0, _} -> log_write_failure("node #{id} is not in the table")
              end
            end)

            case run_totals do
              nil ->
                nil

              {run, attrs} ->
                case update_run_row(run, attrs, broadcast: false) do
                  {:ok, updated} ->
                    updated

                  {:error, cs} ->
                    log_write_failure(inspect(cs.errors))
                    nil
                end
            end
          end,
          mode: :immediate
        )
      end)

    case result do
      {:ok, %Run{status: status} = updated} when status != before -> broadcast_run(updated)
      _ -> :ok
    end

    result
  end

  defp log_write_failure(reason), do: Logger.error("swarm_code db write failed: #{reason}")

  @doc "Agent nodes of `conversation_id` that still have an unmerged branch."
  def agent_branches(conversation_id) do
    # spec 74 EFFICIENCY-32: the Branches tab shows the name and the stat; the
    # prompt and result stayed in `@changes` for nothing. Merge/Discard re-read
    # the full node (`own_branch`). At most 100; `agent_branch_count/1` counts all.
    Repo.all(
      from(n in agent_branch_query(conversation_id),
        order_by: [desc: n.started_at],
        limit: 100,
        select: map(n, [:id, :run_id, :branch, :changes_stat, :started_at])
      )
    )
  end

  @doc "How many unintegrated agent branches the conversation has (spec 74 EFFICIENCY-32)."
  @spec agent_branch_count(String.t()) :: non_neg_integer()
  def agent_branch_count(conversation_id),
    do: Repo.aggregate(agent_branch_query(conversation_id), :count)

  defp agent_branch_query(conversation_id) do
    from(n in Node,
      join: r in Run,
      on: r.id == n.run_id,
      where:
        r.conversation_id == ^conversation_id and n.kind == "agent" and not is_nil(n.branch) and
          n.integrated == false
    )
  end

  @doc """
  An unintegrated agent branch of this conversation *in this project*.

  Spec 32 §4: branch names are not unique across projects, and the name arrives
  from the browser. Both ids come from the server.
  """
  @spec unintegrated_branch(String.t(), String.t(), String.t()) :: Node.t() | nil
  def unintegrated_branch(conversation_id, project_id, branch)
      when is_binary(conversation_id) and is_binary(project_id) and is_binary(branch) do
    Repo.one(
      from(n in Node,
        join: r in Run,
        on: r.id == n.run_id,
        join: c in Conversation,
        on: c.id == r.conversation_id,
        where:
          c.id == ^conversation_id and c.project_id == ^project_id and n.kind == "agent" and
            n.branch == ^branch and n.integrated == false,
        limit: 1
      )
    )
  end

  def unintegrated_branch(_conversation_id, _project_id, _branch), do: nil

  @doc "Marks one node integrated — not every node that happens to share a branch name."
  @spec mark_node_integrated(String.t()) :: :ok
  def mark_node_integrated(node_id) when is_binary(node_id) do
    Repo.update_all(from(n in Node, where: n.id == ^node_id), set: [integrated: true])
    :ok
  end

  def unintegrated_run_branch(run_id, branch) do
    Repo.one(
      from(n in Node,
        where:
          n.run_id == ^run_id and n.kind == "agent" and n.branch == ^branch and
            n.integrated == false,
        limit: 1
      )
    )
  end

  @doc """
  Boot marking (spec 12 §2): nothing survives the BEAM going away, so every run
  the database still believes is alive is settled here.

  A workflow run keeps its journal and comes back **resumable**: `running`,
  `waiting_user` and manually paused workflow runs become `interrupted` and their
  `workflow_runs` row says why, so the pause card, the transcript card and the
  dashboard all offer `Resume` (spec 09 §4.1). Infrastructure- and budget-paused
  runs are left alone — the watchdog and the budget dialog own those. Every other
  run is simply `stopped`, and every in-flight node (agent or op) is stopped too.

  Returns the number of workflow runs that were interrupted, which the boot toast
  counts.
  """
  @spec mark_interrupted() :: {:ok, non_neg_integer()}
  def mark_interrupted do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    wf_ids = resumable_workflow_run_ids()

    if wf_ids != [] do
      Repo.update_all(from(r in Run, where: r.id in ^wf_ids),
        set: [status: "interrupted", finished_at: now, interrupted: true]
      )

      Repo.update_all(
        from(w in SwarmCode.Domain.Workflows.Run, where: w.run_id in ^wf_ids),
        set: [
          pause_kind: "restart",
          pause_message: "Interrupted by an app restart",
          updated_at: now
        ]
      )
    end

    # Spec 45 §5.2: a non-workflow run paused by the user is as alive as a
    # running one — it comes back resumable too.
    Repo.update_all(
      from(r in Run,
        where: r.status == "running" or (r.status == "paused" and r.kind != "workflow")
      ),
      set: [status: "stopped", finished_at: now, interrupted: true]
    )

    # spec 55 T15 (55a A6): derived, so a new status can never be missed again.
    live_statuses = Node.statuses() -- ~w(done failed stopped)

    Repo.update_all(
      from(n in Node,
        where: n.status in ^live_statuses
      ),
      set: [status: "stopped", detail: "interrupted by restart", finished_at: now]
    )

    {:ok, length(wf_ids)}
  end

  @doc """
  Spec 12 §7: a settled node without an end has no length, and the Timeline
  would draw it as still running since its start. Its last write is the
  honest end (spec 68 T25).

  spec 74 EFFICIENCY-23: a legacy repair — a full `nodes` scan that finds
  nothing after its first run — so it left `mark_interrupted/0` (the window's
  critical path) for `Bootstrap`'s deferred task. Idempotent; no index.
  """
  @spec repair_unfinished_nodes() :: {:ok, non_neg_integer()}
  def repair_unfinished_nodes do
    {count, _} =
      Repo.update_all(
        from(n in Node,
          where: is_nil(n.finished_at) and n.status in ["done", "failed", "stopped"],
          update: [set: [finished_at: n.updated_at]]
        ),
        []
      )

    {:ok, count}
  end

  # Workflow runs the database still believes are alive. Nothing runs at boot,
  # so "no Runner" is a given.
  defp resumable_workflow_run_ids do
    Repo.all(
      from(r in Run,
        join: w in SwarmCode.Domain.Workflows.Run,
        on: w.run_id == r.id,
        where:
          r.kind == "workflow" and
            (r.status in ["running", "waiting_user"] or
               (r.status == "paused" and (is_nil(w.pause_kind) or w.pause_kind == "manual"))),
        select: r.id
      )
    )
  end

  def run_totals(run_id) do
    totals =
      Repo.one(
        from(n in Node,
          where: n.run_id == ^run_id and n.kind == "agent",
          select: %{
            tokens_in: sum(n.tokens_in),
            tokens_out: sum(n.tokens_out),
            cost_usd: sum(n.cost_usd)
          }
        )
      )

    %{
      tokens_in: totals[:tokens_in] || 0,
      tokens_out: totals[:tokens_out] || 0,
      cost_usd: totals[:cost_usd]
    }
  end

  @doc """
  The user's own messages from *behind* a compaction floor, newest first
  (spec 66 T17).

  `list_history_window/2` stops at the floor, so everything the user actually
  asked for is only in the summary, in whatever form the compactor left it. This
  is the companion read that puts their words back: `position < before_position`,
  user role, non-empty, not superseded, newest first, bounded by `byte_budget`
  in content bytes and by a row limit derived from it.

  spec 67 T9 (B35): a slash command is not one of the user's requests — it is an
  instruction to the harness — so `/%` rows are left out. Quoted back at the
  model they read as orders, and the synthetic `/compact` of an automatic
  compaction was never typed by anyone.
  """
  @spec list_user_messages_before(String.t(), integer(), non_neg_integer()) :: [Message.t()]
  def list_user_messages_before(conversation_id, before_position, byte_budget)
      when is_binary(conversation_id) and is_integer(before_position) do
    byte_budget = max(byte_budget, 0)
    row_limit = min(div(byte_budget, 16) + 1, 200)

    rows =
      Repo.all(
        from(m in Message,
          where:
            m.conversation_id == ^conversation_id and m.position < ^before_position and
              m.role == "user" and m.content != "" and is_nil(m.superseded_at) and
              not like(m.content, "/%"),
          order_by: [desc: m.position, desc: m.inserted_at],
          limit: ^row_limit,
          select: struct(m, ^@history_fields)
        )
      )

    # spec 68 T22: prepend + reverse to avoid O(n^2) list append
    {kept, _bytes} =
      Enum.reduce_while(rows, {[], 0}, fn m, {kept, bytes} ->
        bytes = bytes + byte_size(m.content || "")

        if bytes > byte_budget,
          do: {:halt, {kept, bytes}},
          else: {:cont, {[m | kept], bytes}}
      end)

    Enum.reverse(kept)
  end

  def list_user_messages_before(_conversation_id, _before_position, _byte_budget), do: []

  # -- spec 70 D5: FTS5 cross-session message search --------------------------

  @doc """
  Full-text search over message content. Returns conversations whose
  messages match `query`, best match first, one entry per conversation, with a
  snippet of its best-matching message. Limited to `limit` results (default 20).
  """
  # spec 70 D5
  @spec search(String.t(), keyword()) :: [
          %{
            conversation_id: String.t(),
            title: String.t(),
            snippet: String.t(),
            updated_at: String.t() | nil
          }
        ]
  def search(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    safe_q = sanitize_fts(query)

    if safe_q == "" do
      []
    else
      # spec 74 BUGS-43: one row per conversation in SQL. The spec 70 D5
      # over-fetch (4x, deduplicated in Elixir) let one chatty conversation
      # fill every slot. SQLite's bare-column rule: with MIN() in the select
      # list, `messages_fts.rowid` comes from the best-ranked row of the group.
      # spec 73 T38: an edited-and-resent turn is superseded and excluded.
      winners_sql = """
      SELECT m.conversation_id, c.title, c.updated_at, messages_fts.rowid,
             MIN(messages_fts.rank) AS r
      FROM messages_fts
      JOIN messages m ON m.rowid = messages_fts.rowid
      JOIN conversations c ON c.id = m.conversation_id
      WHERE messages_fts MATCH ?1
        AND c.research_id IS NULL
        AND m.superseded_at IS NULL
      GROUP BY m.conversation_id
      ORDER BY r
      LIMIT ?2
      """

      with {:ok, %{rows: [_ | _] = rows}} <- Repo.query(winners_sql, [safe_q, limit]) do
        snippets = search_snippets(safe_q, Enum.map(rows, &Enum.at(&1, 3)))

        Enum.map(rows, fn [id, title, updated_at, rowid, _rank] ->
          %{
            conversation_id: id,
            title: title || "Untitled",
            snippet: Map.get(snippets, rowid) || "",
            updated_at: updated_at
          }
        end)
      else
        _ -> []
      end
    end
  end

  # spec 73 T37/T39: the excerpt is FTS5's own `snippet()` — computed in SQL
  # over the tokens, so `m.content` never crosses the wire. snippet() cannot
  # ride the GROUP BY above, so it runs over the winning rows only.
  defp search_snippets(safe_q, rowids) do
    placeholders = Enum.map_join(2..(length(rowids) + 1)//1, ", ", &"?#{&1}")

    sql = """
    SELECT messages_fts.rowid, snippet(messages_fts, 0, '', '', '...', 20)
    FROM messages_fts
    WHERE messages_fts MATCH ?1 AND messages_fts.rowid IN (#{placeholders})
    """

    case Repo.query(sql, [safe_q | rowids]) do
      {:ok, %{rows: rows}} -> Map.new(rows, fn [rowid, snippet] -> {rowid, snippet} end)
      _ -> %{}
    end
  end

  # spec 74 BUGS-43: unicode61 indexes `workspace_live.ex` as `workspace live
  # ex`, so each typed word becomes the phrase of its word runs
  # (`"workspace_live ex"`, `"SwarmCode Engine"`, `"api v1"`), and the last
  # phrase is a prefix match for as-you-type search (`"helpe"*`).
  defp sanitize_fts(query) do
    phrases =
      query
      |> to_string()
      |> String.split()
      |> Enum.map(fn word ->
        word |> String.replace(~r/[^\w]+/u, " ") |> String.trim()
      end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&("\"" <> &1 <> "\""))

    case phrases do
      [] -> ""
      phrases -> Enum.join(phrases, " ") <> "*"
    end
  end
end
