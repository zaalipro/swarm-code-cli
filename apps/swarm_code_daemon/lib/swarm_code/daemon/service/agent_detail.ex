defmodule SwarmCode.Daemon.Service.AgentDetail do
  @moduledoc """
  pass72 S: the agent overlay's body for one agent (plan P8), built from the
  rows `PersistedProjection.agent_detail/3` read. Pure. Every string is
  bounded and scrubbed of ids, branch names and worktree paths
  (`PanelFacts.scrub/2`); what the domain does not record is omitted.
  """
  alias SwarmCode.Daemon.Service.PanelFacts

  @life_buckets 120
  @max_groups 200
  @max_items 12
  @max_ops 200
  @max_files 50
  @max_findings 20
  @open ~w(running retrying awaiting_approval awaiting_answer paused)
  @waiting_you ~w(awaiting_approval awaiting_answer)

  @group_kind %{
    "read_file" => :read,
    "grep" => :search,
    "find_files" => :search,
    "list_dir" => :explore,
    "lsp" => :explore,
    "git_status" => :explore,
    "git_diff" => :explore,
    "git_log" => :explore,
    "llm" => :think,
    "compact" => :think,
    "run_command" => :command,
    "edit_file" => :edit,
    "edit_files" => :edit,
    "write_file" => :edit,
    "move_file" => :edit,
    "delete_file" => :edit,
    "write_spec" => :edit,
    "git_commit" => :edit,
    "web_search" => :web,
    "web_fetch" => :web,
    "spawn_agent" => :agents,
    "message_agent" => :agents,
    "wait_for_message" => :agents,
    "agent_result" => :agents,
    "integrate_agent" => :agents,
    "inbox" => :agents,
    "ask_user" => :ask
  }

  @doc """
  The wire body. `rows` is `PersistedProjection.agent_detail/3`'s map; `opts`:
  `:request_id`, `:roots`, `:interactions` (this agent's pending interaction
  wire maps), `:model`, `:context_window`, `:now` (the clock in ms, which a
  live agent's life runs to while an operation is open).
  """
  def build(%{agent: n, ops: ops} = rows, opts) do
    roots = Enum.filter([n.workspace_path | opts[:roots] || []], &is_binary/1)
    interactions = opts[:interactions] || []
    facts = PanelFacts.agent(n, ops, roots: roots, interactions: interactions)
    {life, life_start, bucket} = life(n, ops, opts[:now])
    parent = Enum.find(rows.siblings, &(&1.id == n.parent_id))

    %{
      "state" => "idle",
      "request_id" => opts[:request_id],
      "run_id" => n.run_id,
      "agent_id" => n.id,
      "name" => PanelFacts.clip(n.name || "", 200),
      "role" => role(n),
      "model" => opts[:model] && PanelFacts.clip(opts[:model], 200),
      "panel_state" => facts["panel_state"],
      "now" => facts["now"],
      "parent_name" => parent && PanelFacts.clip(parent.name || "", 200),
      "brief" => PanelFacts.clip(PanelFacts.scrub_lines(n.prompt, roots), 4096),
      "brief_bytes" => byte_size(n.prompt || ""),
      "needs_you" =>
        PanelFacts.needs_you(interactions, %{n.id => %{"name" => n.name}}, parents(ops, n), roots),
      "findings" => findings(n.result_head, roots),
      "result" =>
        PanelFacts.clip(
          PanelFacts.scrub_lines(PanelFacts.structured_text(n.result, true), roots),
          8192
        ),
      "result_bytes" => n.result_bytes || 0,
      "error" => nil,
      "agent_error" =>
        if(is_binary(n.error) and n.error != "",
          do: PanelFacts.clip(PanelFacts.scrub(n.error, roots), 400)
        ),
      "activity" => activity(ops, roots),
      "operations" => operations(ops, roots),
      "life" => Enum.map(life, &Atom.to_string/1),
      "life_started_at" => life_start,
      "life_bucket_ms" => bucket,
      "think_ms" => think_ms(ops, life_end(n, ops, opts[:now])),
      "files_read" => files(ops, ["read_file"], roots),
      "files_searched" => files(ops, ["grep", "find_files"], roots),
      "files_changed" =>
        rows.changed
        |> Enum.map(&PanelFacts.clip(PanelFacts.scrub(&1, roots), 200))
        |> Enum.uniq()
        |> Enum.take(@max_files),
      "changes_stat" => n.changes_stat && PanelFacts.clip(n.changes_stat, 200),
      "tokens_in" => n.tokens_in || 0,
      "tokens_out" => n.tokens_out || 0,
      "cost_usd" => n.cost_usd,
      "context_used" => context_used(ops),
      "context_window" => opts[:context_window],
      "turn" => if(is_integer(n.max_turns) and n.max_turns > 0, do: n.turn),
      "max_turns" => if(is_integer(n.max_turns) and n.max_turns > 0, do: n.max_turns),
      "started_at" => PanelFacts.ms(n.started_at),
      "finished_at" => PanelFacts.ms(n.finished_at)
    }
  end

  defp role(%{role: "worker", name: "Judge" <> _}), do: "judge"
  defp role(%{role: role}) when role in ["lead", "sub", "worker", "assistant"], do: role
  defp role(_), do: "unknown"

  defp parents(ops, n), do: Map.new(ops, &{&1.id, n.id})

  ## --------------------------------------------------------------- findings

  @doc """
  The numbered findings of a result, first 20: a numbered list item (`1.`,
  `2)`) or a table row whose first cell is its number. Each keeps its first
  sentence (a leading severity label moves to `severity`, which is set only
  when the item leads with one or a table cell names one) and its first
  `path:line`. Bullets are not findings (they are notes, open issues, …).
  """
  def findings(result, roots) when is_binary(result) do
    result
    |> PanelFacts.structured_text()
    |> String.split(~r/\r?\n/u)
    |> Enum.flat_map(&finding_line/1)
    |> Enum.map(fn {severity, text, whole} ->
      {severity, PanelFacts.first_sentence(text, roots, 400), whole}
    end)
    |> Enum.reject(fn {_, sentence, _} -> is_nil(sentence) end)
    |> Enum.take(@max_findings)
    |> Enum.with_index(1)
    |> Enum.map(fn {{severity, sentence, whole}, n} ->
      %{
        "n" => n,
        "severity" => severity,
        "text" => sentence,
        "ref" => List.first(PanelFacts.finding_refs(whole, roots))
      }
    end)
  end

  def findings(_, _), do: []

  @severity ~r/^\W*(?:severity\W*)?(critical|blocker|severe|high|major|medium|moderate|low|minor|nit|trivial)\b\W*/iu

  defp finding_line(line) do
    cond do
      match = Regex.run(~r/^\s{0,3}\d{1,2}[.)]\s+(.+)$/u, line) ->
        text = List.last(match)

        case Regex.run(@severity, text) do
          [label, word] -> [{severity(word), String.replace_prefix(text, label, ""), text}]
          _ -> [{nil, text, text}]
        end

      match = Regex.run(~r/^\s*\|\s*\d{1,2}\s*\|(.+)\|\s*$/u, line) ->
        cells = match |> List.last() |> String.split("|") |> Enum.map(&String.trim/1)
        word = Enum.find(cells, &Regex.match?(~r/^\W*[a-z]+\W*$/iu, &1))
        severity = if word, do: severity(String.replace(word, ~r/\W/u, ""))
        text = cells |> Enum.reject(&(&1 == "")) |> List.last()
        if text, do: [{severity, text, Enum.join(cells, " ")}], else: []

      true ->
        []
    end
  end

  defp severity(word) do
    case String.downcase(word) do
      w when w in ~w(critical blocker severe high major) -> "high"
      w when w in ~w(medium moderate) -> "medium"
      w when w in ~w(low minor nit trivial) -> "low"
      _ -> nil
    end
  end

  ## --------------------------------------------------------------- activity

  @doc "Operations folded into activity groups, oldest first, at most 200 (the newest)."
  def activity(ops, roots) do
    ops
    |> Enum.flat_map(fn op -> said(op, roots) ++ [{kind(op), op}] end)
    |> Enum.chunk_while(
      nil,
      fn
        {kind, op}, {kind, ops} when kind in [:read, :search, :explore, :think, :web, :agents] ->
          {:cont, {kind, [op | ops]}}

        item, nil ->
          {:cont, start(item)}

        item, acc ->
          {:cont, acc, start(item)}
      end,
      fn
        nil -> {:cont, nil}
        acc -> {:cont, acc, nil}
      end
    )
    |> Enum.map(fn {kind, ops} -> group(kind, Enum.reverse(ops), roots) end)
    |> Enum.take(-@max_groups)
  end

  defp start({kind, op}), do: {kind, [op]}

  # A think that produced words: the words are the agent's own ("said"),
  # grouped on their own after the thought.
  defp said(%{op_type: "llm", status: "done", result: text} = op, roots)
       when is_binary(text) and text != "" do
    case PanelFacts.first_sentence(text, roots, 400) do
      nil -> []
      sentence -> [{:said, Map.put(op, :said, sentence)}]
    end
  end

  defp said(_, _), do: []

  defp kind(op), do: Map.get(@group_kind, op.op_type, :other)

  defp group(:said, [op], _roots) do
    base(:said, [op], "said", [])
    |> Map.merge(%{"quote" => op.said, "duration_ms" => 0})
  end

  defp group(kind, ops, roots) do
    n = length(ops)
    items = ops |> Enum.map(&item(&1, roots)) |> Enum.reject(&(&1 == "")) |> Enum.uniq()
    last = List.last(ops)

    {title, quote} =
      case kind do
        :read -> {"read #{count(items, n, "file")}", nil}
        :search -> {"searched #{count(items, n, "pattern")}", nil}
        :explore -> {"explored " <> Enum.map_join(Enum.take(items, 3), ", ", &place/1), nil}
        :think -> {if(n == 1, do: "thought", else: "thought ×#{n}"), thought(ops, roots)}
        :command -> command(last, List.first(items) || "a command")
        :edit -> {PanelFacts.doing(last, roots) |> past(), nil}
        :web -> {"looked on the web ×#{n}", nil}
        :agents -> {agents_title(ops, roots), nil}
        :ask -> {"asked you", nil}
        :other -> {PanelFacts.doing(last, roots), nil}
      end

    base(kind, ops, title, items)
    |> Map.put("quote", quote && PanelFacts.clip(quote, 400))
  end

  # pass72 G7 (QA Q8): a command says what became of it: asked, running,
  # blocked, denied, stopped, failed, or ran with its last output line.
  defp command(op, command) do
    error = Map.get(op, :error) || ""

    cond do
      op.status in @waiting_you ->
        {"asked to run " <> command, "waiting for your answer"}

      op.status in @open ->
        {"running " <> command, last_line(Map.get(op, :tail))}

      op.status == "failed" and String.starts_with?(error, "blocked") ->
        {"blocked: " <> command, PanelFacts.clip(error, 400)}

      op.status == "failed" and String.contains?(error, "denied") ->
        {"you denied " <> command, nil}

      op.status == "stopped" ->
        {"stopped " <> command, nil}

      op.status == "failed" and error != "" ->
        {"failed: " <> command, PanelFacts.clip(PanelFacts.scrub(error, []), 400)}

      true ->
        {"ran " <> command, last_line(Map.get(op, :tail))}
    end
  end

  defp base(kind, ops, title, items) do
    first = hd(ops)
    start = PanelFacts.ms(first.started_at) || 0
    finish = ops |> Enum.map(&(PanelFacts.ms(&1.finished_at) || start)) |> Enum.max()

    %{
      "kind" => Atom.to_string(kind),
      "title" => PanelFacts.clip(title, 200),
      "items" => items |> Enum.take(@max_items) |> Enum.map(&PanelFacts.clip(&1, 200)),
      "count" => length(ops),
      "started_at" => start,
      "duration_ms" => max(finish - start, 0),
      "quote" => nil,
      "state" => group_state(ops)
    }
  end

  defp group_state(ops) do
    cond do
      Enum.any?(ops, &(&1.status in @waiting_you)) -> "waiting"
      Enum.any?(ops, &(&1.status in @open)) -> "running"
      Enum.any?(ops, &(&1.status == "failed")) -> "failed"
      true -> "done"
    end
  end

  defp count(items, n, noun) do
    k = max(length(items), if(items == [], do: n, else: 0))
    "#{k} #{noun}#{if k == 1, do: "", else: "s"}"
  end

  defp item(%{op_type: "run_command", title: "run: " <> command}, roots),
    do: command |> String.replace(~r/ \(in [^)]*\)$/u, "") |> PanelFacts.scrub(roots)

  defp item(%{op_type: type, title: title}, roots) when type in ["grep", "find_files"] do
    case String.split(title || "", " ", parts: 2) do
      [_, pattern] -> ~s(") <> PanelFacts.scrub(pattern, roots) <> ~s(")
      _ -> ""
    end
  end

  defp item(%{title: title}, roots) do
    case String.split(title || "", " ", parts: 2) do
      [_, rest] -> PanelFacts.scrub(rest, roots)
      [one] -> PanelFacts.scrub(one, roots)
    end
  end

  defp thought(ops, roots) do
    ops
    |> Enum.reverse()
    |> Enum.find_value(&PanelFacts.first_sentence(&1.detail, roots, 400))
  end

  defp agents_title(ops, roots) do
    case Enum.filter(ops, &(&1.op_type == "spawn_agent")) do
      [] -> PanelFacts.doing(List.last(ops), roots)
      spawned -> "started #{length(spawned)} agent#{if length(spawned) == 1, do: "", else: "s"}"
    end
  end

  defp place("."), do: "the project"
  defp place("./"), do: "the project"
  defp place(path), do: path

  # "editing lib/y.ex" → "edited lib/y.ex"
  defp past("editing " <> rest), do: "edited " <> rest
  defp past("writing " <> rest), do: "wrote " <> rest
  defp past("moving " <> rest), do: "moved " <> rest
  defp past("deleting " <> rest), do: "deleted " <> rest
  defp past("committing"), do: "committed"
  defp past(other), do: other

  defp last_line(text) when is_binary(text) do
    text
    |> String.split(~r/\r?\n/u)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> List.last()
    |> case do
      nil -> nil
      line -> PanelFacts.clip(PanelFacts.scrub(line, []), 400)
    end
  end

  defp last_line(_), do: nil

  ## ------------------------------------------------------------- operations

  defp operations(ops, roots) do
    ops
    |> Enum.take(-@max_ops)
    |> Enum.map(fn op ->
      start = PanelFacts.ms(op.started_at)
      finish = PanelFacts.ms(op.finished_at)

      %{
        "id" => op.id,
        "op_type" => PanelFacts.clip(op.op_type || "op", 64),
        "title" => PanelFacts.clip(PanelFacts.scrub(op.title || "", roots), 200),
        "status" => op_status(op.status),
        "started_at" => start,
        "duration_ms" => if(start && finish, do: max(finish - start, 0))
      }
    end)
  end

  defp op_status(status) when status in @waiting_you, do: "waiting"
  defp op_status(status) when status in ["running", "retrying", "paused"], do: "running"
  defp op_status(status) when status in ["done", "failed", "stopped", "queued"], do: status
  defp op_status(_), do: "done"

  ## ------------------------------------------------------------------ life

  # The whole life on an absolute axis: at most 120 buckets of whole seconds.
  defp life(n, ops, now) do
    start =
      PanelFacts.ms(n.started_at) || ops |> Enum.map(&PanelFacts.ms(&1.started_at)) |> min_int()

    finish = life_end(n, ops, now)

    if is_integer(start) and is_integer(finish) and finish > start do
      span = finish - start
      bucket = max(div(span + @life_buckets - 1, @life_buckets), 1_000) |> round_up(1_000)
      count = div(span + bucket - 1, bucket)
      end_ms = start + count * bucket
      {PanelFacts.lane(ops, end_ms, count, bucket), start, bucket}
    else
      {[], nil, 0}
    end
  end

  # pass72 G6 (QA Q5): a live agent's life runs to the caller's clock while
  # an operation is open, so a wait on you is drawn (▒) for as long as it
  # lasts rather than ending where the wait began.
  defp life_end(n, ops, now) do
    case PanelFacts.ms(n.finished_at) do
      nil ->
        anchor = PanelFacts.anchor(ops)

        if is_integer(now) and is_integer(anchor) and Enum.any?(ops, &(&1.status in @open)),
          do: max(anchor, now),
          else: anchor

      finish ->
        finish
    end
  end

  defp round_up(value, unit), do: div(value + unit - 1, unit) * unit

  defp min_int(values) do
    case Enum.filter(values, &is_integer/1) do
      [] -> nil
      list -> Enum.min(list)
    end
  end

  defp think_ms(_ops, nil), do: 0

  defp think_ms(ops, end_ms) do
    ops
    |> Enum.filter(&(&1.op_type in ["llm", "compact"]))
    |> Enum.map(fn op ->
      s = PanelFacts.ms(op.started_at)
      f = if op.status in @open, do: end_ms, else: PanelFacts.ms(op.finished_at)
      if is_integer(s) and is_integer(f), do: max(f - s, 0), else: 0
    end)
    |> Enum.sum()
  end

  ## ------------------------------------------------------------------ files

  defp files(ops, types, roots) do
    ops
    |> Enum.filter(&(&1.op_type in types))
    |> Enum.map(&item(&1, roots))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.take(@max_files)
    |> Enum.map(&PanelFacts.clip(&1, 200))
  end

  # The context the agent last sent: its newest think's input tokens.
  defp context_used(ops) do
    ops
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{op_type: "llm", tokens_in: n} when is_integer(n) and n > 0 -> n
      _ -> nil
    end)
  end
end
