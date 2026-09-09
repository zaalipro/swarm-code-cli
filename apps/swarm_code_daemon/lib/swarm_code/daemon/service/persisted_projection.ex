defmodule SwarmCode.Daemon.Service.PersistedProjection do
  @moduledoc false
  import Ecto.Query
  alias SwarmCode.Domain.Repo
  alias SwarmCode.Domain.Conversations.{Run, Message, Node}

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
          inserted_at: r.inserted_at,
          updated_at: r.updated_at
        }
      )

    page(query, cursor, direction, limit)
  end

  def records(conversation, scope, cursor \\ nil, direction \\ "before", limit \\ 201) do
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

    m =
      from([m, r] in m,
        select: %{
          id: m.id,
          run_id: m.run_id,
          node_id: fragment("coalesce(?, ?)", r.root_node_id, r.id),
          role: m.role,
          text: fragment("substr(coalesce(?, ''), 1, 2048)", m.content),
          reasoning: fragment("substr(coalesce(?, ''), 1, 2048)", m.reasoning),
          attachments: m.attachments,
          status: r.status,
          inserted_at: m.inserted_at,
          updated_at: m.updated_at,
          text_bytes: fragment("length(cast(coalesce(?, '') as blob))", m.content),
          reasoning_bytes: fragment("length(cast(coalesce(?, '') as blob))", m.reasoning)
        }
      )

    n =
      from([n, r] in n,
        select: %{
          id: n.id,
          run_id: n.run_id,
          node_id: n.id,
          role: fragment("case when ? = 'agent' then 'assistant' else 'tool' end", n.kind),
          text:
            fragment(
              "substr(coalesce(?, '') || char(10) || coalesce(?, ?, '') || char(10) || coalesce(?, ''), 1, 2048)",
              n.name,
              n.result,
              n.detail,
              n.error
            ),
          reasoning: fragment("''"),
          attachments: fragment("'[]'"),
          status: n.status,
          inserted_at: n.inserted_at,
          updated_at: n.updated_at,
          text_bytes:
            fragment(
              "length(cast(coalesce(?, '') || char(10) || coalesce(?, ?, '') || char(10) || coalesce(?, '') as blob))",
              n.name,
              n.result,
              n.detail,
              n.error
            ),
          reasoning_bytes: fragment("0")
        }
      )

    page(from(x in subquery(union_all(m, ^n))), cursor, direction, limit)
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

  defp represented_answer_query do
    from(m in Message,
      where:
        m.run_id == parent_as(:record_run).id and m.role == "assistant" and
          m.content != "" and parent_as(:record_node).status == "done" and
          (parent_as(:record_node).id == parent_as(:record_run).root_node_id or
             (parent_as(:record_node).parent_id == parent_as(:record_run).root_node_id and
                parent_as(:record_node).kind == "op" and parent_as(:record_node).op_type == "llm" and
                parent_as(:record_node).result == m.content)),
      select: 1
    )
  end

  def agents(conversation, ids) do
    Repo.all(
      from(n in Node,
        join: r in Run,
        on: r.id == n.run_id,
        where: r.conversation_id == ^conversation and n.run_id in ^ids and n.kind == "agent",
        order_by: [desc: n.inserted_at, desc: n.id],
        limit: 200,
        select: %{
          id: n.id,
          run_id: n.run_id,
          kind: n.kind,
          status: n.status,
          updated_at: n.updated_at
        }
      )
    )
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
            text:
              fragment(
                "substr(cast(coalesce(?, '') || char(10) || coalesce(?, ?, '') || char(10) || coalesce(?, '') as blob), ?, ?)",
                n.name,
                n.result,
                n.detail,
                n.error,
                ^(offset + 1),
                ^bytes
              ),
            total:
              fragment(
                "length(cast(coalesce(?, '') || char(10) || coalesce(?, ?, '') || char(10) || coalesce(?, '') as blob))",
                n.name,
                n.result,
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
