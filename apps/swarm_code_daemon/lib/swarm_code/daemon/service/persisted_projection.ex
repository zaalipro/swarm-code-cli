defmodule SwarmCode.Daemon.Service.PersistedProjection do
  @moduledoc false
  import Ecto.Query
  alias SwarmCode.Domain.Repo
  alias SwarmCode.Domain.Checkpoints.Checkpoint
  alias SwarmCode.Domain.Conversations.{Conversation, Run, Message, Node}

  # An op that is still open: the agent is on it, so its title is the agent's step.
  @open_ops ~w(running retrying awaiting_approval awaiting_answer paused)

  def runs(conversation, scope, cursor \\ nil, direction \\ "before", limit \\ 201) do
    base = from(r in Run, where: r.conversation_id == ^conversation)

    base =
      cond do
        scope && scope.kind == :run -> from(r in base, where: r.id == ^scope.id)
        scope && scope.kind == :runs -> from(r in base, where: r.id in ^scope.ids)
        true -> base
      end

    query =
      from(r in base,
        select: %{
          id: r.id,
          conversation_id: r.conversation_id,
          kind: r.kind,
          status: r.status,
          prompt: fragment("substr(?, 1, 2048)", r.prompt),
          label: fragment("substr(?, 1, 256)", r.label),
          root_node_id: r.root_node_id,
          launched_by_run_id: r.launched_by_run_id,
          consensus: r.consensus,
          goal_id: r.goal_id,
          # pass72 S: a consensus run's configured rounds (D4).
          consensus_rounds: fragment("json_extract(?, '$.rounds')", r.consensus_config),
          tokens_in: r.tokens_in,
          tokens_out: r.tokens_out,
          cost_usd: r.cost_usd,
          model: r.model,
          error_kind: r.error_kind,
          started_at: r.started_at,
          finished_at: r.finished_at,
          inserted_at: r.inserted_at,
          updated_at: r.updated_at
        }
      )

    page(query, cursor, direction, limit)
  end

  def records(conversation, scope, cursor \\ nil, direction \\ "before", limit \\ 201),
    do: page(records_query(conversation, scope), cursor, direction, limit)

  @doc """
  pass71 S6: the records of `ids` (node ids) exactly as `records/5` selects
  them: the same union, so every column loads with the same type.
  """
  def records_by_ids(_conversation, []), do: []

  def records_by_ids(conversation, ids) do
    Repo.all(
      from(x in subquery(records_query(conversation, nil)),
        where: x.id in ^ids,
        order_by: [asc: x.inserted_at, asc: x.id]
      )
    )
  end

  defp records_query(conversation, scope) do
    m =
      from(m in Message,
        join: r in Run,
        on: r.id == m.run_id,
        where: m.conversation_id == ^conversation
      )

    represented_answer = represented_answer_query()

    n =
      from(n in Node,
        as: :record_node,
        join: r in Run,
        as: :record_run,
        on: r.id == n.run_id,
        where: r.conversation_id == ^conversation,
        where: not exists(subquery(represented_answer))
      )

    m = if scope && scope.kind == :run, do: from([m, r] in m, where: r.id == ^scope.id), else: m
    n = if scope && scope.kind == :run, do: from([n, r] in n, where: r.id == ^scope.id), else: n

    # Both halves of the union list the same keys in the same order. The
    # message half is first, so its column types are the ones Ecto loads the
    # rows with: `agent_id`, `started_at` and `finished_at` are typed fields
    # here so an op node's timings and parent come back cast, not raw text.
    m =
      from([m, r] in m,
        select: %{
          id: m.id,
          run_id: m.run_id,
          node_id: fragment("coalesce(?, ?)", r.root_node_id, r.id),
          role: m.role,
          # pass71 F1: a prompt or reply is read up to 8 KB (the backend's
          # `@reply_bytes`); longer ones keep a detail ref.
          text: fragment("substr(coalesce(?, ''), 1, 8192)", m.content),
          reasoning: fragment("substr(coalesce(?, ''), 1, 2048)", m.reasoning),
          attachments: m.attachments,
          status: r.status,
          inserted_at: m.inserted_at,
          updated_at: m.updated_at,
          text_bytes: fragment("length(cast(coalesce(?, '') as blob))", m.content),
          reasoning_bytes: fragment("length(cast(coalesce(?, '') as blob))", m.reasoning),
          source_kind: m.role,
          op_type: fragment("null"),
          title: fragment("null"),
          detail: fragment("null"),
          input: fragment("null"),
          agent_id: r.root_node_id,
          started_at: m.inserted_at,
          finished_at: m.inserted_at,
          tokens_in: m.tokens_in,
          tokens_out: m.tokens_out,
          result_bytes: fragment("0"),
          # pass73 T3/T8: a steer is a user message the running turn took in
          # (`Engine.steer/4` stores it against the run it steers).
          steer:
            fragment(
              "case when ? = 'user' and ? is not null and ? = ? then 1 else 0 end",
              m.role,
              m.reply_to_run_id,
              m.reply_to_run_id,
              m.run_id
            )
        }
      )

    n =
      from([n, r] in n,
        select: %{
          id: n.id,
          run_id: n.run_id,
          node_id: n.id,
          role: fragment("case when ? = 'agent' then 'assistant' else 'tool' end", n.kind),
          # What the node produced, never its name: the client draws the
          # speaker line from the agent the item belongs to, so a name in the
          # body was a lead called "Lead" over three blank rows.
          # pass72 S: an agent's `detail` "isolated in <branch>" is the
          # engine's bookkeeping, never what the agent produced (the owner saw
          # the branch name as an agent's line): it is not the item's text.
          text:
            fragment(
              "substr(trim(coalesce(?, case when ? like 'isolated in %' then null else ? end, '') || char(10) || coalesce(?, ''), char(10)), 1, case when ? = 'agent' then 8192 else 2048 end)",
              n.result,
              n.detail,
              n.detail,
              n.error,
              n.kind
            ),
          reasoning: fragment("''"),
          attachments: fragment("'[]'"),
          status: n.status,
          inserted_at: n.inserted_at,
          updated_at: n.updated_at,
          text_bytes:
            fragment(
              "length(cast(trim(coalesce(?, case when ? like 'isolated in %' then null else ? end, '') || char(10) || coalesce(?, ''), char(10)) as blob))",
              n.result,
              n.detail,
              n.detail,
              n.error
            ),
          reasoning_bytes: fragment("0"),
          source_kind: n.kind,
          op_type: n.op_type,
          title: fragment("substr(coalesce(?, ''), 1, 200)", n.title),
          detail: fragment("substr(coalesce(?, ''), 1, 200)", n.detail),
          input: n.input,
          agent_id:
            fragment("case when ? = 'agent' then ? else ? end", n.kind, n.id, n.parent_id),
          started_at: n.started_at,
          finished_at: n.finished_at,
          tokens_in: n.tokens_in,
          tokens_out: n.tokens_out,
          result_bytes: fragment("length(cast(coalesce(?, '') as blob))", n.result),
          steer: fragment("0")
        }
      )

    from(x in subquery(union_all(m, ^n)))
  end

  # Window eviction is not removal. Only retire nodes whose answer is now
  # represented by the canonical assistant message.
  def represented_node_ids(_conversation, []), do: []

  def represented_node_ids(conversation, ids) do
    answer = represented_answer_query()

    Repo.all(
      from(n in Node,
        as: :record_node,
        join: r in Run,
        as: :record_run,
        on: r.id == n.run_id,
        where: r.conversation_id == ^conversation and n.id in ^ids and exists(subquery(answer)),
        select: n.id
      )
    )
  end

  # The run's root agent is represented by its answer as soon as the answer
  # exists, empty or streaming: a chat turn creates the assistant message
  # before the agent node, and two "Assistant · thinking" lines for one
  # answer read as two answers. The answering llm op is represented only
  # once the answer is complete and equal to its result.
  defp represented_answer_query do
    from(m in Message,
      where:
        m.run_id == parent_as(:record_run).id and m.role == "assistant" and
          (parent_as(:record_node).id == parent_as(:record_run).root_node_id or
             (m.content != "" and parent_as(:record_node).status == "done" and
                parent_as(:record_node).parent_id == parent_as(:record_run).root_node_id and
                parent_as(:record_node).kind == "op" and parent_as(:record_node).op_type == "llm" and
                parent_as(:record_node).result == m.content)),
      select: 1
    )
  end

  def agents(conversation, ids) do
    Repo.all(
      from(n in agents_query(conversation),
        where: n.run_id in ^ids,
        order_by: [desc: n.inserted_at, desc: n.id],
        limit: 200
      )
    )
  end

  @doc "pass71 S6: the agents of `ids` (node ids), selected as `agents/2` does."
  def agents_by_ids(_conversation, []), do: []

  def agents_by_ids(conversation, ids),
    do: Repo.all(from(n in agents_query(conversation), where: n.id in ^ids))

  defp agents_query(conversation) do
    from(n in Node,
      join: r in Run,
      on: r.id == n.run_id,
      where: r.conversation_id == ^conversation and n.kind == "agent",
      select: %{
        id: n.id,
        run_id: n.run_id,
        kind: n.kind,
        status: n.status,
        updated_at: n.updated_at,
        name: n.name,
        role: n.role,
        title: n.title,
        progress: n.progress,
        tokens_in: n.tokens_in,
        tokens_out: n.tokens_out,
        cost_usd: n.cost_usd,
        started_at: n.started_at,
        finished_at: n.finished_at,
        parent_id: n.parent_id,
        depth: n.depth,
        changes_stat: n.changes_stat,
        error: fragment("substr(coalesce(?, ''), 1, 200)", n.error),
        error_kind: n.error_kind,
        # Only a judge's result is read (its verdict JSON); everyone else's
        # stays in the database.
        result: fragment("case when ? like 'Judge%' then ? else null end", n.name, n.result),
        # pass72 S: the head of a finished agent's result (its finding and
        # the `path:line` it cites), its workflow phase, and its worktree (a
        # prefix the panel's sentences strip).
        result_head:
          fragment(
            "case when ? = 'done' then substr(?, 1, 4096) else null end",
            n.status,
            n.result
          ),
        phase: n.phase,
        workspace_path: n.workspace_path
      }
    )
  end

  @doc """
  pass72 S: the operations the side panel reads for the agents of the live runs
  `ids`: each agent's newest 64 and every open one, newest first. The
  detail (an llm op's reasoning) is cut to 1 280 bytes. Clock-free, so a
  projection is a function of the database alone.
  """
  @panel_ops_per_agent 64

  def panel_ops(_conversation, []), do: []

  def panel_ops(conversation, ids) do
    ranked =
      from(n in Node,
        join: r in Run,
        on: r.id == n.run_id,
        where: r.conversation_id == ^conversation and n.run_id in ^ids and n.kind == "op",
        select: %{
          id: n.id,
          run_id: n.run_id,
          parent_id: n.parent_id,
          op_type: n.op_type,
          status: n.status,
          title: fragment("substr(coalesce(?, ''), 1, 200)", n.title),
          detail: fragment("substr(coalesce(?, ''), 1, 1280)", n.detail),
          started_at: n.started_at,
          finished_at: n.finished_at,
          inserted_at: n.inserted_at,
          rank:
            over(row_number(),
              partition_by: n.parent_id,
              order_by: [desc: n.started_at, desc: n.inserted_at, desc: n.id]
            )
        }
      )

    Repo.all(
      from(o in subquery(ranked),
        where: o.rank <= ^@panel_ops_per_agent or o.status in ^@open_ops,
        order_by: [desc: o.started_at, desc: o.inserted_at, desc: o.id],
        limit: 4000,
        select: %{
          id: o.id,
          run_id: o.run_id,
          parent_id: o.parent_id,
          op_type: o.op_type,
          status: o.status,
          title: o.title,
          detail: o.detail,
          started_at: o.started_at,
          finished_at: o.finished_at
        }
      )
    )
  end

  @doc """
  pass72 S: what the agent overlay reads for one agent of a run of the
  conversation: `{:ok, %{agent, run, ops, changed, siblings}}` or `:error` when
  the node is not an agent of that run. `ops` are the agent's newest 400
  operations, oldest first, with the head of each detail and the tail of each
  result (a command's last output line); `changed` the files it wrote.
  """
  def agent_detail(conversation, run_id, node_id) do
    agent =
      Repo.one(
        from(n in Node,
          join: r in Run,
          on: r.id == n.run_id,
          where:
            r.conversation_id == ^conversation and r.id == ^run_id and n.id == ^node_id and
              n.kind == "agent",
          select: %{
            id: n.id,
            run_id: n.run_id,
            name: n.name,
            role: n.role,
            title: n.title,
            status: n.status,
            parent_id: n.parent_id,
            depth: n.depth,
            tokens_in: n.tokens_in,
            tokens_out: n.tokens_out,
            cost_usd: n.cost_usd,
            turn: n.turn,
            max_turns: n.max_turns,
            started_at: n.started_at,
            finished_at: n.finished_at,
            workspace_path: n.workspace_path,
            changes_stat: n.changes_stat,
            error: fragment("substr(coalesce(?, ''), 1, 400)", n.error),
            prompt: fragment("substr(coalesce(?, ''), 1, 4096)", n.prompt),
            result: fragment("substr(coalesce(?, ''), 1, 8192)", n.result),
            result_bytes: fragment("length(cast(coalesce(?, '') as blob))", n.result),
            result_head:
              fragment(
                "case when ? = 'done' then substr(?, 1, 4096) else null end",
                n.status,
                n.result
              )
          }
        )
      )

    if agent do
      run =
        Repo.one(
          from(r in Run,
            where: r.id == ^run_id,
            select: %{id: r.id, root_node_id: r.root_node_id, model: r.model, status: r.status}
          )
        )

      ops =
        Repo.all(
          from(n in Node,
            where: n.run_id == ^run_id and n.parent_id == ^node_id and n.kind == "op",
            order_by: [desc: n.started_at, desc: n.inserted_at, desc: n.id],
            limit: 400,
            select: %{
              id: n.id,
              parent_id: n.parent_id,
              op_type: n.op_type,
              status: n.status,
              title: fragment("substr(coalesce(?, ''), 1, 200)", n.title),
              detail: fragment("substr(coalesce(?, ''), 1, 1280)", n.detail),
              result: fragment("substr(coalesce(?, ''), 1, 1024)", n.result),
              tail: fragment("substr(coalesce(?, ''), -400)", n.result),
              error: fragment("substr(coalesce(?, ''), 1, 200)", n.error),
              tokens_in: n.tokens_in,
              started_at: n.started_at,
              finished_at: n.finished_at
            }
          )
        )
        |> Enum.reverse()

      changed =
        Repo.all(
          from(c in Checkpoint,
            join: n in Node,
            on: n.id == c.node_id,
            where:
              c.conversation_id == ^conversation and c.run_id == ^run_id and
                (n.id == ^node_id or n.parent_id == ^node_id),
            group_by: c.path,
            order_by: [asc: min(c.inserted_at)],
            limit: 50,
            select: c.path
          )
        )

      siblings =
        Repo.all(
          from(n in Node,
            where: n.run_id == ^run_id and n.kind == "agent",
            order_by: [asc: n.inserted_at, asc: n.id],
            limit: 200,
            select: %{id: n.id, name: n.name, parent_id: n.parent_id, status: n.status}
          )
        )

      {:ok, %{agent: agent, run: run, ops: ops, changed: changed, siblings: siblings}}
    else
      :error
    end
  end

  @doc "pass72 S: how many distinct files each agent of the runs `ids` wrote: `%{agent_id => n}`."
  def files_changed(_conversation, []), do: %{}

  def files_changed(conversation, ids) do
    Repo.all(
      from(c in Checkpoint,
        join: n in Node,
        on: n.id == c.node_id,
        where: c.conversation_id == ^conversation and c.run_id in ^ids,
        group_by: fragment("case when ? = 'agent' then ? else ? end", n.kind, n.id, n.parent_id),
        select:
          {fragment("case when ? = 'agent' then ? else ? end", n.kind, n.id, n.parent_id),
           count(c.path, :distinct)}
      )
    )
    |> Enum.reject(fn {agent, _} -> is_nil(agent) end)
    |> Map.new()
  end

  @doc "pass72 S: `%{run_id => %{phases, phase}}` for the workflow runs among `ids`."
  def workflow_phases([]), do: %{}

  def workflow_phases(ids) do
    Repo.all(
      from(w in SwarmCode.Domain.Workflows.Run,
        where: w.run_id in ^ids,
        select: {w.run_id, %{phases: w.phases, phase: w.phase}}
      )
    )
    |> Map.new()
  end

  @doc """
  pass72 S: for the goal runs among `rows`, `%{run_id => %{iteration,
  iterations, status}}`: the run's place among its goal's runs (oldest first),
  how many runs the goal has had, and the goal's status.
  """
  def goal_facts(rows) do
    goal_ids = rows |> Enum.map(& &1.goal_id) |> Enum.filter(&is_binary/1) |> Enum.uniq()

    if goal_ids == [] do
      %{}
    else
      runs =
        Repo.all(
          from(r in Run,
            where: r.goal_id in ^goal_ids,
            order_by: [asc: r.inserted_at, asc: r.id],
            select: {r.goal_id, r.id}
          )
        )
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

      status =
        Repo.all(
          from(g in SwarmCode.Domain.Conversations.Goal,
            where: g.id in ^goal_ids,
            select: {g.id, g.status}
          )
        )
        |> Map.new()

      for row <- rows, is_binary(row.goal_id), into: %{} do
        ids = Map.get(runs, row.goal_id, [])
        index = Enum.find_index(ids, &(&1 == row.id))

        {row.id,
         %{
           iteration: index && index + 1,
           iterations: length(ids),
           status: status[row.goal_id]
         }}
      end
    end
  end

  @doc "The newest still-open op per agent of `ids`: `%{agent_id => op}`."
  def running_ops(_conversation, []), do: %{}

  def running_ops(conversation, ids) do
    Repo.all(
      from(n in Node,
        join: r in Run,
        on: r.id == n.run_id,
        where:
          r.conversation_id == ^conversation and n.run_id in ^ids and n.kind == "op" and
            n.status in ^@open_ops,
        order_by: [desc: n.started_at, desc: n.inserted_at, desc: n.id],
        limit: 400,
        select: %{
          parent_id: n.parent_id,
          op_type: n.op_type,
          title: fragment("substr(coalesce(?, ''), 1, 200)", n.title),
          started_at: n.started_at
        }
      )
    )
    |> Enum.reduce(%{}, fn op, acc -> Map.put_new(acc, op.parent_id, op) end)
  end

  @doc """
  The newest 200 checkpoints of `ids`, with the agent that wrote each one (the
  checkpoint's node is the write op; its parent is the agent) and that agent's
  worktree, so the path can be shown relative to it.
  """
  def checkpoints(_conversation, []), do: []

  def checkpoints(conversation, ids) do
    Repo.all(
      from(c in Checkpoint,
        left_join: n in Node,
        on: n.id == c.node_id,
        left_join: a in Node,
        on:
          a.id == fragment("case when ? = 'agent' then ? else ? end", n.kind, n.id, n.parent_id),
        where: c.conversation_id == ^conversation and c.run_id in ^ids,
        order_by: [desc: c.inserted_at, desc: c.id],
        limit: 200,
        select: %{
          id: c.id,
          run_id: c.run_id,
          node_id: c.node_id,
          agent_id: a.id,
          workspace_path: a.workspace_path,
          path: c.path,
          restorable: c.restorable,
          inserted_at: c.inserted_at
        }
      )
    )
  end

  @doc "How many checkpoints each run of `ids` has: `%{run_id => count}`."
  def checkpoint_counts(_conversation, []), do: %{}

  def checkpoint_counts(conversation, ids) do
    Repo.all(
      from(c in Checkpoint,
        where: c.conversation_id == ^conversation and c.run_id in ^ids,
        group_by: c.run_id,
        select: {c.run_id, count(c.id)}
      )
    )
    |> Map.new()
  end

  @doc """
  pass70 C3: a keyset page of the project's conversations, newest first
  (`updated_at`, then id). Research conversations are the research's, not the
  user's, and stay out. `cursor` is the id of the last row of the previous
  page. Returns `{:ok, rows, more?}` or `{:error, :invalid_request}`.
  """
  def conversations(project_id, cursor, limit) do
    base =
      from(c in Conversation,
        where: c.project_id == ^project_id and is_nil(c.research_id)
      )

    boundary =
      if cursor,
        do:
          Repo.one(
            from(c in base, where: c.id == ^cursor, select: %{id: c.id, updated_at: c.updated_at})
          )

    if cursor && is_nil(boundary) do
      {:error, :invalid_request}
    else
      bounded =
        if boundary,
          do:
            from(c in base,
              where:
                c.updated_at < ^boundary.updated_at or
                  (c.updated_at == ^boundary.updated_at and c.id < ^boundary.id)
            ),
          else: base

      rows =
        Repo.all(
          from(c in bounded,
            order_by: [desc: c.updated_at, desc: c.id],
            limit: ^(limit + 1),
            select: %{
              id: c.id,
              title: fragment("substr(coalesce(?, ''), 1, 256)", c.title),
              inserted_at: c.inserted_at,
              updated_at: c.updated_at,
              last_seen_at: c.last_seen_at
            }
          )
        )

      {page, rest} = Enum.split(rows, limit)
      ids = Enum.map(page, & &1.id)

      stats =
        if ids == [],
          do: %{},
          else:
            Repo.all(
              from(r in Run,
                where: r.conversation_id in ^ids,
                group_by: r.conversation_id,
                select: {r.conversation_id, count(r.id), max(r.finished_at)}
              )
            )
            |> Map.new(fn {id, count, finished} -> {id, {count, finished}} end)

      {:ok, Enum.map(page, &Map.put(&1, :stats, Map.get(stats, &1.id, {0, nil}))), rest != []}
    end
  end

  @doc """
  pass70 C1/C6: the conversation's spend and its context gauge — the prompt
  tokens of its newest model call, which is what the next turn starts from.
  """
  def conversation_totals(conversation) do
    cost =
      Repo.one(
        from(r in Run,
          where: r.conversation_id == ^conversation,
          select: sum(r.cost_usd)
        )
      )

    # The newest run first, then its newest model call: two indexed lookups
    # instead of a scan of every node of the conversation.
    newest =
      Repo.one(
        from(r in Run,
          where: r.conversation_id == ^conversation,
          order_by: [desc: r.inserted_at, desc: r.id],
          limit: 1,
          select: r.id
        )
      )

    context =
      newest &&
        Repo.one(
          from(n in Node,
            where:
              n.run_id == ^newest and n.kind == "op" and n.op_type == "llm" and n.tokens_in > 0,
            order_by: [desc: n.inserted_at, desc: n.id],
            limit: 1,
            select: n.tokens_in
          )
        )

    %{cost_usd: cost, context_used: context}
  end

  def run_metadata(conversation, ids) do
    {:ok, rows, _, _} =
      runs(conversation, %{kind: :runs, ids: Enum.take(ids, 200)}, nil, "before", 200)

    rows
  end

  def detail(conversation, scope, id, channel, offset, bytes) do
    m = from(m in Message, where: m.conversation_id == ^conversation and m.id == ^id)

    n =
      from(n in Node,
        join: r in Run,
        on: r.id == n.run_id,
        where: r.conversation_id == ^conversation and n.id == ^id
      )

    m = if scope.kind == :run, do: from(m in m, where: m.run_id == ^scope.id), else: m
    n = if scope.kind == :run, do: from([n, r] in n, where: r.id == ^scope.id), else: n
    field = if channel == "reasoning", do: :reasoning, else: :content

    m =
      from(m in m,
        select: %{
          text:
            fragment(
              "substr(cast(coalesce(?, '') as blob), ?, ?)",
              field(m, ^field),
              ^(offset + 1),
              ^bytes
            ),
          total: fragment("length(cast(coalesce(?, '') as blob))", field(m, ^field))
        }
      )

    message = Repo.one(m)

    if message || channel == "reasoning" do
      message
    else
      Repo.one(
        from([n, r] in n,
          select: %{
            # pass70 C8 (ux 2.5): exactly the text `records/5` measured for
            # the item's `detail_ref` (`text_bytes`); the name it used to
            # prepend made every total differ, and the client waited forever
            # for a window of the size it was promised.
            text:
              fragment(
                "substr(cast(trim(coalesce(?, case when ? like 'isolated in %' then null else ? end, '') || char(10) || coalesce(?, ''), char(10)) as blob), ?, ?)",
                n.result,
                n.detail,
                n.detail,
                n.error,
                ^(offset + 1),
                ^bytes
              ),
            total:
              fragment(
                "length(cast(trim(coalesce(?, case when ? like 'isolated in %' then null else ? end, '') || char(10) || coalesce(?, ''), char(10)) as blob))",
                n.result,
                n.detail,
                n.detail,
                n.error
              )
          }
        )
      )
    end
  end

  defp page(query, cursor, direction, limit) do
    query = from(x in subquery(query))

    boundary =
      if cursor,
        do:
          Repo.one(
            from(x in query,
              where: x.id == ^cursor,
              select: %{id: x.id, inserted_at: x.inserted_at}
            )
          )

    if cursor && is_nil(boundary) do
      {:error, :invalid_request}
    else
      bounded =
        cond do
          is_nil(boundary) ->
            query

          direction == "after" ->
            from(x in query,
              where:
                x.inserted_at > ^boundary.inserted_at or
                  (x.inserted_at == ^boundary.inserted_at and x.id > ^boundary.id)
            )

          true ->
            from(x in query,
              where:
                x.inserted_at < ^boundary.inserted_at or
                  (x.inserted_at == ^boundary.inserted_at and x.id < ^boundary.id)
            )
        end

      bounded =
        if direction == "after",
          do: from(x in bounded, order_by: [asc: x.inserted_at, asc: x.id]),
          else: from(x in bounded, order_by: [desc: x.inserted_at, desc: x.id])

      rows = Repo.all(from(x in bounded, limit: ^limit))
      rows = if direction == "before", do: Enum.reverse(rows), else: rows
      first = List.first(rows)
      last = List.last(rows)

      before? =
        first &&
          Repo.exists?(
            from(x in query,
              where:
                x.inserted_at < ^first.inserted_at or
                  (x.inserted_at == ^first.inserted_at and x.id < ^first.id)
            )
          )

      after? =
        last &&
          Repo.exists?(
            from(x in query,
              where:
                x.inserted_at > ^last.inserted_at or
                  (x.inserted_at == ^last.inserted_at and x.id > ^last.id)
            )
          )

      {:ok, rows, if(before?, do: first.id), if(after?, do: last.id)}
    end
  end
end
