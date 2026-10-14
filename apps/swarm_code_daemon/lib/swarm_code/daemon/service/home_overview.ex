defmodule SwarmCode.Daemon.Service.HomeOverview do
  @moduledoc """
  orbit: the bounded reads behind `home.overview` (the CLI's Home screen).

  `build/4` is pure database and ETS reading with no backend state, so the
  backend runs it inside a job's `work` function. Every read is bounded by the
  request: at most `projects` projects, `per_project` conversations each, five
  live runs, one scheduled task. It never calls `Projects.list/0` or
  `Conversations.list_visible/0` (both unbounded).

  The result is the body of the wire's `home_overview` response without the
  `request_id`, `state` and `error` entries the backend wraps around it.
  Titles are at most 256 bytes, names at most 200, and every instant is unix
  milliseconds.
  """
  import Ecto.Query

  alias SwarmCode.Daemon.Service.Settings.Usage
  alias SwarmCode.Domain.Conversations.{Conversation, Message, Node, Run}
  alias SwarmCode.Domain.Engine.Questions
  alias SwarmCode.Domain.Projects.Project
  alias SwarmCode.Domain.{Repo, Scheduled}

  # The registry rows read for the bars (and their conversations' live marks).
  @live_cap 64
  # Bars shown; the rest is `live_overflow`.
  @bars 5
  # Waiting conversations whose project is looked up (they are few).
  @waiting_cap 500
  @kinds ~w(chat goal swarm workflow research consensus ultra)

  @type options :: %{projects: 1..8, per_project: 1..24}

  @doc """
  The overview of `project_id` and the most recently opened other projects.

  `month` is the spend/budget pair the backend cached (nil reads it now) and
  `revision` the backend's home revision the answer reflects.
  """
  @spec build(binary(), options(), map() | nil, non_neg_integer()) :: map()
  def build(project_id, %{projects: projects, per_project: per_project}, month, revision) do
    list = project_rows(project_id, projects)
    ids = Enum.map(list, & &1.id)

    page = conversation_rows(ids, per_project)
    counts = conversation_counts(ids)
    finished = finished_at(Enum.map(page, & &1.id))
    live = live_rows()
    waits = Questions.list() |> Enum.frequencies_by(& &1.conversation_id)
    waiting_by_project = waiting_by_project(waits)

    live_by_conversation = live_by_conversation(live)
    live_by_project = live_by_project(live)

    {bars, overflow} = Enum.split(live, @bars)

    %{
      "revision" => revision,
      "project_id" => project_id,
      "projects" =>
        Enum.map(list, fn project ->
          conversations =
            for row <- page, row.project_id == project.id do
              conversation_body(row, finished, live_by_conversation, waits)
            end

          %{
            "id" => project.id,
            "name" => clip(project.name, 200),
            "root_path" => clip(project.root_path, 4096),
            "current" => project.id == project_id,
            "last_opened_at" => ms(project.last_opened_at),
            "conversation_count" => Map.get(counts, project.id, 0),
            "live" => Map.get(live_by_project, project.id, 0),
            "waiting" => Map.get(waiting_by_project, project.id, 0),
            "conversations" => conversations
          }
        end),
      "live_runs" => Enum.map(bars, &live_run_body/1),
      "live_overflow" => length(overflow),
      "waiting_total" => waits |> Map.values() |> Enum.sum(),
      "month" => month || Usage.month(),
      "next_scheduled" => next_scheduled()
    }
  end

  # The current project first (even a scratch one), then the non-scratch
  # projects by `last_opened_at` (never opened last), then name: one query.
  defp project_rows(project_id, limit) do
    Repo.all(
      from(p in Project,
        where: p.id == ^project_id or p.scratch == false,
        order_by: [
          desc: fragment("(? = ?)", p.id, ^project_id),
          desc_nulls_last: p.last_opened_at,
          asc: p.name
        ],
        limit: ^limit,
        select: %{
          id: p.id,
          name: p.name,
          root_path: p.root_path,
          last_opened_at: p.last_opened_at
        }
      )
    )
  end

  # The conversations the user made themselves: not research, not a scheduled
  # task's, and not an empty one (D11: no run and no live user message, the
  # one `SessionSelection.open/2` gives a project nothing was said in; it is
  # the client's `Home.empty?/1`). `query` names its conversation binding `:c`.
  defp own_conversations(query) do
    from(c in query,
      where:
        is_nil(c.research_id) and is_nil(c.scheduled_task_id) and
          (exists(from(r in Run, where: r.conversation_id == parent_as(:c).id, select: 1)) or
             exists(
               from(m in Message,
                 where:
                   m.conversation_id == parent_as(:c).id and m.role == "user" and
                     is_nil(m.superseded_at),
                 select: 1
               )
             ))
    )
  end

  # The newest `per_project` conversations of each project, in one window query
  # (see `own_conversation/0` for which conversations count).
  defp conversation_rows([], _per_project), do: []

  defp conversation_rows(ids, per_project) do
    ranked =
      from(c in Conversation, as: :c, where: c.project_id in ^ids)
      |> own_conversations()
      |> select([c], %{
        id: c.id,
        project_id: c.project_id,
        title: fragment("substr(coalesce(?, ''), 1, 256)", c.title),
        updated_at: c.updated_at,
        last_seen_at: c.last_seen_at,
        rank:
          over(row_number(),
            partition_by: c.project_id,
            order_by: [desc: c.updated_at, desc: c.id]
          )
      })

    Repo.all(
      from(r in subquery(ranked),
        where: r.rank <= ^per_project,
        order_by: [asc: r.project_id, desc: r.updated_at, desc: r.id]
      )
    )
  end

  defp conversation_counts([]), do: %{}

  defp conversation_counts(ids) do
    from(c in Conversation, as: :c, where: c.project_id in ^ids)
    |> own_conversations()
    |> group_by([c], c.project_id)
    |> select([c], {c.project_id, count(c.id)})
    |> Repo.all()
    |> Map.new()
  end

  # Each page conversation's newest finished run, which `unread?/2` compares
  # with when it was last seen.
  defp finished_at([]), do: %{}

  defp finished_at(conversation_ids) do
    Repo.all(
      from(r in Run,
        where: r.conversation_id in ^conversation_ids,
        group_by: r.conversation_id,
        select: {r.conversation_id, max(r.finished_at)}
      )
    )
    |> Map.new()
  end

  defp conversation_body(row, finished, live_by_conversation, waits) do
    run = Map.get(live_by_conversation, row.id)

    %{
      "id" => row.id,
      "title" => clip(row.title, 256),
      "updated_at" => ms(row.updated_at) || 0,
      "live" => run != nil,
      "live_kind" => run && run.kind,
      "waiting" => Map.get(waits, row.id, 0),
      "unread" => unread?(row.last_seen_at, Map.get(finished, row.id))
    }
  end

  # The engine registry's runs (this VM's), joined to their conversation and
  # root node, oldest first. A registry entry whose run row is gone (a race, or
  # a run another process owns) is ignored.
  defp live_rows do
    ids =
      Registry.select(SwarmCode.Domain.Registry, [{{{:run, :"$1"}, :_, :_}, [], [:"$1"]}])
      |> Enum.take(@live_cap)

    if ids == [] do
      []
    else
      Repo.all(
        from(r in Run,
          join: c in Conversation,
          on: c.id == r.conversation_id,
          left_join: n in Node,
          on: n.id == r.root_node_id,
          where: r.id in ^ids,
          order_by: [asc: r.started_at, asc: r.id],
          select: %{
            id: r.id,
            conversation_id: r.conversation_id,
            project_id: c.project_id,
            kind: r.kind,
            goal_id: r.goal_id,
            consensus: r.consensus,
            started_at: r.started_at,
            progress: n.progress
          }
        )
      )
      |> Enum.map(&Map.put(&1, :presentation, presentation_kind(&1)))
    end
  end

  defp live_run_body(run) do
    %{
      "id" => run.id,
      "project_id" => run.project_id,
      "conversation_id" => run.conversation_id,
      "kind" => run.presentation,
      "progress" => progress(run.progress),
      "started_at" => ms(run.started_at) || 0
    }
  end

  # A conversation is live while one of its runs is; `live_kind` is the newest
  # running run's kind. (`live` is oldest first, so the last one per
  # conversation wins.)
  defp live_by_conversation(live) do
    Enum.reduce(live, %{}, fn run, acc ->
      Map.put(acc, run.conversation_id, %{kind: run.presentation})
    end)
  end

  # Live conversations per project (not runs: a conversation with two runs
  # still counts once, as its bead does).
  defp live_by_project(live) do
    live
    |> Enum.uniq_by(& &1.conversation_id)
    |> Enum.frequencies_by(& &1.project_id)
  end

  # A project's waiting count is the sum over all of its conversations that
  # wait, including any outside the page.
  defp waiting_by_project(waits) when map_size(waits) == 0, do: %{}

  defp waiting_by_project(waits) do
    ids = waits |> Map.keys() |> Enum.take(@waiting_cap)

    Repo.all(from(c in Conversation, where: c.id in ^ids, select: {c.id, c.project_id}))
    |> Enum.reduce(%{}, fn {conversation_id, project_id}, acc ->
      Map.update(acc, project_id, waits[conversation_id], &(&1 + waits[conversation_id]))
    end)
  end

  defp next_scheduled do
    case Scheduled.upcoming(1) do
      [task | _] ->
        project = loaded_project(task)

        %{
          "id" => task.id,
          "name" => clip(task.name, 200),
          "project_id" => project && project.id,
          "project_name" => project && clip(project.name, 200),
          "next_run_at" => ms(task.next_run_at) || 0
        }

      [] ->
        nil
    end
  end

  defp loaded_project(%{project: %Project{} = project}), do: project
  defp loaded_project(_task), do: nil

  # The same kind the live conversation list shows (`presentation_kind/1` of
  # the backend) plus a whitelist: a compact turn is a chat.
  defp presentation_kind(%{goal_id: id}) when is_binary(id), do: "goal"
  defp presentation_kind(%{consensus: true}), do: "consensus"
  defp presentation_kind(%{kind: kind}) when kind in @kinds, do: kind
  defp presentation_kind(_run), do: "chat"

  defp progress(value) when is_integer(value), do: value |> max(0) |> min(100)
  defp progress(_value), do: nil

  # `unread?/2` of `PersistedBackend`: a run finished after the conversation
  # was last seen (never seen = unread once anything finished).
  defp unread?(_seen, nil), do: false
  defp unread?(nil, _finished), do: true

  defp unread?(seen, finished) do
    case {ms(seen), ms(finished)} do
      {seen, finished} when is_integer(seen) and is_integer(finished) -> finished > seen
      _ -> false
    end
  end

  # Unix milliseconds; a raw SQLite datetime string is parsed, anything else is
  # unknown.
  defp ms(nil), do: nil
  defp ms(%DateTime{} = value), do: max(DateTime.to_unix(value, :millisecond), 0)

  defp ms(%NaiveDateTime{} = value),
    do: value |> DateTime.from_naive!("Etc/UTC") |> ms()

  defp ms(value) when is_binary(value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, naive} -> ms(naive)
      _ -> nil
    end
  end

  defp ms(_value), do: nil

  # At most `max` bytes, cut on a character boundary.
  defp clip(nil, _max), do: ""

  defp clip(text, max) when is_binary(text),
    do: text |> binary_part(0, min(byte_size(text), max)) |> utf8_prefix()

  defp clip(_other, _max), do: ""

  defp utf8_prefix(text),
    do:
      if(String.valid?(text),
        do: text,
        else: utf8_prefix(binary_part(text, 0, byte_size(text) - 1))
      )
end
