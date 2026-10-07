defmodule SwarmCode.Domain.Checkpoints do
  @moduledoc """
  File snapshots taken right before an agent writes, so a turn can be rewound.

  One row per (run, file write): the content the file had before. `nil` means the
  file did not exist yet, so restoring deletes it again.
  """
  import Ecto.Query, warn: false

  alias SwarmCode.Domain.AtomicFile
  alias SwarmCode.Domain.Checkpoints.Checkpoint
  alias SwarmCode.Domain.Conversations
  alias SwarmCode.Domain.Conversations.Run
  alias SwarmCode.Domain.Repo

  # Spec 32 §2: a checkpoint id arrives from the browser, and a rewind writes
  # files. Both the row and its target have to belong to the conversation the
  # user is looking at.
  @foreign "That checkpoint does not belong to this conversation."

  # Anything bigger is recorded but not restorable — we will not keep megabytes
  # of file content in SQLite.
  @max_bytes 2_000_000

  # spec 74 BUGS-3: why a path was left alone by a rewind.
  @unrestorable_reason "binary or over 2 MB"
  @only_copy "kept: the moved copy of a file whose snapshot is binary or over 2 MB"

  @doc """
  Records the current content of `abs_path` for the run in `ctx`. A no-op when
  the context belongs to no conversation (direct tool calls in tests). `run_id`
  is optional: a manual edit from the Changes tab has no run of its own.
  """
  # spec 60 T26: every failure is an error — the callers write nothing without a
  # rewind point. Only "no run and no conversation in `ctx`" is still `:ok`.
  #
  # spec 74 BUGS-3: with `require_restorable: true` a file that could not be
  # rewound (binary, not UTF-8, over 2 MB) is `{:error, :unrestorable}` and no
  # row is written — `move_file`/`delete_file` refuse it before anything
  # changes on disk, instead of leaving a rewind that deletes both copies. The
  # run's existing row for the path decides when there is one, and the check
  # runs with no conversation too (a direct tool call).
  @spec snapshot(map(), String.t(), keyword()) ::
          :ok | {:error, :unrestorable | :database_busy | :invalid_checkpoint | term()}
  def snapshot(ctx, abs_path, opts \\ []) do
    run_id = Map.get(ctx, :run_id)
    require? = Keyword.get(opts, :require_restorable, false)

    case Repo.retry(:checkpoint, fn -> conversation_id(ctx, run_id) end) do
      {:error, :database_busy} ->
        {:error, :database_busy}

      conversation_id when is_binary(conversation_id) ->
        # Spec 51 §1.4: only the oldest snapshot per (run, path) is ever restored
        # (`dedupe/1`, `restore_run/2`), so a second write of the same file in
        # the same run records nothing — 84 % of the checkpoint bytes in the
        # measured database were these duplicates. A manual edit from the
        # Changes tab (`run_id` nil) keeps one row per write.
        case Repo.retry(:checkpoint, fn -> existing_restorable(run_id, abs_path) end) do
          {:error, :database_busy} -> {:error, :database_busy}
          nil -> insert(conversation_id, ctx, abs_path, read(abs_path), require?)
          false when require? -> {:error, :unrestorable}
          _recorded -> :ok
        end

      _none ->
        if require? and not elem(read(abs_path), 1), do: {:error, :unrestorable}, else: :ok
    end
  rescue
    e -> {:error, e}
  end

  @doc "A `snapshot/2` failure as the sentence a tool result or a flash shows (spec 60 T26)."
  @spec error_message(term()) :: String.t()
  def error_message(:database_busy), do: "could not record a checkpoint — retry"
  def error_message(reason) when is_binary(reason), do: reason

  def error_message(e) when is_exception(e),
    do: "could not record a checkpoint (#{Exception.message(e)}) — the file was not changed"

  def error_message(other),
    do: "could not record a checkpoint (#{inspect(other)}) — the file was not changed"

  # The run's row for the path — its `restorable` flag — or nil when the run
  # has none (or there is no run: a manual edit keeps one row per write).
  defp existing_restorable(run_id, abs_path) when is_binary(run_id) do
    Repo.one(
      from(c in Checkpoint,
        where: c.run_id == ^run_id and c.path == ^abs_path,
        select: c.restorable,
        limit: 1
      )
    )
  end

  defp existing_restorable(_run_id, _abs_path), do: nil

  defp insert(_conversation_id, _ctx, _abs_path, {_content, false}, true = _require?),
    do: {:error, :unrestorable}

  defp insert(conversation_id, ctx, abs_path, {content, restorable?}, _require?) do
    # spec 55 T16 (55a A17): a busy database refuses the write instead of
    # letting the file go without a rewind point.
    # spec 68 T3: ownership IDs set via put_change from trusted context.
    case SwarmCode.Domain.Repo.retry(:checkpoint, fn ->
           %Checkpoint{}
           |> Checkpoint.changeset(%{
             path: abs_path,
             previous_content: content,
             restorable: restorable?,
             inserted_at: now()
           })
           |> Ecto.Changeset.put_change(:conversation_id, conversation_id)
           |> Ecto.Changeset.put_change(:run_id, Map.get(ctx, :run_id))
           |> Ecto.Changeset.put_change(:node_id, Map.get(ctx, :node_id))
           |> Checkpoint.validate()
           |> Repo.insert()
         end) do
      {:error, :database_busy} -> {:error, :database_busy}
      {:ok, _} -> :ok
      # spec 60 T26
      {:error, %Ecto.Changeset{}} -> {:error, :invalid_checkpoint}
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp conversation_id(ctx, run_id) do
    case Map.get(ctx, :conversation_id) do
      id when is_binary(id) ->
        id

      _ when is_binary(run_id) ->
        Repo.one(from(r in Run, where: r.id == ^run_id, select: r.conversation_id))

      _ ->
        nil
    end
  end

  defp read(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > @max_bytes ->
        {"[too large]", false}

      {:ok, _} ->
        case File.read(path) do
          {:ok, content} -> {content, String.valid?(content)}
          _ -> {"[unreadable]", false}
        end

      _ ->
        {nil, true}
    end
  end

  # Spec 51 §1.3: a listing is read for its paths, dates and `restorable`; the
  # content (up to @max_bytes a row) is loaded per row at restore time. The
  # `previous_content` column survives as a marker only — "" for "had content",
  # nil for "the file was new" — so the Changes tab's "new" badge keeps working
  # without a byte of the snapshot leaving the database.
  @listing [:id, :conversation_id, :run_id, :node_id, :path, :restorable, :inserted_at]

  defp listing(query) do
    from(c in query,
      select: struct(c, ^@listing),
      select_merge: %{
        previous_content:
          fragment("CASE WHEN ? IS NULL THEN NULL ELSE '' END", c.previous_content)
      }
    )
  end

  @doc "Checkpoints of `run_id`, newest first — without their content (spec 51 §1.3)."
  def for_run(run_id) do
    from(c in Checkpoint, where: c.run_id == ^run_id, order_by: [desc: c.inserted_at])
    |> listing()
    |> Repo.all()
  end

  @doc "One checkpoint with its content, or nil."
  def get(id), do: Repo.get(Checkpoint, id)

  # ------------------------------------------------------------------ T32: what a run changed

  # 200 files and 2 MB of content: the Changes pane is a list to read, not an
  # archive, and a swarm run that rewrote a vendored directory must not pull
  # 60 MB of SQLite into a LiveView's assigns.
  @run_diff_files 200
  @run_diff_bytes 2_000_000
  # Above this many lines a file is counted by line frequency rather than by
  # `List.myers_difference/2`, which is O(ND) and not worth it for a minified
  # bundle or a lock file.
  @myers_lines 20_000

  @doc """
  What a run changed, from its own checkpoints (spec 67 T32 / G45).

  `[%{path, before, after, added, removed}]`, `before`/`after` nil when the file
  did not exist on that side. The Changes pane recomputes from live git, so
  after `git_commit` it shows nothing and an old run's diff was unrecoverable —
  while every before-content has been in this table the whole time. The after
  side is the next checkpoint of the same path in the conversation (what the
  file held when the *next* run first touched it) and, when there is none, what
  is on disk now.

  Capped at #{@run_diff_files} files and #{@run_diff_bytes} bytes of content,
  with a trailing `%{omitted: n}` marker when either bites. `[]` for a run with
  no checkpoints, so a caller can fall back to git.
  """
  @spec run_diff(String.t() | nil) :: [map()]
  def run_diff(run_id) when is_binary(run_id) do
    # spec 73 T68: the query is limited to the files that can be shown — every
    # row's content was loaded (500 files × up to 2 MB) to show 200. The
    # omitted marker comes from a count of distinct paths, so the output is
    # what it was.
    rows =
      from(c in Checkpoint,
        where: c.run_id == ^run_id,
        order_by: [asc: c.inserted_at, asc: c.id],
        limit: @run_diff_files,
        select: %{
          path: c.path,
          previous_content: c.previous_content,
          restorable: c.restorable,
          inserted_at: c.inserted_at,
          conversation_id: c.conversation_id
        }
      )
      |> Repo.all()
      # `snapshot/2` keeps only the oldest row per (run, path) already; this is
      # the belt for rows written before spec 51 §1.4.
      |> Enum.uniq_by(& &1.path)

    case rows do
      [] -> []
      rows -> build_run_diff(rows, distinct_paths(run_id, rows))
    end
  rescue
    Ecto.Query.CastError -> []
  end

  def run_diff(_run_id), do: []

  @doc """
  One path's `run_diff/1` entry (spec 74 EFFICIENCY-55): the oldest checkpoint
  of `path` in the run, diffed by the same rules — nil when the run never
  touched it. Showing one file of a finished run no longer builds the whole
  run's diff; a file past `run_diff/1`'s page now shows too.
  """
  @spec run_file_diff(String.t(), String.t()) :: map() | nil
  def run_file_diff(run_id, path) when is_binary(run_id) and is_binary(path) do
    from(c in Checkpoint,
      where: c.run_id == ^run_id and c.path == ^path,
      order_by: [asc: c.inserted_at, asc: c.id],
      limit: 1,
      select: %{
        path: c.path,
        previous_content: c.previous_content,
        restorable: c.restorable,
        inserted_at: c.inserted_at,
        conversation_id: c.conversation_id
      }
    )
    |> Repo.one()
    |> case do
      nil -> nil
      row -> diff_entry(row, next_contents([row]))
    end
  rescue
    Ecto.Query.CastError -> nil
  end

  def run_file_diff(_run_id, _path), do: nil

  # Only a page that may have been cut needs the count.
  defp distinct_paths(_run_id, rows) when length(rows) < @run_diff_files, do: length(rows)

  defp distinct_paths(run_id, _rows) do
    Repo.one(from(c in Checkpoint, where: c.run_id == ^run_id, select: count(c.path, :distinct)))
  end

  defp build_run_diff(shown, total) do
    nexts = next_contents(shown)

    entries =
      shown
      |> Enum.reduce_while({[], 0}, fn row, {acc, bytes} ->
        entry = diff_entry(row, nexts)
        size = byte_size(entry.before || "") + byte_size(entry.after || "")

        if acc != [] and bytes + size > @run_diff_bytes,
          do: {:halt, {acc, bytes}},
          else: {:cont, {[entry | acc], bytes + size}}
      end)
      |> elem(0)
      |> Enum.reverse()

    case total - length(entries) do
      0 -> entries
      omitted -> entries ++ [%{omitted: omitted}]
    end
  end

  defp diff_entry(row, nexts) do
    before = content(row)
    after_ = after_content(row, nexts)
    {added, removed} = counts(before, after_)

    %{path: row.path, before: before, after: after_, added: added, removed: removed}
  end

  # A row recorded as unrestorable holds a marker ("[too large]"), never the
  # file: counting its lines would be a lie, so it reads as "no content".
  defp content(%{restorable: false}), do: nil
  defp content(%{previous_content: content}), do: content

  # The content the file had when the run was over: the next checkpoint of the
  # same path in this conversation recorded exactly that, and when there is none
  # the file on disk still holds it — a `git commit` in between changes neither.
  defp after_content(row, nexts) do
    case Map.fetch(nexts, row.path) do
      {:ok, content} -> content
      :error -> disk_content(row.path)
    end
  end

  defp disk_content(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > @max_bytes ->
        nil

      {:ok, _stat} ->
        case File.read(path) do
          {:ok, content} -> if String.valid?(content), do: content
          _error -> nil
        end

      _missing ->
        nil
    end
  end

  # spec 73 T68: the later snapshots are listed by id, path and time first;
  # the content is fetched for exactly the one row per path that is the
  # "after" side — a conversation with 30 later turns on the same paths
  # loaded thirty contents per file to use one.
  defp next_contents([]), do: %{}

  defp next_contents([%{conversation_id: conversation_id} | _] = rows) do
    paths = Enum.map(rows, & &1.path)
    oldest = rows |> Enum.map(& &1.inserted_at) |> Enum.min(DateTime)

    later =
      from(c in Checkpoint,
        where:
          c.conversation_id == ^conversation_id and c.path in ^paths and
            c.inserted_at > ^oldest and c.restorable == true,
        order_by: [asc: c.inserted_at, asc: c.id],
        select: %{id: c.id, path: c.path, at: c.inserted_at}
      )
      |> Repo.all()
      |> Enum.group_by(& &1.path)

    chosen =
      for row <- rows,
          next =
            Enum.find(
              Map.get(later, row.path, []),
              &(DateTime.compare(&1.at, row.inserted_at) == :gt)
            ),
          do: {next.id, row.path}

    case chosen do
      [] ->
        %{}

      chosen ->
        ids = Enum.map(chosen, &elem(&1, 0))

        contents =
          from(c in Checkpoint, where: c.id in ^ids, select: {c.id, c.previous_content})
          |> Repo.all()
          |> Map.new()

        Map.new(chosen, fn {id, path} -> {path, Map.get(contents, id)} end)
    end
  end

  defp counts(before, after_) do
    b = lines(before)
    a = lines(after_)

    if length(b) + length(a) > @myers_lines, do: rough_counts(b, a), else: myers_counts(b, a)
  end

  defp lines(nil), do: []
  defp lines(""), do: []
  defp lines(text), do: String.split(text, "\n")

  defp myers_counts(b, a) do
    b
    |> List.myers_difference(a)
    |> Enum.reduce({0, 0}, fn
      {:ins, lines}, {added, removed} -> {added + length(lines), removed}
      {:del, lines}, {added, removed} -> {added, removed + length(lines)}
      {:eq, _lines}, acc -> acc
    end)
  end

  # Line frequencies: a line that is in the new file more often than in the old
  # one counts as added, and the other way round. It is what `diff` would say
  # for a file whose lines are mostly unique, and it is O(n).
  defp rough_counts(b, a) do
    before_freq = Enum.frequencies(b)
    after_freq = Enum.frequencies(a)

    added =
      Enum.reduce(after_freq, 0, fn {line, n}, sum ->
        sum + max(n - Map.get(before_freq, line, 0), 0)
      end)

    removed =
      Enum.reduce(before_freq, 0, fn {line, n}, sum ->
        sum + max(n - Map.get(after_freq, line, 0), 0)
      end)

    {added, removed}
  end

  @doc """
  The conversation's checkpoints grouped by run, newest turn first:
  `[%{run_id, turn, prompt, at, files: [checkpoint]}]`.
  """
  @spec for_conversation(String.t(), [map()] | nil) :: [map()]
  def for_conversation(conversation_id, runs \\ nil)

  def for_conversation(conversation_id, runs) do
    checkpoints =
      from(c in Checkpoint,
        where: c.conversation_id == ^conversation_id,
        order_by: [desc: c.inserted_at]
      )
      |> listing()
      |> Repo.all()

    # spec 74 EFFICIENCY-32: the runs the caller holds, and none read at all
    # when there is nothing to list.
    runs =
      cond do
        checkpoints == [] -> []
        is_list(runs) -> runs
        true -> Conversations.list_runs(conversation_id)
      end

    turns =
      runs
      |> Enum.sort_by(& &1.started_at, DateTime)
      |> Enum.with_index(1)
      |> Map.new(fn {r, i} -> {r.id, {i, r}} end)

    checkpoints
    |> Enum.group_by(& &1.run_id)
    |> Enum.map(fn {run_id, files} ->
      {turn, run} = Map.get(turns, run_id, {0, nil})

      %{
        run_id: run_id,
        turn: turn,
        prompt: run && run.prompt,
        at: List.last(files) && List.last(files).inserted_at,
        # spec 74 BUGS-38: the manual saves of the Changes tab (no run) keep the
        # newest row per path, so their Restore undoes the latest save; a
        # turn keeps its oldest, which takes the file back to the turn's start.
        files: if(is_nil(run_id), do: Enum.uniq_by(files, & &1.path), else: dedupe(files))
      }
    end)
    |> Enum.sort_by(& &1.turn, :desc)
  end

  # One row per path (the oldest snapshot of that path in the run is the one that
  # takes the file back to where the turn started).
  defp dedupe(files) do
    files
    |> Enum.reverse()
    |> Enum.uniq_by(& &1.path)
    |> Enum.reverse()
  end

  @doc """
  Restores one file to the content recorded in `checkpoint_id`.

  The checkpoint must belong to `conversation_id`, and its target must still be
  inside that conversation's project.
  """
  #
  # spec 74 BUGS-3: a delete-on-restore row (the file did not exist) whose
  # operation also recorded an unrestorable row is the destination of a move
  # of a binary or oversized file — deleting it would delete the only copy, so
  # it is refused by name.
  @spec restore_one(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def restore_one(conversation_id, checkpoint_id) do
    with {:ok, root} <- project_root(conversation_id),
         {:ok, checkpoint} <- own(conversation_id, checkpoint_id),
         :ok <- not_only_copy(root, checkpoint) do
      apply_checkpoint(root, checkpoint)
    end
  end

  defp not_only_copy(root, %Checkpoint{previous_content: nil, node_id: node_id} = checkpoint)
       when is_binary(node_id) do
    if Repo.exists?(from(c in Checkpoint, where: c.node_id == ^node_id and not c.restorable)),
      do:
        {:error,
         "#{relative(root, checkpoint.path)} is the moved copy of a file whose snapshot is " <>
           "binary or over 2 MB — restoring it would delete the only copy"},
      else: :ok
  end

  defp not_only_copy(_root, _checkpoint), do: :ok

  @doc "The conversation's own checkpoint, or the exact ownership error."
  @spec own(String.t(), String.t()) :: {:ok, Checkpoint.t()} | {:error, String.t()}
  def own(conversation_id, checkpoint_id) when is_binary(checkpoint_id) do
    case Repo.get_by(Checkpoint, id: checkpoint_id, conversation_id: conversation_id) do
      nil ->
        {:error, @foreign}

      %Checkpoint{restorable: false} ->
        {:error,
         "this file is binary or too large (over 2 MB), so its snapshot cannot be restored"}

      checkpoint ->
        {:ok, checkpoint}
    end
  rescue
    # A malformed id is a foreign id.
    Ecto.Query.CastError -> {:error, @foreign}
  end

  def own(_conversation_id, _checkpoint_id), do: {:error, @foreign}

  defp project_root(conversation_id) do
    with %{project_id: project_id} when is_binary(project_id) <-
           Conversations.get(conversation_id),
         %{root_path: root} when is_binary(root) <- SwarmCode.Domain.Projects.get(project_id) do
      {:ok, root}
    else
      _other -> {:error, @foreign}
    end
  end

  # Spec 51 §1.3: the listing carried no content; the row is read here, and one
  # deleted since the listing (a cleanup, another window) says so.
  defp apply_checkpoint(_root, nil), do: {:error, "the snapshot was deleted"}

  defp apply_checkpoint(root, %Checkpoint{previous_content: nil, path: path}) do
    case AtomicFile.remove(root, path) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, restore_error(root, path, reason)}
    end
  end

  defp apply_checkpoint(root, %Checkpoint{previous_content: content, path: path}) do
    case AtomicFile.replace(root, path, content) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, restore_error(root, path, reason)}
    end
  end

  # A file that has since moved out of the project is not this conversation's to
  # write, whatever the row says.
  defp restore_error(_root, _path, :outside_root), do: @foreign

  defp restore_error(root, path, reason),
    do:
      "cannot restore #{SwarmCode.Domain.Tools.Path.relative(root, path)}: #{AtomicFile.format_error(reason)}"

  @doc """
  Takes the conversation back to just before `run_id`: restores that run's
  checkpoints and every later run's, newest first, and records what happened.
  """
  @spec restore_run(String.t(), String.t()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def restore_run(conversation_id, run_id) do
    with {:ok, %{restored: n}} <- restore_run_report(conversation_id, run_id), do: {:ok, n}
  end

  @doc """
  `restore_run/2` with what could not be restored (spec 74 BUGS-3):
  `{:ok, %{restored: n, skipped: [{relative_path, reason}], message: text}}`,
  where `message` is the sentence the chat records ("Rewound 3 file(s) to
  before turn 2; could not restore data/big.json (binary or over 2 MB).").
  """
  @spec restore_run_report(String.t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def restore_run_report(conversation_id, run_id) do
    turns = for_conversation(conversation_id)

    case Enum.find(turns, &(&1.run_id == run_id)) do
      nil ->
        {:error, "unknown turn"}

      %{turn: turn} ->
        rows =
          turns
          |> Enum.filter(&(&1.turn >= turn))
          |> Enum.sort_by(& &1.turn, :asc)
          |> Enum.flat_map(& &1.files)

        with {:ok, root} <- project_root(conversation_id) do
          {restored, skipped} = plan_restore(rows)
          do_rewind(conversation_id, root, restored, turn, describe_skipped(root, skipped))
        end
    end
  end

  # A file touched in several turns must end up with the content it had before
  # the OLDEST of them, so the earliest snapshot per path wins — and it wins
  # **before** the restorable filter (spec 74 BUGS-3): filtering first let a
  # later row of the same path stand in for an unrestorable earliest one. A
  # path whose earliest row is unrestorable is skipped, and so is a
  # delete-on-restore row of the same operation (`node_id`): that is the
  # destination of a moved binary, and deleting it deleted the only copy.
  defp plan_restore(rows) do
    earliest = Enum.uniq_by(rows, & &1.path)

    unrestorable_nodes =
      for %{restorable: false, node_id: node_id} when is_binary(node_id) <- rows,
          into: MapSet.new(),
          do: node_id

    Enum.reduce(earliest, {[], []}, fn row, {restored, skipped} ->
      cond do
        not row.restorable ->
          {restored, [{row.path, @unrestorable_reason} | skipped]}

        is_nil(row.previous_content) and MapSet.member?(unrestorable_nodes, row.node_id) ->
          {restored, [{row.path, @only_copy} | skipped]}

        true ->
          {[row | restored], skipped}
      end
    end)
    |> then(fn {restored, skipped} -> {Enum.reverse(restored), Enum.reverse(skipped)} end)
  end

  defp describe_skipped(root, skipped),
    do: Enum.map(skipped, fn {path, reason} -> {relative(root, path), reason} end)

  defp relative(root, path), do: SwarmCode.Domain.Tools.Path.relative(root, path)

  # Spec 32 §2: every failure used to be swallowed and the count reported as if
  # it had worked. It stops at the first one and says how far it got; retrying
  # after the cause is fixed reapplies the prefix and writes the one message.
  # Public for the spec 51 §1.3 test (a row deleted between listing and restore).
  @doc false
  def rewind(conversation_id, root, checkpoints, turn) do
    with {:ok, %{restored: n}} <- do_rewind(conversation_id, root, checkpoints, turn, []),
         do: {:ok, n}
  end

  defp do_rewind(conversation_id, root, checkpoints, turn, skipped) do
    result =
      Enum.reduce_while(checkpoints, {:ok, 0}, fn checkpoint, {:ok, done} ->
        case apply_checkpoint(root, Repo.get(Checkpoint, checkpoint.id)) do
          {:ok, _path} ->
            {:cont, {:ok, done + 1}}

          {:error, reason} ->
            relative = relative(root, checkpoint.path)
            {:halt, {:error, "Could not restore #{relative}: #{reason} after #{done} file(s)."}}
        end
      end)

    with {:ok, n} <- result do
      message = rewind_message(n, turn, skipped)

      Conversations.create_message(%{
        conversation_id: conversation_id,
        role: "swarm",
        content: message
      })

      {:ok, %{restored: n, skipped: skipped, message: message}}
    end
  end

  defp rewind_message(n, turn, []), do: "Rewound #{n} file(s) to before turn #{turn}."

  defp rewind_message(n, turn, skipped) do
    names = Enum.map_join(skipped, ", ", fn {rel, reason} -> "#{rel} (#{reason})" end)
    "Rewound #{n} file(s) to before turn #{turn}; could not restore #{names}."
  end
end
