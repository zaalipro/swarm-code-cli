defmodule SwarmCode.Domain.Storage do
  @moduledoc """
  What SwarmCode's own data costs, and how to get rid of the part that is spent
  (spec 49).

  Measured on the owner's production database (spec 49 §1): `nodes.result` — the
  text every tool call returned — was **59.5 %** of the whole file, and
  `messages.content`, the thing the user actually reads, was **0.6 %**. Almost
  all of a SwarmCode database is agent exhaust, which is why the headline
  operation here is not "delete sessions" but the payload prune: keep every
  transcript, every node row, every token and cost figure, and drop the four
  columns that carry the exhaust.

  Everything in this module is confined to the app's own storage: the SQLite
  file at `Repo.config()[:database]` and the research directories under
  `SwarmCode.Domain.Research.root_dir/0`. It never reads or writes a project file,
  `.swarm_code/`, a worktree, or another harness's folder.

  Measurement is asynchronous by design. A grouped scan of `nodes` costs about
  1 s warm and 5 s cold on a 1.5 GB database (spec 49 §1), so callers run
  `overview/0` and `sessions/1` in a task and take the result over PubSub.
  """

  import Ecto.Query, warn: false

  alias SwarmCode.Domain.Checkpoints.Checkpoint
  alias SwarmCode.Domain.Conversations
  alias SwarmCode.Domain.Conversations.{Conversation, Message, Node, Run}
  alias SwarmCode.Domain.Engine
  alias SwarmCode.Domain.Repo
  alias SwarmCode.Domain.Research
  alias SwarmCode.Domain.Settings
  alias SwarmCode.Domain.Workflows.JournalEntry
  alias SwarmCode.Domain.Workflows.Run, as: WorkflowRun

  require Logger

  @topic "storage"
  @finished ~w(done failed stopped)
  # Spec 49 §1.5: one transaction per batch, so a cleanup of a million rows
  # never holds the write lock long enough to make a live agent wait.
  @batch 500
  @run_batch 200
  # Spec 49 §1.7: VACUUM writes a second copy of the file before it swaps.
  @vacuum_headroom 2

  # Test seam for the sweep's transaction paths (mission storage-safety): an
  # arity-1 function set as `:storage_transaction_seam` is called with
  # `{step, ids, calls}` before each transaction and may return
  # `{:error, reason}` to force the `{:error}` branch without touching the
  # database. `calls` counts prior transactions of the same step. Absent, the
  # seam is a no-op.
  defp transaction_seam(step, ids, calls) do
    case Application.get_env(:swarm_code_daemon, :storage_transaction_seam) do
      fun when is_function(fun, 1) -> fun.({step, ids, calls})
      _ -> :ok
    end
  end

  defp with_seam(step, ids, calls, fun) do
    case transaction_seam(step, ids, calls) do
      {:error, reason} ->
        send(self(), {:storage_seam_forced, step, ids, calls, reason})
        {:error, reason}

      _ ->
        Repo.transaction(fun)
    end
  rescue
    e ->
      send(self(), {:storage_seam_forced, step, ids, calls, e})
      reraise e, __STACKTRACE__
  end

  @type selection :: map()
  @type plan :: map()

  # ------------------------------------------------------- the byte fragments

  # `Node`'s four payload columns (spec 49 §1.5). `error` and `changes_stat`
  # are deliberately not here — 40 KB and 405 B in the measured database, and
  # they are what a failed run is read for.
  defmacrop node_bytes(n) do
    quote do
      fragment(
        "length(CAST(COALESCE(?,'') AS BLOB)) + length(CAST(COALESCE(?,'') AS BLOB)) + length(CAST(COALESCE(?,'') AS BLOB)) + length(CAST(COALESCE(?,'') AS BLOB))",
        unquote(n).result,
        unquote(n).input,
        unquote(n).prompt,
        unquote(n).detail
      )
    end
  end

  defmacrop msg_bytes(m) do
    quote do
      fragment(
        "length(CAST(COALESCE(?,'') AS BLOB)) + length(CAST(COALESCE(?,'') AS BLOB))",
        unquote(m).content,
        unquote(m).reasoning
      )
    end
  end

  defmacrop col_bytes(c) do
    quote do: fragment("length(CAST(COALESCE(?,'') AS BLOB))", unquote(c))
  end

  # ------------------------------------------------------------------- topic

  @doc "The progress topic of a running cleanup (spec 49 §1.5)."
  @spec topic() :: String.t()
  def topic, do: @topic

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: SwarmCode.Domain.PubSub.subscribe(SwarmCode.Domain.PubSub, @topic)

  defp broadcast(message),
    do: SwarmCode.Domain.PubSub.broadcast(SwarmCode.Domain.PubSub, @topic, message)

  # ------------------------------------------------------------ sizes on disk

  @db_key {__MODULE__, :database}

  @doc """
  The SQLite file this repo has open: `PRAGMA database_list`'s `main` when it
  is a file (a repo started on a path), else the file the guarded repo's
  launcher recorded (its connections open a VFS name, `/swarm-binding`), else
  the configured path.

  cli74 F42: it read `Repo.config()[:database]`, which the guarded repo never
  carries, so Storage said `0 B on disk` and `df` measured the working
  directory (found in the sandbox).
  """
  @spec db_path() :: String.t()
  def db_path do
    main = main_file()

    cond do
      is_binary(main) and File.regular?(main) -> main
      is_binary(path = :persistent_term.get(@db_key, nil)) -> path
      true -> Repo.config()[:database] |> to_string()
    end
  end

  defp main_file do
    case Repo.query("PRAGMA database_list", [], log: false) do
      {:ok, %{rows: rows}} ->
        Enum.find_value(rows, fn
          [_seq, "main", file | _] when is_binary(file) -> file
          _ -> nil
        end)

      _ ->
        nil
    end
  rescue
    # No repo is running (a launcher that stopped): nothing is open.
    _ -> nil
  end

  @doc false
  # The guarded repo's launcher: the file its pool opens (nil when it stops).
  @spec put_db_path(String.t() | nil) :: :ok
  def put_db_path(path) when is_binary(path), do: :persistent_term.put(@db_key, path)

  def put_db_path(nil) do
    _ = :persistent_term.erase(@db_key)
    :ok
  end

  @doc "The bytes the database occupies: the file, its write-ahead log and its shared index."
  @spec file_bytes() :: %{db: non_neg_integer(), wal: non_neg_integer(), shm: non_neg_integer()}
  def file_bytes do
    path = db_path()
    %{db: size_of(path), wal: size_of(path <> "-wal"), shm: size_of(path <> "-shm")}
  end

  defp size_of(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end

  @doc """
  Bytes SQLite is holding for reuse: `freelist_count × page_size`.

  A **floor**, and the UI says so: pruning also frees space *inside* pages, and
  a measured VACUUM returned 614 MB where the freelist claimed 348 (spec 49 §1).
  """
  @spec reclaimable_bytes() :: non_neg_integer()
  def reclaimable_bytes, do: pragma("freelist_count") * pragma("page_size")

  defp pragma(name) do
    case Ecto.Adapters.SQL.query(Repo, "PRAGMA #{name}", []) do
      {:ok, %{rows: [[n]]}} when is_integer(n) -> n
      _ -> 0
    end
  rescue
    _ -> 0
  end

  @doc "Free bytes on the volume the database lives on, or nil when `df` cannot say."
  @spec free_disk_bytes() :: non_neg_integer() | nil
  def free_disk_bytes do
    case System.cmd("df", ["-k", Path.dirname(db_path())], stderr_to_stdout: true) do
      {out, 0} -> out |> String.split("\n", trim: true) |> Enum.at(1) |> available_kb()
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp available_kb(line) when is_binary(line) do
    with kb when is_binary(kb) <- line |> String.split(~r/\s+/, trim: true) |> Enum.at(3),
         {n, _} <- Integer.parse(kb) do
      n * 1024
    else
      _ -> nil
    end
  end

  defp available_kb(_), do: nil

  @doc "The research directories under `Research.root_dir/0`: how many and how big."
  @spec research_dir_bytes() :: %{count: non_neg_integer(), bytes: non_neg_integer()}
  def research_dir_bytes do
    root = Research.root_dir()

    case File.ls(root) do
      {:ok, entries} ->
        Enum.reduce(entries, %{count: 0, bytes: 0}, fn entry, acc ->
          %{acc | count: acc.count + 1, bytes: acc.bytes + dir_bytes(Path.join(root, entry))}
        end)

      _ ->
        %{count: 0, bytes: 0}
    end
  end

  # spec 60 T28: `lstat`, and a symlink weighs nothing — a link to `/` in the
  # research dir used to walk the disk on every Settings mount.
  @doc false
  def dir_bytes(path) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} ->
        0

      {:ok, %{type: :regular, size: size}} ->
        size

      {:ok, %{type: :directory}} ->
        case File.ls(path) do
          {:ok, entries} -> Enum.reduce(entries, 0, &(&2 + dir_bytes(Path.join(path, &1))))
          _ -> 0
        end

      _ ->
        0
    end
  end

  # -------------------------------------------------------------- the overview

  @doc """
  Everything the Storage section shows (spec 49 §1.2).

  `kinds` sums the columns each kind owns, so the segments add up to what the
  tables hold — deliberately less than the file, because indexes, page overhead
  and the freelist belong to no kind.
  """
  @spec overview() :: map()
  def overview do
    files = file_bytes()
    dirs = research_dir_bytes()

    messages = agg(from(m in Message, select: {count(m.id), sum(msg_bytes(m))}))
    payloads = agg(from(n in Node, select: {count(n.id), sum(node_bytes(n))}))

    checkpoints =
      agg(from(c in Checkpoint, select: {count(c.id), sum(col_bytes(c.previous_content))}))

    journals = agg(from(j in JournalEntry, select: {count(j.id), sum(col_bytes(j.result))}))

    {research_count, research_bytes} =
      agg(
        from(r in Research.Research,
          select: {count(r.id), sum(col_bytes(r.summary) + col_bytes(r.interpretation))}
        )
      )

    %{
      db_bytes: files.db,
      wal_bytes: files.wal,
      total_bytes: files.db + files.wal + files.shm,
      reclaimable_bytes: reclaimable_bytes(),
      free_disk_bytes: free_disk_bytes(),
      # spec 72 D6: isolation directory stats.
      isolation_dirs: count_isolation_dirs(),
      isolation_bytes: isolation_disk_usage(),
      sessions: Repo.aggregate(visible_conversations(), :count, :id),
      kinds: [
        kind(:sessions, "Sessions", messages),
        kind(:agents, "Agent details", payloads),
        kind(:checkpoints, "Rewind snapshots", checkpoints),
        kind(:workflows, "Workflow journals", journals),
        kind(:research, "Research", {research_count, research_bytes + dirs.bytes})
      ],
      measured_at: DateTime.utc_now()
    }
  end

  defp agg(query) do
    case Repo.one(query) do
      {count, bytes} -> {count || 0, bytes || 0}
      _ -> {0, 0}
    end
  end

  defp kind(key, label, {count, bytes}), do: %{key: key, label: label, count: count, bytes: bytes}

  # -------------------------------------------------------------- the sessions

  @doc """
  Every visible session with what it weighs (spec 49 §1.3).

  Four grouped scans, joined in Elixir — never one query per session. Sessions a
  research owns (`research_id`) are absent: they are hidden from every sidebar
  and are accounted under the `:research` kind instead.

  Options: `:sort` — `:bytes` (default, heaviest first), `:date`, `:title`.
  """
  @spec sessions(keyword()) :: [map()]
  def sessions(opts \\ []) do
    conversations = Repo.all(from(c in visible_conversations(), preload: [:project]))

    runs =
      Repo.all(
        from(r in Run,
          left_join: n in Node,
          on: n.run_id == r.id,
          group_by: r.conversation_id,
          select: {r.conversation_id, count(r.id, :distinct), sum(node_bytes(n))}
        )
      )
      |> Map.new(fn {id, runs, bytes} -> {id, {runs || 0, bytes || 0}} end)

    messages =
      Repo.all(
        from(m in Message,
          group_by: m.conversation_id,
          select: {m.conversation_id, count(m.id), sum(msg_bytes(m))}
        )
      )
      |> Map.new(fn {id, count, bytes} -> {id, {count || 0, bytes || 0}} end)

    checkpoints =
      Repo.all(
        from(c in Checkpoint,
          group_by: c.conversation_id,
          select: {c.conversation_id, sum(col_bytes(c.previous_content))}
        )
      )
      |> Map.new(fn {id, bytes} -> {id, bytes || 0} end)

    journals =
      Repo.all(
        from(j in JournalEntry,
          join: r in Run,
          on: r.id == j.run_id,
          group_by: r.conversation_id,
          select: {r.conversation_id, sum(col_bytes(j.result))}
        )
      )
      |> Map.new(fn {id, bytes} -> {id, bytes || 0} end)

    running = MapSet.new(running_conversation_ids())
    open = MapSet.new(open_conversation_ids())

    conversations
    |> Enum.map(fn c ->
      {run_count, run_bytes} = Map.get(runs, c.id, {0, 0})
      {message_count, message_bytes} = Map.get(messages, c.id, {0, 0})
      running? = MapSet.member?(running, c.id)
      open? = MapSet.member?(open, c.id)
      pinned? = c.pinned_at != nil

      %{
        id: c.id,
        title: c.title,
        project: (c.project && c.project.name) || "No project",
        project_id: c.project_id,
        updated_at: c.updated_at,
        last_seen_at: c.last_seen_at,
        messages: message_count,
        runs: run_count,
        bytes:
          run_bytes + message_bytes + Map.get(checkpoints, c.id, 0) + Map.get(journals, c.id, 0),
        running?: running?,
        open?: open?,
        pinned?: pinned?,
        deletable?: not running? and not open?,
        reason: reason(running?, open?, pinned?)
      }
    end)
    |> sort_sessions(opts[:sort] || :bytes)
  end

  defp reason(true, _open, _pinned), do: :running
  defp reason(_running, true, _pinned), do: :open
  defp reason(_running, _open, true), do: :pinned
  defp reason(_running, _open, _pinned), do: nil

  defp sort_sessions(sessions, :date),
    do: Enum.sort_by(sessions, & &1.updated_at, {:desc, DateTime})

  defp sort_sessions(sessions, :title),
    do: Enum.sort_by(sessions, &String.downcase(&1.title || ""))

  defp sort_sessions(sessions, _bytes), do: Enum.sort_by(sessions, & &1.bytes, :desc)

  defp visible_conversations, do: from(c in Conversation, where: is_nil(c.research_id))

  @doc "Ids of the conversations that have a run live right now (the Registry, not a column)."
  @spec running_conversation_ids() :: [String.t()]
  def running_conversation_ids do
    case Engine.running_run_ids() do
      [] ->
        []

      ids ->
        Repo.all(from(r in Run, where: r.id in ^ids, distinct: true, select: r.conversation_id))
    end
  end

  @doc "Ids of the conversations open in a window right now (spec 49 §4.2)."
  @spec open_conversation_ids() :: [String.t()]
  def open_conversation_ids, do: SwarmCode.Domain.UIState.open_conversation_ids()

  # --------------------------------------------------------------- the presets

  @presets [
    %{
      key: "older_30",
      title: "Delete sessions older than 30 days",
      note: "everything they hold goes with them",
      icon: "hero-calendar-days",
      selection: %{older_than_days: 30}
    },
    %{
      key: "keep_14",
      title: "Keep only the last 2 weeks",
      note: "the same cut, drawn tighter",
      icon: "hero-scissors",
      selection: %{older_than_days: 14}
    },
    %{
      key: "prune_14",
      title: "Prune agent details older than 14 days",
      note: "keeps every transcript, token and cost",
      icon: "hero-sparkles",
      selection: %{prune_days: 14}
    },
    %{
      key: "checkpoints_30",
      title: "Delete rewind snapshots older than 30 days",
      note: "you can no longer rewind those runs",
      icon: "hero-arrow-uturn-left",
      selection: %{checkpoint_days: 30}
    },
    %{
      key: "vacuum",
      title: "Reclaim disk space",
      note: "compacts the file; deletes nothing",
      icon: "hero-arrows-pointing-in",
      selection: %{vacuum: true}
    }
  ]

  @doc "The one-click cleanups of the Quick tab (spec 49 §3)."
  @spec presets() :: [map()]
  def presets, do: @presets

  @doc "Every preset with the plan it would run (spec 49 §3), measured once."
  @spec previews([map()] | nil) :: [map()]
  def previews(sessions \\ nil) do
    sessions = sessions || sessions()

    for preset <- @presets do
      Map.put(preset, :plan, plan(preset.selection, sessions))
    end
  end

  # ------------------------------------------------------------------ the plan

  @doc """
  What a selection would delete (spec 49 §1.4): counts, bytes, and what is
  skipped and why.

  The resolved **session ids** are carried — they are the user's explicit
  choice, and there are tens of them. The checkpoint, journal and node sets are
  not: they can be hundreds of thousands of rows, so the plan carries their
  cutoff and the execution re-resolves them in batches.
  """
  @spec plan(selection(), [map()] | nil) :: plan()
  def plan(selection, sessions \\ nil) do
    sessions = sessions || sessions()
    now = DateTime.utc_now()

    {ids, skipped} = resolve_sessions(selection, sessions, now)
    by_id = Map.new(sessions, &{&1.id, &1})
    session_bytes = Enum.reduce(ids, 0, &(&2 + Map.fetch!(by_id, &1).bytes))

    prune_days = day_opt(selection[:prune_days])
    checkpoint_days = day_opt(selection[:checkpoint_days])
    journal_days = day_opt(selection[:journal_days])
    {research_ids, research_bytes} = resolve_research(selection, now)

    {prune_runs, prune_bytes} = measure(prunable_runs(prune_days, ids, now), :runs)

    {checkpoints, checkpoint_bytes} =
      measure(prunable_checkpoints(checkpoint_days, ids, now), :cp)

    {journals, journal_bytes} = measure(prunable_journals(journal_days, ids, now), :journal)

    items =
      [
        item(:sessions, "Sessions", length(ids), session_bytes),
        item(:payloads, "Runs with their details pruned", prune_runs, prune_bytes),
        item(:checkpoints, "Rewind snapshots", checkpoints, checkpoint_bytes),
        item(:journals, "Workflow journal rows", journals, journal_bytes),
        item(:research, "Research reports", length(research_ids), research_bytes)
      ]
      |> Enum.reject(&(&1.count == 0))

    %{
      items: items,
      skipped: skipped,
      session_ids: ids,
      prune_days: prune_days,
      checkpoint_days: checkpoint_days,
      journal_days: journal_days,
      research_ids: research_ids,
      total_count: Enum.reduce(items, 0, &(&2 + &1.count)),
      total_bytes: Enum.reduce(items, 0, &(&2 + &1.bytes)),
      vacuum: selection[:vacuum] == true,
      # spec 60 T21: the execution re-checks "pinned" with the same answer.
      include_pinned: selection[:include_pinned] == true,
      planned_at: now
    }
  end

  defp item(key, label, count, bytes), do: %{key: key, label: label, count: count, bytes: bytes}

  defp day_opt(n) when is_integer(n) and n >= 0, do: n

  defp day_opt(n) when is_binary(n) do
    case Integer.parse(n) do
      {days, _} when days >= 0 -> days
      _ -> nil
    end
  end

  defp day_opt(_), do: nil

  defp cutoff(days, now), do: DateTime.add(now, -days * 86_400, :second)

  # Spec 49 §4: running, open and (unless explicitly ticked) pinned sessions are
  # never in a plan. The reason travels with the row so the review can say it.
  defp resolve_sessions(selection, sessions, now) do
    include_pinned? = selection[:include_pinned] == true

    selection
    |> candidates(sessions, now)
    |> Enum.reduce({[], []}, fn session, {ids, skipped} ->
      cond do
        session.running? -> {ids, [skip(session, :running) | skipped]}
        session.open? -> {ids, [skip(session, :open) | skipped]}
        session.pinned? and not include_pinned? -> {ids, [skip(session, :pinned) | skipped]}
        true -> {[session.id | ids], skipped}
      end
    end)
    |> then(fn {ids, skipped} -> {Enum.reverse(ids), Enum.reverse(skipped)} end)
  end

  defp skip(session, reason),
    do: %{id: session.id, title: session.title, bytes: session.bytes, reason: reason}

  defp candidates(selection, sessions, now) do
    explicit = MapSet.new(List.wrap(selection[:session_ids]))
    older = day_opt(selection[:older_than_days])
    empty? = selection[:empty_sessions] == true

    Enum.filter(sessions, fn s ->
      MapSet.member?(explicit, s.id) or
        (older != nil and DateTime.compare(s.updated_at, cutoff(older, now)) == :lt) or
        (empty? and s.messages == 0 and s.runs == 0)
    end)
  end

  defp resolve_research(selection, now) do
    explicit = List.wrap(selection[:research_ids])
    days = day_opt(selection[:research_days])

    query =
      cond do
        explicit != [] and days != nil ->
          from(r in Research.Research,
            where:
              r.id in ^explicit or
                (r.status in @finished and r.inserted_at < ^cutoff(days, now))
          )

        explicit != [] ->
          from(r in Research.Research, where: r.id in ^explicit)

        days != nil ->
          from(r in Research.Research,
            where: r.status in @finished and r.inserted_at < ^cutoff(days, now)
          )

        true ->
          nil
      end

    if query do
      rows = Repo.all(from(r in query, select: {r.id, r.summary, r.interpretation}))

      bytes =
        Enum.reduce(rows, 0, fn {id, summary, interpretation}, acc ->
          acc + byte_size(summary || "") + byte_size(interpretation || "") +
            dir_bytes(Research.dir(id))
        end)

      {Enum.map(rows, &elem(&1, 0)), bytes}
    else
      {[], 0}
    end
  end

  # ------------------------------------------------- what each operation covers

  # A prune never touches a run of a session that is about to go whole: its
  # bytes would be counted twice.
  defp prunable_runs(nil, _session_ids, _now), do: nil

  defp prunable_runs(days, session_ids, now) do
    from(r in Run,
      where:
        r.status in @finished and not is_nil(r.finished_at) and
          r.finished_at < ^cutoff(days, now) and r.pruned == false
    )
    |> exclude_conversations(session_ids)
  end

  defp prunable_checkpoints(nil, _session_ids, _now), do: nil

  defp prunable_checkpoints(days, session_ids, now) do
    from(c in Checkpoint, where: c.inserted_at < ^cutoff(days, now))
    |> exclude_live_runs(Engine.running_run_ids())
    |> exclude_conversations(session_ids)
  end

  defp prunable_journals(nil, _session_ids, _now), do: nil

  defp prunable_journals(days, session_ids, now) do
    from(j in JournalEntry,
      join: r in Run,
      on: r.id == j.run_id,
      join: w in WorkflowRun,
      on: w.run_id == r.id,
      where:
        r.status in @finished and not is_nil(r.finished_at) and
          r.finished_at < ^cutoff(days, now)
    )
    |> exclude_run_conversations(session_ids)
  end

  # `not in ^[]` is not a safe no-op in SQL, so an empty exclusion adds no
  # clause at all.
  defp exclude_conversations(query, []), do: query

  defp exclude_conversations(query, ids),
    do: from(q in query, where: q.conversation_id not in ^ids)

  defp exclude_run_conversations(query, []), do: query

  defp exclude_run_conversations(query, ids),
    do: from([_j, r] in query, where: r.conversation_id not in ^ids)

  defp exclude_live_runs(query, []), do: query

  defp exclude_live_runs(query, run_ids),
    do: from(c in query, where: is_nil(c.run_id) or c.run_id not in ^run_ids)

  defp measure(nil, _what), do: {0, 0}

  defp measure(query, :runs) do
    agg(
      from(r in query,
        left_join: n in Node,
        on: n.run_id == r.id,
        select: {count(r.id, :distinct), sum(node_bytes(n))}
      )
    )
  end

  defp measure(query, :cp),
    do: agg(from(c in query, select: {count(c.id), sum(col_bytes(c.previous_content))}))

  defp measure(query, :journal),
    do: agg(from(j in query, select: {count(j.id), sum(col_bytes(j.result))}))

  # ------------------------------------------------------------- the execution

  @doc "Whether a cleanup is running right now."
  @spec running?() :: boolean()
  def running?, do: Registry.lookup(SwarmCode.Domain.Registry, :storage_cleanup) != []

  @doc """
  Executes a plan in a supervised task, reporting progress on `topic/0`
  (spec 49 §1.5).

  One at a time: a second call while one runs is `{:error, :busy}`.
  """
  @spec run(plan()) :: {:ok, pid()} | {:error, :busy | term()}
  def run(plan) do
    if running?() do
      {:error, :busy}
    else
      Task.Supervisor.start_child(SwarmCode.Domain.TaskSupervisor, fn ->
        case Registry.register(SwarmCode.Domain.Registry, :storage_cleanup, nil) do
          {:ok, _} ->
            try do
              execute(plan, &broadcast/1)
            rescue
              e ->
                broadcast({:storage_failed, e})
                reraise e, __STACKTRACE__
            end

          _ ->
            broadcast({:storage_failed, :busy})
        end
      end)
    end
  end

  @doc """
  Runs a plan in the calling process — the retention sweep's path (spec 49 §2),
  and what the tests drive.

  Unlike `run/1`, the caller's `notify` is the sweep's own channel: pass a
  function capturing the events (e.g. `&send(self(), &1)`) to observe
  `{:storage_progress, _}`, `{:storage_failed, _}` and `{:storage_done, _}`.
  """
  @spec run_sync(plan(), (tuple() -> term())) :: map()
  def run_sync(plan, notify \\ fn _ -> :ok end), do: execute(plan, notify)

  defp execute(plan, notify) do
    before = file_bytes()

    state = %{
      done: 0,
      total: plan.total_count,
      bytes: 0,
      step: "",
      errors: [],
      notify: notify
    }

    if plan[:__raise__], do: raise(plan[:__raise__])

    state =
      state
      |> step("Workflow journals", &delete_journals(&1, plan))
      |> step("Rewind snapshots", &delete_checkpoints(&1, plan))
      |> step("Agent details", &prune_payloads(&1, plan))
      |> step("Research reports", &delete_research(&1, plan))
      |> step("Sessions", &delete_sessions(&1, plan))

    vacuum =
      if plan.vacuum do
        emit(%{state | done: state.total, step: "Reclaiming disk space"})
        vacuum()
      end

    result = %{
      count: state.done,
      bytes_freed: state.bytes,
      before: before.db,
      after: file_bytes().db,
      reclaimable: reclaimable_bytes(),
      vacuum: vacuum,
      errors: Enum.reverse(state.errors)
    }

    notify.({:storage_done, result})
    result
  end

  defp step(state, label, fun) do
    state = %{state | step: label}
    emit(state)
    fun.(state)
  end

  defp emit(state) do
    state.notify.(
      {:storage_progress,
       %{done: state.done, total: state.total, bytes_freed: state.bytes, step: state.step}}
    )

    state
  end

  defp advance(state, count, bytes),
    do: emit(%{state | done: state.done + count, bytes: state.bytes + bytes})

  # 1. journals ------------------------------------------------------------

  defp delete_journals(state, %{journal_days: nil}), do: state

  defp delete_journals(state, plan) do
    query = prunable_journals(plan.journal_days, plan.session_ids, plan.planned_at)

    state
    |> batch_delete(
      JournalEntry,
      from(j in query, select: j.id),
      fn ids ->
        Repo.one(from(j in JournalEntry, where: j.id in ^ids, select: sum(col_bytes(j.result)))) ||
          0
      end,
      plan
    )
    |> log("workflow journal rows")
  end

  # 2. checkpoints ---------------------------------------------------------

  defp delete_checkpoints(state, %{checkpoint_days: nil}), do: state

  defp delete_checkpoints(state, plan) do
    query = prunable_checkpoints(plan.checkpoint_days, plan.session_ids, plan.planned_at)

    state
    |> batch_delete(
      Checkpoint,
      from(c in query, select: c.id),
      fn ids ->
        Repo.one(
          from(c in Checkpoint, where: c.id in ^ids, select: sum(col_bytes(c.previous_content)))
        ) || 0
      end,
      plan
    )
    |> log("rewind snapshots")
  end

  defp batch_delete(state, schema, id_query, measure, plan) do
    batch_size = plan[:__batch_size__] || @batch
    do_batch_delete(state, schema, id_query, measure, batch_size, 0)
  end

  defp do_batch_delete(state, schema, id_query, measure, batch_size, calls) do
    case Repo.all(from(q in id_query, limit: ^batch_size)) do
      [] ->
        state

      ids ->
        bytes = measure.(ids)

        case with_seam(:journal_delete, ids, calls, fn ->
               Repo.delete_all(from(s in schema, where: s.id in ^ids))
             end) do
          {:ok, {count, _}} ->
            state
            |> advance(count, bytes)
            |> do_batch_delete(schema, id_query, measure, batch_size, calls + 1)

          {:error, reason} ->
            Logger.warning(
              "storage batch delete failed for #{inspect(schema)}: #{inspect(reason)}"
            )

            state.notify.({:storage_failed, %{step: :journal_delete, reason: reason}})
            record_error(state, :journal_delete, reason)
        end
    end
  end

  defp record_error(state, step, reason),
    do: %{state | errors: [%{step: step, reason: reason} | state.errors]}

  # 3. payload prune -------------------------------------------------------

  defp prune_payloads(state, %{prune_days: nil}), do: state

  defp prune_payloads(state, plan) do
    query = prunable_runs(plan.prune_days, plan.session_ids, plan.planned_at)

    from(r in query, select: r.id)
    |> Repo.all()
    |> Enum.chunk_every(@run_batch)
    |> Enum.with_index()
    |> Enum.reduce(state, fn {ids, calls}, state -> prune_batch(state, ids, calls) end)
    |> log("runs pruned")
  end

  defp prune_batch(state, ids, calls) do
    # Spec 51 §1.9: consensus is reconstructed from the judge's prompt/result
    # and the submit_plan / write_spec op results (spec 37 §3); those rows
    # keep their text, and the reclaimed figure leaves them out the same way.
    keep_ops =
      Repo.all(
        from(o in Node,
          where: o.run_id in ^ids and o.op_type in ~w(submit_plan write_spec),
          select: o.id
        )
      )

    # Spec 51 §5.8: a run whose rounds were stored as they were produced
    # (`consensus_config["rounds_done"]`) reads its card from those entries,
    # so its judge rows are pruned like any worker; a run from before that
    # keeps the judge's text (the §1.9 interim).
    legacy =
      Repo.all(from(r in Run, where: r.id in ^ids, select: {r.id, r.consensus_config}))
      |> Enum.filter(fn {_id, cfg} -> List.wrap(Map.get(cfg || %{}, "rounds_done")) == [] end)
      |> Enum.map(&elem(&1, 0))

    keep_agents =
      Repo.all(
        from(a in Node,
          where: a.parent_id in ^keep_ops and a.run_id in ^legacy,
          select: a.id
        )
      )

    keep = keep_ops ++ keep_agents

    bytes =
      Repo.one(
        from(n in Node,
          where: n.run_id in ^ids and n.id not in ^keep,
          select: sum(node_bytes(n))
        )
      ) || 0

    case with_seam(:prune_payloads, ids, calls, fn ->
           Repo.update_all(from(n in Node, where: n.run_id in ^ids and n.id not in ^keep),
             set: [result: nil, input: nil, prompt: nil, detail: nil]
           )

           Repo.update_all(from(r in Run, where: r.id in ^ids), set: [pruned: true])
         end) do
      {:ok, _} ->
        advance(state, length(ids), bytes)

      {:error, reason} ->
        Logger.warning(
          "storage prune payloads failed for runs #{inspect(ids)}: #{inspect(reason)}"
        )

        state.notify.({:storage_failed, %{step: :prune_payloads, reason: reason}})
        record_error(state, :prune_payloads, reason)
    end
  end

  # 4. research ------------------------------------------------------------

  defp delete_research(state, %{research_ids: []}), do: state

  defp delete_research(state, plan) do
    plan.research_ids
    |> Enum.reduce(state, fn id, state ->
      bytes = research_bytes(id)
      Research.delete(id)
      advance(state, 1, bytes)
    end)
    |> log("researches")
  end

  defp research_bytes(id) do
    row =
      Repo.one(
        from(r in Research.Research,
          where: r.id == ^id,
          select: {r.summary, r.interpretation}
        )
      )

    case row do
      {summary, interpretation} ->
        byte_size(summary || "") + byte_size(interpretation || "") + dir_bytes(Research.dir(id))

      _ ->
        0
    end
  end

  # 5. sessions ------------------------------------------------------------

  defp delete_sessions(state, %{session_ids: []}), do: state

  defp delete_sessions(state, plan) do
    # Spec 49 §4.1: "running" is re-checked here, not only at plan time — a run
    # can start between the preview and the Delete button.
    live = MapSet.new(running_conversation_ids())
    # spec 60 T21: so are "open" and "pinned" — a session opened or pinned after
    # the preview stays.
    open = MapSet.new(open_conversation_ids())
    include_pinned? = Map.get(plan, :include_pinned, false)

    plan.session_ids
    |> Enum.reduce(state, fn id, state ->
      with false <- MapSet.member?(live, id) or MapSet.member?(open, id),
           conversation when not is_nil(conversation) <- Conversations.get(id),
           false <- conversation.pinned_at != nil and not include_pinned? do
        delete_one(state, conversation, session_bytes(id))
      else
        _ ->
          Logger.info("swarm_code storage: skipped session #{id} (live, open or pinned)")
          state
      end
    end)
    |> log("sessions")
  end

  defp delete_one(state, conversation, bytes) do
    case Conversations.delete(conversation) do
      {:ok, _} ->
        advance(state, 1, bytes)

      other ->
        Logger.warning("swarm_code storage: #{conversation.id} not deleted (#{inspect(other)})")
        state
    end
  end

  defp session_bytes(id) do
    runs =
      Repo.one(
        from(r in Run,
          left_join: n in Node,
          on: n.run_id == r.id,
          where: r.conversation_id == ^id,
          select: sum(node_bytes(n))
        )
      ) || 0

    messages =
      Repo.one(from(m in Message, where: m.conversation_id == ^id, select: sum(msg_bytes(m)))) ||
        0

    checkpoints =
      Repo.one(
        from(c in Checkpoint,
          where: c.conversation_id == ^id,
          select: sum(col_bytes(c.previous_content))
        )
      ) || 0

    journals =
      Repo.one(
        from(j in JournalEntry,
          join: r in Run,
          on: r.id == j.run_id,
          where: r.conversation_id == ^id,
          select: sum(col_bytes(j.result))
        )
      ) || 0

    runs + messages + checkpoints + journals
  end

  # Spec 49 §1.5: one line per destructive step, with counts and bytes.
  defp log(state, what) do
    Logger.info("swarm_code storage: #{state.step} — #{state.done} #{what}, #{mb(state.bytes)}")
    state
  end

  defp mb(bytes), do: :erlang.float_to_binary(bytes / 1_048_576, decimals: 1) <> " MB"

  # ---------------------------------------------------------------- the vacuum

  @doc """
  `PRAGMA wal_checkpoint(TRUNCATE)` then `VACUUM` (spec 49 §1.7).

  Refuses while anything runs — VACUUM takes an exclusive lock and a live agent
  would meet `SQLITE_BUSY` — and when the volume cannot hold a second copy of
  the file, which is what VACUUM writes before it swaps. It holds the
  Scheduler's tick for the duration.
  """
  @spec vacuum() ::
          {:ok, map()} | {:error, :runs_active | {:disk, non_neg_integer(), non_neg_integer()}}
  def vacuum do
    before = file_bytes()
    free = free_disk_bytes()
    needed = before.db * @vacuum_headroom

    cond do
      Engine.running_run_ids() != [] ->
        {:error, :runs_active}

      is_integer(free) and free < needed ->
        {:error, {:disk, needed, free}}

      true ->
        do_vacuum(before)
    end
  end

  defp do_vacuum(before) do
    pause_scheduler()

    try do
      Ecto.Adapters.SQL.query!(Repo, "PRAGMA wal_checkpoint(TRUNCATE)", [], timeout: :infinity)
      Ecto.Adapters.SQL.query!(Repo, "VACUUM", [], timeout: :infinity)
      # And again afterwards (spec 49 §5, browser check): in WAL mode the whole
      # rewritten database lands in the write-ahead log, so without this second
      # checkpoint the file shrinks by 11 MB while a 24 MB `-wal` sits next to
      # it and "freed" reads as zero.
      Ecto.Adapters.SQL.query!(Repo, "PRAGMA wal_checkpoint(TRUNCATE)", [], timeout: :infinity)
    after
      resume_scheduler()
    end

    now = file_bytes()
    freed = max(before.db + before.wal - (now.db + now.wal), 0)
    Logger.info("swarm_code storage: vacuum freed #{mb(freed)}")
    {:ok, %{before: before.db, after: now.db, freed: freed}}
  end

  @doc "Whether the Scheduler should skip this tick (a VACUUM holds it, spec 49 §2)."
  @spec paused?() :: boolean()
  def paused?, do: :persistent_term.get({__MODULE__, :paused}, false)

  defp pause_scheduler, do: :persistent_term.put({__MODULE__, :paused}, true)
  defp resume_scheduler, do: :persistent_term.put({__MODULE__, :paused}, false)

  # ------------------------------------------------------------- the retention

  @doc """
  The daily retention sweep (spec 49 §2), called by the Scheduler's tick.

  Returns `:skipped` unless a policy is set and the last sweep is more than a
  day old. It never vacuums — reclaiming disk is always the user's explicit act
  — and it never deletes a pinned, open or running session.
  """
  @spec apply_retention(DateTime.t()) :: :ok | :skipped
  def apply_retention(now \\ DateTime.utc_now()) do
    settings = Settings.get()

    selection =
      %{}
      |> put_days(:older_than_days, settings.storage_retention_days)
      |> put_days(:prune_days, settings.storage_prune_days)

    cond do
      selection == %{} -> :skipped
      not due?(settings.storage_last_cleanup_at, now) -> :skipped
      running?() -> :skipped
      true -> sweep(selection, now)
    end
  end

  defp sweep(selection, now) do
    plan = plan(selection)
    Settings.update_quiet(%{storage_last_cleanup_at: now})

    if plan.total_count > 0 do
      Logger.info(
        "swarm_code storage: retention sweep — #{plan.total_count} items, #{mb(plan.total_bytes)}"
      )

      run_sync(plan)
    end

    :ok
  end

  defp put_days(selection, _key, nil), do: selection
  defp put_days(selection, key, days) when is_integer(days), do: Map.put(selection, key, days)

  defp due?(nil, _now), do: true
  defp due?(last, now), do: DateTime.diff(now, last, :second) >= 86_400

  # spec 72 D6: count isolation directories across all projects.
  defp count_isolation_dirs do
    for project <- SwarmCode.Domain.Projects.list(),
        dir = SwarmCode.Domain.Projects.Workspace.worktrees_dir(project.root_path),
        File.dir?(dir),
        {:ok, entries} = File.ls(dir),
        reduce: 0 do
      acc -> acc + length(entries)
    end
  rescue
    _ -> 0
  end

  # spec 72 D6: total disk usage of isolation directories.
  defp isolation_disk_usage do
    for project <- SwarmCode.Domain.Projects.list(),
        dir = SwarmCode.Domain.Projects.Workspace.worktrees_dir(project.root_path),
        File.dir?(dir),
        reduce: 0 do
      acc ->
        case System.cmd("du", ["-sk", dir], stderr_to_stdout: true) do
          {out, 0} ->
            case Integer.parse(out) do
              {kb, _} -> acc + kb * 1024
              _ -> acc
            end

          _ ->
            acc
        end
    end
  rescue
    _ -> 0
  end
end
