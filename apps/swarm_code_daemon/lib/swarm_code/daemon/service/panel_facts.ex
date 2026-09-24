defmodule SwarmCode.Daemon.Service.PanelFacts do
  @moduledoc """
  pass72 S: the side panel's facts about an agent and a run, derived from what
  the domain records (node rows, their operations, pending interactions) and
  nothing else. Pure: the caller passes the clock.

  Every sentence is plain words with a verb, bounded in bytes, and scrubbed of
  ids, branch names and worktree paths (the owner's pass-70 bug: an agent's
  row read "isolated in swarm/2404157a/…"). What the domain does not record
  is omitted, never estimated (plan P5).

  Operations are maps with `:parent_id`, `:op_type`, `:status`, `:title`,
  `:detail`, `:started_at` and `:finished_at` (`DateTime` or nil).
  """

  @cell_ms 5_000
  @cells 12
  @now_bytes 80
  @finding_bytes 160
  @max_refs 5

  @open ~w(running retrying awaiting_approval awaiting_answer paused)
  @waiting_you ~w(awaiting_approval awaiting_answer)
  # Ops that change files: a lane cell they dominate is a write (`█`).
  @writes ~w(edit_file edit_files write_file move_file delete_file write_spec git_commit)
  # Ops that only wait for other agents: idle in the lane, "waiting" as a state.
  @others ~w(spawn_agent wait_for_message)
  @think ~w(llm compact)
  # A tie between kinds in one cell goes to the one that matters most to the user.
  @priority [:wait_you, :write, :tools, :think]

  @type kind :: :think | :tools | :write | :wait_you | :idle

  def cell_ms, do: @cell_ms
  def cells, do: @cells

  @doc """
  The panel facts of one agent row, as wire keys. `ops` are the agent's own
  newest operations (every open one among them), `opts`: `:interactions` (the
  pending interaction wire maps that belong to this agent), `:files_changed`,
  `:roots` (path prefixes to strip: the project root, the agent's worktree).

  The lane is anchored at the agent's last recorded event (rounded up to a
  cell boundary), never at the clock, so a body only changes when the
  database does; a client rolls it forward to its own clock with `lane_now`
  (`SwarmCodeCLI.UI.DataSource.Lane`).
  """
  def agent(n, ops, opts) do
    roots = roots(opts[:roots])
    interactions = opts[:interactions] || []
    state = state(n, ops, interactions)
    finding = if n.status == "done", do: finding(Map.get(n, :result_head), roots)
    lane_at = anchor(ops)
    live? = state not in [:done, :failed, :stopped, :queued] and is_integer(lane_at)

    %{
      "panel_state" => Atom.to_string(state),
      "now" => now(state, n, ops, interactions, finding, roots),
      "lane" =>
        if(live?, do: Enum.map(lane(ops, lane_at, @cells, @cell_ms), &Atom.to_string/1), else: []),
      "lane_at" => if(live?, do: lane_at),
      "lane_now" => Atom.to_string(if(live?, do: lane_now(ops), else: :idle)),
      "finding" => finding,
      "finding_refs" =>
        if(n.status == "done", do: finding_refs(Map.get(n, :result_head), roots), else: []),
      "files_changed" => opts[:files_changed] || 0,
      "elapsed_ms" => elapsed_ms(n),
      "tokens" => (n.tokens_in || 0) + (n.tokens_out || 0)
    }
  end

  ## ------------------------------------------------------------------ state

  @doc "The one P3 state of an agent row."
  def state(n, ops, interactions) do
    open = Enum.filter(ops, &(&1.status in @open))

    cond do
      n.status in @waiting_you or interactions != [] or
          Enum.any?(open, &(&1.status in @waiting_you)) ->
        :needs_you

      n.status == "done" ->
        :done

      n.status == "failed" ->
        :failed

      n.status == "stopped" ->
        :stopped

      n.status == "queued" ->
        :queued

      n.status == "paused" ->
        :paused

      Enum.any?(open, &(&1.op_type not in @others and &1.op_type not in @think)) ->
        :working

      Enum.any?(open, &(&1.op_type in @think)) ->
        :thinking

      Enum.any?(open, &(&1.op_type in @others)) ->
        :waiting

      true ->
        :working
    end
  end

  defp elapsed_ms(%{started_at: %DateTime{} = s, finished_at: %DateTime{} = f}),
    do: max(DateTime.diff(f, s, :millisecond), 0)

  defp elapsed_ms(_), do: nil

  ## -------------------------------------------------------------------- now

  @doc "One plain sentence with a verb for the agent's row (R2), at most 80 bytes."
  def now(state, n, ops, interactions, finding, roots) do
    text =
      case state do
        :needs_you -> asks(interactions, ops, roots)
        :failed -> failure(n, roots)
        :stopped -> "stopped"
        :done -> finding || "done"
        :queued -> "queued"
        :paused -> "paused"
        :waiting -> waiting(ops)
        :thinking -> thought(ops, roots)
        :working -> working(ops, roots)
      end

    clip(text, @now_bytes)
  end

  defp asks([%{"kind" => "question"} | _], _ops, _roots), do: "has a question for you"

  defp asks([%{"approval" => %{"tool" => tool} = card} | _], _ops, roots),
    do: wants(tool, card["arguments_preview"], roots)

  defp asks(_none, ops, roots) do
    case Enum.find(newest_first(ops), &(&1.status in @waiting_you)) do
      %{status: "awaiting_answer"} -> "has a question for you"
      %{op_type: type} = op -> wants(type, nil, roots, op)
      nil -> "waiting for you"
    end
  end

  defp wants(tool, args, roots, op \\ nil) do
    path =
      case decode(args) do
        %{"path" => p} when is_binary(p) and p != "" -> scrub(p, roots)
        _ -> op && title_rest(op.title, roots)
      end

    case tool do
      "run_command" -> "wants to run a command"
      t when t in ["edit_file", "write_file"] and is_binary(path) -> "wants to edit " <> path
      t when t in @writes -> "wants to change files"
      "ask_user" -> "has a question for you"
      t when is_binary(t) -> "wants to use " <> humanize(t)
      _ -> "waiting for you"
    end
  end

  defp failure(n, roots) do
    case first_sentence(n.error, roots) do
      nil -> "failed"
      text -> "failed: " <> text
    end
  end

  defp waiting(ops) do
    open = Enum.filter(ops, &(&1.status in @open))
    spawned = Enum.filter(open, &(&1.op_type == "spawn_agent"))

    case spawned do
      [op] ->
        case title_rest(op.title, []) do
          name when is_binary(name) and name != "" -> "waiting on " <> name
          _ -> "waiting on 1 agent"
        end

      [_ | _] ->
        "waiting on #{length(spawned)} agents"

      [] ->
        if Enum.any?(open, &(&1.op_type == "wait_for_message")),
          do: "waiting for a message",
          else: "waiting"
    end
  end

  # The newest reasoning: an open think streams its tail (its last complete
  # sentence is the freshest), a finished one keeps its opening. A think that
  # has not said a sentence yet falls back to the one before it.
  defp thought(ops, roots) do
    ops
    |> newest_first()
    |> Enum.filter(&(&1.op_type == "llm"))
    |> Enum.find_value("thinking", fn op ->
      if op.status in @open,
        do: last_sentence(op.detail, roots),
        else: first_sentence(op.detail, roots)
    end)
  end

  defp working(ops, roots) do
    case Enum.find(newest_first(ops), &(&1.status in @open and &1.op_type not in @think)) do
      nil -> "working"
      op -> doing(op, roots)
    end
  end

  @doc "What an operation is doing, as a present-participle phrase."
  def doing(%{op_type: type, title: title} = _op, roots) do
    rest = title_rest(title, roots)

    phrase =
      case type do
        "read_file" -> "reading " <> (rest || "a file")
        "grep" -> ~s(searching ") <> (rest || "") <> ~s(")
        "find_files" -> ~s(finding files ") <> (rest || "") <> ~s(")
        "list_dir" -> "listing " <> (rest || ".")
        "run_command" -> command_phrase(title, roots)
        "edit_file" -> "editing " <> (rest || "a file")
        "edit_files" -> "editing " <> (rest || "files")
        "write_file" -> "writing " <> (rest || "a file")
        "move_file" -> "moving " <> (rest || "a file")
        "delete_file" -> "deleting " <> (rest || "a file")
        "web_search" -> "searching the web for " <> (rest || "")
        "web_fetch" -> "fetching " <> host(rest)
        "git_status" -> "checking git status"
        "git_diff" -> "reading the git diff"
        "git_log" -> "reading the git log"
        "git_commit" -> "committing"
        "lsp" -> "asking the language server"
        "message_agent" -> "messaging " <> (rest || "an agent")
        "inbox" -> "checking its inbox"
        "remember" -> "saving a memory"
        "ask_user" -> "asking you a question"
        "submit_plan" -> "submitting a plan"
        "write_spec" -> "writing a spec"
        "agent_result" -> "reading an agent's result"
        "integrate_agent" -> "integrating an agent's changes"
        "start_swarm" -> "starting a swarm"
        "compact" -> "compacting its context"
        "workflow_" <> _ -> "working on a workflow"
        other when is_binary(other) -> "using " <> humanize(other)
        _ -> "working"
      end

    phrase |> String.trim() |> clip(@now_bytes)
  end

  defp command_phrase(title, roots) do
    case title do
      "poll background process" <> _ ->
        "checking a background command"

      "stop background process" <> _ ->
        "stopping a background command"

      "run: " <> command ->
        "running " <> (command |> String.replace(~r/ \(in [^)]*\)$/, "") |> scrub(roots))

      _ ->
        "running a command"
    end
  end

  # A tool title is "<verb> <object>"; the object is what the sentence needs.
  defp title_rest(title, roots) when is_binary(title) do
    case String.split(title, " ", parts: 2) do
      [_verb, rest] ->
        case scrub(rest, roots) do
          "" -> nil
          text -> text
        end

      _ ->
        nil
    end
  end

  defp title_rest(_, _), do: nil

  defp host(nil), do: "a page"

  defp host(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> "a page"
    end
  end

  defp humanize(name), do: name |> String.replace(~r/[_.]+|__/, " ") |> String.trim()

  ## ------------------------------------------------------------------- lane

  @doc """
  `cells` activity kinds covering `[end_ms - cells * cell_ms, end_ms)`, oldest
  first. A cell takes the kind that overlaps it longest (ties by `@priority`),
  else `:idle`. An open op runs until `end_ms`; an op waiting on the user is
  `:wait_you`; ops that only wait on other agents are idle.
  """
  def lane(ops, end_ms, cells, cell_ms) do
    start = end_ms - cells * cell_ms

    spans =
      for op <- ops,
          kind = kind(op),
          kind != :idle,
          s = ms(op.started_at),
          is_integer(s),
          f = span_end(op, end_ms),
          f > start and s < end_ms,
          do: {kind, max(s, start), min(f, end_ms)}

    for i <- 0..(cells - 1) do
      a = start + i * cell_ms
      b = a + cell_ms

      spans
      |> Enum.reduce(%{}, fn {kind, s, f}, acc ->
        overlap = min(f, b) - max(s, a)
        if overlap > 0, do: Map.update(acc, kind, overlap, &(&1 + overlap)), else: acc
      end)
      |> dominant()
    end
  end

  defp dominant(map) when map_size(map) == 0, do: :idle

  defp dominant(map) do
    best = map |> Map.values() |> Enum.max()
    Enum.find(@priority, &(Map.get(map, &1) == best))
  end

  @doc "The cell boundary at or after an agent's last recorded op event, nil without ops."
  def anchor(ops) do
    ops
    # An open op is still going on after its start: its cell is in the window.
    |> Enum.flat_map(fn op ->
      open = if op.status in @open and is_integer(ms(op.started_at)), do: ms(op.started_at) + 1
      [ms(op.started_at), ms(op.finished_at), open]
    end)
    |> Enum.filter(&is_integer/1)
    |> Enum.max(fn -> nil end)
    |> case do
      nil -> nil
      last -> div(last + @cell_ms - 1, @cell_ms) * @cell_ms
    end
  end

  @doc "The kind still going on now (what a client rolls the lane forward with)."
  def lane_now(ops) do
    kinds = for op <- ops, op.status in @open, do: kind(op)
    Enum.find(@priority, :idle, &(&1 in kinds))
  end

  @doc "The lane kind of one operation."
  def kind(%{status: status}) when status in @waiting_you, do: :wait_you
  def kind(%{op_type: "ask_user"}), do: :wait_you
  def kind(%{op_type: type}) when type in @think, do: :think
  def kind(%{op_type: type}) when type in @writes, do: :write
  def kind(%{op_type: type}) when type in @others, do: :idle
  def kind(%{op_type: type}) when is_binary(type), do: :tools
  def kind(_), do: :idle

  defp span_end(%{status: status}, end_ms) when status in @open, do: end_ms

  defp span_end(op, end_ms) do
    case ms(op.finished_at) do
      nil -> end_ms
      f -> f
    end
  end

  def ms(%DateTime{} = t), do: DateTime.to_unix(t, :millisecond)
  def ms(%NaiveDateTime{} = t), do: t |> DateTime.from_naive!("Etc/UTC") |> ms()
  def ms(_), do: nil

  ## ---------------------------------------------------------------- finding

  @doc "The first sentence of an agent's result (≤ 160 bytes), else nil."
  def finding(result, roots \\ []) do
    case first_sentence(without_engine_notes(result), roots(roots), @finding_bytes + 40) do
      nil ->
        nil

      sentence ->
        # A leading severity label ("medium", "**High:**") is the overlay's
        # column, not the sentence.
        sentence
        |> String.replace(
          ~r/^\W*(?:severity\W*)?(critical|blocker|severe|high|major|medium|moderate|low|minor|nit|trivial)\b[\s:*\-–—]*/iu,
          ""
        )
        |> blank_nil()
        |> then(&(&1 && clip(&1, @finding_bytes)))
    end
  end

  # The engine appends its own notes to a worker's report ("[Changes on branch
  # swarm/… (…). Integrate them …]", "[No file changes.]", "Delta patch
  # captured: …"); they are not what the agent found (pass72 F, P's request 2).
  defp without_engine_notes(result) when is_binary(result) do
    result
    |> String.split(~r/\r?\n/u)
    |> Enum.reject(fn line ->
      line = String.trim(line)

      String.starts_with?(line, ["[Changes on branch ", "[No file changes.]"]) or
        String.starts_with?(line, "Delta patch captured")
    end)
    |> Enum.join("\n")
  end

  defp without_engine_notes(result), do: result

  @doc "Up to five `path:line` references cited by a result, in order, unique."
  def finding_refs(result, roots \\ [])

  def finding_refs(result, roots) when is_binary(result) do
    ~r/(?<![\w\/.\-])((?:[\w.\-]+\/)*[\w\-][\w.\-]*\.[A-Za-z][A-Za-z0-9]{0,7}):(\d{1,6})/u
    |> Regex.scan(scrub(result, roots(roots)))
    |> Enum.map(fn [_, path, line] -> path <> ":" <> line end)
    |> Enum.reject(&String.contains?(&1, "://"))
    |> Enum.uniq()
    |> Enum.take(@max_refs)
    |> Enum.map(&clip(&1, 200))
  end

  def finding_refs(_, _), do: []

  ## ---------------------------------------------------------------- run facts

  @doc """
  What waits on the user in a run, oldest first: the interaction wire maps of
  the run, `agents_by_id` (wire agent maps) and `op_parent` (`%{op_id =>
  agent_id}`) to name the agent.
  """
  def needs_you(interactions, agents_by_id, op_parent, roots \\ []) do
    roots = roots(roots)

    interactions
    |> Enum.uniq_by(&{&1["node_id"], &1["kind"]})
    |> Enum.map(fn i -> needs_you_item(i, agents_by_id, op_parent, roots) end)
    |> Enum.sort_by(& &1["requested_at"])
    |> Enum.take(20)
  end

  defp needs_you_item(%{"kind" => "approval", "approval" => card} = i, agents, parents, roots) do
    agent_id = card["agent_id"] || parents[i["node_id"]] || i["node_id"]
    agent = agents[agent_id]

    %{
      "agent_id" => agent && agent_id,
      "node_id" => i["node_id"],
      "agent_name" => clip((agent && agent["name"]) || card["agent_name"] || "", 200),
      "kind" => "approval",
      "text" => clip(approval_text(card, roots), 1024),
      "reason" => clip(scrub(card["reason"] || "", roots), 512),
      "requested_at" => card["requested_at"] || i["created_at"] || 0
    }
  end

  defp needs_you_item(%{"kind" => "question"} = i, agents, parents, _roots) do
    agent_id = parents[i["node_id"]] || i["node_id"]
    agent = agents[agent_id]
    prompt = get_in(i, ["question", "prompt"]) || ""

    %{
      "agent_id" => agent && agent_id,
      "node_id" => i["node_id"],
      "agent_name" => clip((agent && agent["name"]) || "", 200),
      "kind" => "question",
      "text" => clip(literal(prompt), 1024),
      "reason" => "",
      "requested_at" => i["created_at"] || 0
    }
  end

  # The literal request: the command itself, else the tool and its path.
  defp approval_text(card, roots) do
    args = decode(card["arguments_preview"])
    command = card["command"] || (card["tool"] == "run_command" && args["command"])

    cond do
      # The command is the literal request the user answers: kept whole,
      # only its control characters and runs of whitespace fold to spaces.
      is_binary(command) and command != "" ->
        literal(command)

      is_binary(args["path"]) ->
        (verb(card["tool"]) <> " " <> scrub(args["path"], roots)) |> String.trim()

      true ->
        humanize(card["tool"] || "agent operation")
    end
  end

  defp verb("edit_file"), do: "edit"
  defp verb("write_file"), do: "write"
  defp verb("delete_file"), do: "delete"
  defp verb(tool) when is_binary(tool), do: humanize(tool)
  defp verb(_), do: ""

  @doc """
  A workflow's phases as it records them (`phases`, the current `phase`) with
  the agents that ran in each (their `phase` column), for a run `status`.
  """
  def phases(%{phases: [_ | _] = names, phase: current}, agents, run_status) do
    index = Enum.find_index(names, &(&1 == current))

    names
    |> Enum.take(20)
    |> Enum.with_index()
    |> Enum.map(fn {name, i} ->
      mine = Enum.filter(agents, &(Map.get(&1, :phase) == name))

      %{
        "name" => clip(name, 120),
        "state" => phase_state(i, index, run_status),
        "agent_count" => length(mine),
        "live" => Enum.count(mine, &(&1.status in @open)),
        "done" => Enum.count(mine, &(&1.status == "done"))
      }
    end)
  end

  def phases(_wf, _agents, _status), do: []

  defp phase_state(_i, nil, "done"), do: "done"
  defp phase_state(_i, nil, _), do: "queued"
  defp phase_state(i, index, "done") when i <= index, do: "done"
  defp phase_state(i, index, _) when i < index, do: "done"
  defp phase_state(i, i, "waiting_user"), do: "waiting"
  defp phase_state(i, i, "paused"), do: "paused"
  defp phase_state(i, i, status) when status in ["failed", "interrupted", "stopped"], do: "failed"
  defp phase_state(i, i, _), do: "running"
  defp phase_state(_, _, _), do: "queued"

  ## ------------------------------------------------------------------- text

  @doc "Strip roots, worktree paths, branch names and ids; collapse whitespace."
  def scrub(text, roots) when is_binary(text) do
    text =
      Enum.reduce(roots(roots), text, fn root, acc ->
        String.replace(acc, root <> "/", "") |> String.replace(root, ".")
      end)

    text
    |> String.replace(
      ~r/(?:[^\s"'(`]*\/)?\.swarm_code\/worktrees\/(?:[0-9a-f]{8}\/)?[^\/\s`]+\/?/u,
      ""
    )
    |> String.replace(~r/\bisolated in \S+/u, "")
    |> String.replace(~r/\bswarm\/[0-9a-f]{6,}\/[\w.\-]+/u, "")
    |> String.replace(
      ~r/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/iu,
      ""
    )
    |> String.replace(~r/[\x00-\x1F\x7F]+/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  def scrub(_, _), do: ""

  @doc """
  `scrub/2` for a multi-line text (a brief, a result): the same removals, but
  newlines and indentation stay; other control characters go.
  """
  def scrub_lines(text, roots) when is_binary(text) do
    text =
      Enum.reduce(roots(roots), text, fn root, acc ->
        String.replace(acc, root <> "/", "") |> String.replace(root, ".")
      end)

    text
    |> String.replace(
      ~r/(?:[^\s"'(`]*\/)?\.swarm_code\/worktrees\/(?:[0-9a-f]{8}\/)?[^\/\s`]+\/?/u,
      ""
    )
    |> String.replace(~r/\bisolated in \S+/u, "")
    |> String.replace(~r/\bswarm\/[0-9a-f]{6,}\/[\w.\-]+/u, "")
    |> String.replace(
      ~r/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/iu,
      ""
    )
    |> String.replace(~r/\r\n?/u, "\n")
    |> String.replace(~r/[\x00-\x08\x0B-\x1F\x7F]/u, "")
    |> String.trim()
  end

  def scrub_lines(_, _), do: ""

  defp literal(text) when is_binary(text),
    do: text |> String.replace(~r/[\x00-\x1F\x7F\s]+/u, " ") |> String.trim()

  defp literal(_), do: ""

  @doc "The first real sentence of a text (headings, rules and bullets skipped)."
  def first_sentence(text, roots, max \\ @now_bytes)

  def first_sentence(text, roots, max) when is_binary(text) do
    text
    |> String.slice(0, 4_000)
    |> String.split(~r/\r?\n/u)
    |> Enum.reject(&heading?/1)
    |> Enum.map(&plain_line/1)
    |> Enum.find(&(String.length(&1) >= 8 and not String.ends_with?(&1, ":")))
    |> case do
      nil ->
        nil

      line ->
        line
        |> sentence_head()
        |> scrub(roots(roots))
        |> blank_nil()
        |> then(&(&1 && clip(&1, max)))
    end
  end

  def first_sentence(_, _, _), do: nil

  defp last_sentence(text, roots) when is_binary(text) do
    text
    |> String.split(~r/(?<=[.!?])\s+/u)
    |> Enum.map(&plain_line/1)
    |> Enum.filter(&(String.length(&1) >= 8 and String.match?(&1, ~r/[.!?]$/u)))
    |> List.last()
    |> case do
      nil -> nil
      line -> line |> scrub(roots) |> blank_nil() |> then(&(&1 && clip(&1, @now_bytes)))
    end
  end

  defp last_sentence(_, _), do: nil

  # A heading, a rule or a bold-only label names a section; it is no finding.
  defp heading?(line) do
    line = String.trim(line)

    String.starts_with?(line, "#") or String.match?(line, ~r/^([-*_=]\s*){3,}$/u) or
      String.match?(line, ~r/^\*\*[^*]+\*\*:?$/u)
  end

  defp plain_line(line) do
    line
    |> String.replace(~r/^\s*(?:#+|[-*+>]|\d+[.)])\s+/u, "")
    |> String.replace(~r/\*\*|__|`/u, "")
    |> String.trim()
  end

  defp sentence_head(line) do
    case Regex.run(~r/^(.+?[.!?])(?:\s|$)/u, line) do
      [_, head] -> head
      _ -> line
    end
  end

  defp blank_nil(""), do: nil
  defp blank_nil(text), do: text

  @doc "Cut `text` to at most `max` bytes on a character boundary, with `…` when cut."
  def clip(text, max) when is_binary(text) do
    if byte_size(text) <= max do
      text
    else
      text |> take_bytes(max - 3) |> String.trim_trailing() |> Kernel.<>("…")
    end
  end

  def clip(_, _), do: ""

  defp take_bytes(text, max) do
    text
    |> String.codepoints()
    |> Enum.reduce_while({[], 0}, fn cp, {acc, size} ->
      if size + byte_size(cp) <= max,
        do: {:cont, {[cp | acc], size + byte_size(cp)}},
        else: {:halt, {acc, size}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp newest_first(ops),
    do: Enum.sort_by(ops, &(ms(&1.started_at) || 0), :desc)

  defp decode(text) when is_binary(text) and byte_size(text) <= 65_536 do
    case Jason.decode(text) do
      {:ok, %{} = map} -> map
      _ -> %{}
    end
  end

  defp decode(_), do: %{}

  defp roots(nil), do: []

  defp roots(roots) when is_list(roots),
    do:
      roots
      |> Enum.filter(&(is_binary(&1) and byte_size(&1) > 1))
      |> Enum.map(&String.trim_trailing(&1, "/"))
      |> Enum.uniq()
      |> Enum.sort_by(&byte_size/1, :desc)
end
