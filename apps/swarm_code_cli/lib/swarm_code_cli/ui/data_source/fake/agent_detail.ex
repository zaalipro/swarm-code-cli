defmodule SwarmCodeCLI.UI.DataSource.Fake.AgentDetail do
  @moduledoc """
  pass72 S (fake parity): the agent overlay's detail for a synthetic agent,
  built from the script's own facts (the agent summary, its transcript tool
  items, its changes and the run's pending interactions), shaped like the
  daemon's `AgentDetail`. Pure.
  """
  alias SwarmCodeCLI.UI.DataSource.{DTO, Request}

  @kinds %{
    "read_file" => :read,
    "grep" => :search,
    "find_files" => :search,
    "list_dir" => :explore,
    "run_command" => :command,
    "edit_file" => :edit,
    "write_file" => :edit
  }

  @briefs %{
    "lead" => "Coordinate the authentication review across three reviewers and a builder.",
    "scout-1" => "Map every call site that reads or refreshes a session token.",
    "scout-2" => "Read the session tests and say which refresh paths they cover.",
    "builder-4" =>
      "Harden the token refresh path in lib/swarm_code/repo.ex; keep the tests green.",
    "judge" => "Judge the three proposals against the review checklist."
  }

  @findings %{
    "scout-1" => [
      {:high, "Refresh tokens are read in three places, all through Repo.",
       "lib/swarm_code/repo.ex:41"},
      {:medium, "The session plug refreshes without a lock.", "lib/swarm_code/session.ex:88"}
    ]
  }

  def query(script, %Request{kind: {:agent_detail, run_id, node_id}} = request) do
    with %DTO.AgentSummary{run_id: ^run_id} = agent <- Map.get(script.agents, node_id),
         %DTO.RunSummary{} = run <- Map.get(script.runs, run_id),
         true <- in_scope?(request.scope, run) do
      {:ok, build(script, agent, run, request.request_id)}
    else
      _ -> {:error, :not_allowed}
    end
  end

  defp in_scope?(%{kind: :conversation, id: id}, run), do: run.conversation_id == id
  defp in_scope?(%{kind: :run, id: id}, run), do: run.id == id
  defp in_scope?(_, _), do: false

  defp build(script, agent, run, request_id) do
    tools =
      script.transcript
      |> Map.values()
      |> Enum.filter(&(&1.agent_id == agent.id and &1.kind == :tool and &1.tool != nil))
      |> Enum.sort_by(&{&1.at, &1.id})

    parent = agent.parent_id && Map.get(script.agents, agent.parent_id)

    changed =
      script.changes
      |> Map.values()
      |> Enum.filter(&(&1.agent_id == agent.id))
      |> Enum.sort_by(& &1.at)
      |> Enum.map(& &1.path)

    %DTO.AgentDetail{
      state: :idle,
      request_id: request_id,
      run_id: run.id,
      agent_id: agent.id,
      name: agent.name,
      role: agent.role,
      model: agent.model || run.model,
      panel_state: agent.panel_state,
      now: agent.now,
      parent_name: parent && parent.name,
      brief: Map.get(@briefs, agent.name, agent.title),
      brief_bytes: byte_size(Map.get(@briefs, agent.name, agent.title)),
      needs_you: Enum.filter(run.needs_you, &(&1.agent_id == agent.id)),
      findings: findings(agent.name),
      result: agent.finding || "",
      result_bytes: byte_size(agent.finding || ""),
      agent_error: agent.error,
      activity: Enum.map(tools, &group/1),
      operations: Enum.map(tools, &op_line/1),
      life: agent.lane,
      life_started_at: agent.started_at,
      life_bucket_ms: if(agent.lane == [], do: 0, else: 5_000),
      think_ms: 5_000 * Enum.count(agent.lane, &(&1 == :think)),
      files_read: files(tools, ["read_file"]),
      files_searched: files(tools, ["grep", "find_files"]),
      files_changed: changed,
      changes_stat: agent.changes_stat,
      tokens_in: agent.tokens_in,
      tokens_out: agent.tokens_out,
      cost_usd: agent.cost_usd,
      context_used: if(agent.tokens_in > 0, do: agent.tokens_in),
      context_window: 98_304,
      started_at: agent.started_at,
      finished_at: agent.finished_at
    }
  end

  defp findings(name) do
    @findings
    |> Map.get(name, [])
    |> Enum.with_index(1)
    |> Enum.map(fn {{severity, text, ref}, n} ->
      %DTO.Finding{n: n, severity: severity, text: text, ref: ref}
    end)
  end

  defp group(%DTO.TranscriptItem{tool: tool} = item) do
    kind = Map.get(@kinds, tool.name, :other)

    %DTO.ActivityGroup{
      kind: kind,
      title: tool.title,
      items: tool.files,
      count: 1,
      started_at: tool.started_at || item.at,
      duration_ms: tool.duration_ms || 0,
      quote: if(kind == :command, do: tool.detail),
      state: state(tool.status)
    }
  end

  defp op_line(%DTO.TranscriptItem{tool: tool} = item) do
    %DTO.OpLine{
      id: item.id,
      op_type: tool.name,
      title: tool.title,
      status:
        case state(tool.status) do
          :waiting -> :waiting
          other -> other
        end,
      started_at: tool.started_at,
      duration_ms: tool.duration_ms
    }
  end

  defp state(status) when status in [:waiting_question, :waiting_approval], do: :waiting
  defp state(status) when status in [:done, :failed], do: status
  defp state(status) when status in [:stopped, :interrupted, :superseded], do: :failed
  defp state(_), do: :running

  defp files(tools, names),
    do:
      tools
      |> Enum.filter(&(&1.tool.name in names))
      |> Enum.flat_map(& &1.tool.files)
      |> Enum.uniq()
end
