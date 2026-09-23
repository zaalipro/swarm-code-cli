defmodule SwarmCode.Domain.Engine.Prompts do
  @moduledoc "System prompts and history conversion."

  alias SwarmCode.Domain.Conversations.Message
  alias SwarmCode.Domain.Projects.Project

  @plan_mode "PLAN MODE: do not modify anything. Explore with the read-only tools only " <>
               "(read_file, list_dir, grep, web_search, web_fetch) and produce a concrete, " <>
               "numbered, step-by-step plan with file paths. Do not write files, edit files " <>
               "or run commands. End with a short \"## Open questions\" section."

  @doc """
  The lines every agent of a conversation gets appended to its system prompt:
  the conversation goal (`/goal`), the project instructions (AGENTS.md), the
  saved memory and, in plan mode, the read-only instruction.

  `opts` accepts `:goal`, `:mode` (`"build"` | `"plan"`), `:instructions` and
  `:memory` (see `SwarmCode.Domain.Engine.ProjectContext`). `assistant/2` reads three
  more: `:ultra`, `:command` and `:consensus` (spec 37 §4.3 — the map of
  `SwarmCode.Domain.Engine.Consensus.config/1`, which appends the planner block).
  """
  @spec suffix(keyword() | map()) :: String.t()
  def suffix(opts) do
    goal = opts[:goal]
    goals = opts[:goals] || []
    mode = opts[:mode] || "build"

    [
      goal_lines(goals, goal),
      # spec 66 T15: several files can be in there now, root first.
      section(
        "Project instructions (AGENTS.md; deeper files win over shallower ones for files in their directory):",
        opts[:instructions]
      ),
      section(
        "Memory (facts saved earlier — trust them, update them with the remember tool when they change):",
        opts[:memory]
      ),
      if(mode == "plan", do: @plan_mode)
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> ""
      lines -> "\n" <> Enum.join(lines, "\n") <> "\n"
    end
  end

  # One goal reads as a sentence; several are listed (spec 10 §19).
  defp goal_lines([_, _ | _] = goals, _goal) do
    listed =
      goals
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {text, i} -> "#{i}. #{String.trim(text)}" end)

    "Active goals (keep them in mind for every answer; this run pursues one of them):\n" <> listed
  end

  defp goal_lines([single], nil), do: goal_lines([], single)

  defp goal_lines(_goals, goal) do
    if is_binary(goal) and String.trim(goal) != "" do
      "Conversation goal (keep it in mind for every answer): " <> String.trim(goal)
    end
  end

  defp section(_header, nil), do: nil

  defp section(header, text) when is_binary(text) do
    if String.trim(text) == "", do: nil, else: header <> "\n" <> String.trim(text)
  end

  defp section(_header, _text), do: nil

  @ultra """
  ULTRA MODE: for any substantive task (multi-file change, audit, research, review, migration) do not do the work inline. For tasks that fan out (review/audit/research/migrate many files, implement a multi-part spec) author and launch a workflow instead of doing it inline. Call workflow_list first and reuse a saved workflow whose when_to_use matches; otherwise author one for exactly this request following the WORKFLOW AUTHORING MODE procedure below — smoke-check it, save it into the project and launch it with workflow_run straight away. Never ask "shall I launch it?". Say in two sentences what it will do, name the run, and continue when its result arrives. Prefer adversarial verification panels. Trivial questions and one-line edits stay inline.
  """

  # Spec 12 §5: `/create-workflow` is enforced, not suggested — the turn has no
  # `start_swarm` tool at all, and the prompt says so.
  @create_workflow_command """
  The user invoked /create-workflow: you MUST author and launch a workflow. Never start a swarm or do the work yourself in this turn, even if the text says "agents" or "subagents".
  """

  def assistant(%Project{} = project, opts \\ []) do
    # Ultra authors a workflow for every substantive request (spec 11 §10.1),
    # so it needs the authoring procedure just as much as /create-workflow does.
    create_workflow? = opts[:command] == :create_workflow
    authoring? = opts[:authoring] || opts[:ultra] || create_workflow?

    # Spec 37 §4.3: consensus mode — the planner's contract with the judge.
    # Spec 54 §5: `:tools` is the turn's own tool set (`Tools.for_agent/5`), or
    # nil for a caller that does not know it — then the prompt names none.
    base(project, opts[:tools]) <>
      suffix(opts) <>
      if(opts[:ultra], do: "\n" <> @ultra <> "\n", else: "") <>
      if(create_workflow?, do: "\n" <> @create_workflow_command, else: "") <>
      if(authoring?,
        do: "\n" <> SwarmCode.Domain.Engine.WorkflowPrompts.create_workflow() <> "\n",
        else: ""
      ) <>
      if(is_map(opts[:consensus]),
        do: "\n" <> SwarmCode.Domain.Engine.Consensus.planner_block(opts[:consensus]) <> "\n",
        else: ""
      )
  end

  @doc "The `/create-workflow` enforcement line (spec 12 §5)."
  def create_workflow_command, do: @create_workflow_command

  # Spec 50 §1.3: the compaction instruction. The headings are fixed so a later
  # turn (and the reader) always finds the same five things in the same order.
  @compact """
  Compact this conversation so it can continue in a much smaller context.

  Write ONE Markdown summary using exactly these headings, in this order:

  ## Goal
  ## Decisions
  ## Files touched
  ## Open threads
  ## The user's last request

  Rules:
  - Be specific and literal: name files with paths, functions with names, commands with the exact text that was run, errors with their message.
  - Keep everything a later turn would need: what was tried, what failed and why, what is still unverified, what the user rejected.
  - Drop greetings, tool output, and anything a later decision has already superseded.
  - Do not do any new work, do not answer the last request, do not use tools, do not ask questions.
  - Under 800 words.
  """

  @doc """
  The compaction instruction (spec 50 §1.3), with the optional `/compact <focus>`
  steer and, when the window did not reach the start of the conversation, the
  count of messages it could not read (spec 51 §6.6).
  """
  @spec compact(String.t(), keyword()) :: String.t()
  def compact(focus \\ "", opts \\ []) do
    steer =
      if is_binary(focus) and String.trim(focus) != "",
        do: "\nPay particular attention to: " <> String.trim(focus) <> "\n",
        else: ""

    @compact <> steer <> omitted_line(opts[:omitted])
  end

  defp omitted_line(count) when is_integer(count) and count > 0 do
    "\nThe #{count} oldest messages of this conversation were not part of this window.\n"
  end

  defp omitted_line(_count), do: ""

  # spec 73 T53: `ultra/0` and `workflow_reference/0` had no callers; `@ultra`
  # itself is interpolated by `assistant/2` above.
  @doc "The `/create-workflow` authoring instruction (spec 09 §5.8)."
  defdelegate create_workflow(), to: SwarmCode.Domain.Engine.WorkflowPrompts

  @doc """
  The bare project preamble, with no goal, memory, mode or tool talk
  (spec 50 §1.4) — what the compactor gets instead of `assistant/2`.
  """
  @spec base_only(Project.t()) :: String.t()
  def base_only(%Project{} = project), do: base(project)

  # spec 73 T54: the four system-prompt builders below read the memoised
  # `<environment>` block (`environment_cached/1`, 2 s TTL, keyed on id, root
  # and mode) — `environment/1` costs up to two git subprocesses, and these
  # ran inside the RunServer's start_agent call, once per spawn, twice with
  # isolation. The text is identical.
  defp base(%Project{} = project, tools \\ nil) do
    """
    You are SwarmCode, an expert coding assistant working inside the project "#{project.name}" at #{project.root_path}.
    #{environment_cached(project)}#{tool_line(tools)}Rules:
    - Paths are relative to the project root unless absolute and inside it.
    - Inspect before you change: read the relevant files first, then keep the edit as small as the change needs.
    - Run commands (tests, compilers, formatters) to verify your changes when the task involves code changes.
    - If a tool returns "Error: ...", adapt instead of repeating the same call.
    - A durable fact about this project or the user's preferences is worth saving to memory — project scope for repository facts, global for the user's own preferences. Never save secrets or transient details.
    - When a decision is the user's to make (an ambiguous request, several valid approaches, a destructive choice), put it to them as 1-4 multiple-choice questions rather than asking in prose, then continue with the answers.
    - A workflow is the user's call, not yours: author or launch one only when the user used /create-workflow or /workflow, or turned Ultra mode on.
    - A swarm is the user's call too — and the user asking in prose for sub-agents, parallel agents or "N agents" is that call.
    - Deliver what the user asked for, at the scope they intended: make routine judgment calls yourself, and where you think the ask is mistaken say so in a sentence and carry on with it. Keep the reply to the length the question needs, and close by saying what you did, which files changed, and how you verified it.
    - The <environment> block above is the truth about this machine; do not guess the date, the branch or the shell.
    """
  end

  # spec 67 T26 (G29): `environment/1` is now built once per think step, not
  # once per run, and `branch/1` is two `stat`s and up to two `git` subprocesses.
  # The block is memoised per project row, root and approval mode, so a mode
  # switch is seen at once (a different key) and a branch switch within this
  # window. Filed under the `:project` tag, so `Projects.broadcast/0` drops it
  # too; `DataCase` clears the whole table around every test.
  @env_ttl_ms 2_000

  @doc "`environment/1`, memoised for #{@env_ttl_ms} ms (spec 67 T26)."
  @spec environment_cached(Project.t()) :: String.t()
  def environment_cached(%Project{} = project) do
    key = {:project, {:env, project.id, project.root_path, project.approval_mode}}
    now = System.monotonic_time(:millisecond)

    case SwarmCode.Domain.Cache.get(key) do
      {block, at} when is_binary(block) and now - at < @env_ttl_ms ->
        block

      _stale ->
        block = environment(project)
        SwarmCode.Domain.Cache.put(key, {block, now})
        block
    end
  end

  @doc """
  What the model can otherwise only guess: the date, the OS, the shell, the
  branch, the approval mode and what it may write (spec 66 T16).

  Built from values the caller already has — no run state is threaded through
  for it. The OS string is resolved once per VM; the branch costs one
  `git rev-parse` per agent and is left out entirely outside a repository.
  """
  @spec environment(Project.t()) :: String.t()
  def environment(%Project{} = project) do
    elements =
      [
        {"cwd", project.root_path},
        {"os", os_name()},
        {"shell", shell_name()},
        {"current_date", Date.to_iso8601(Date.utc_today())},
        {"git_branch", branch(project.root_path)},
        {"approval_mode", project.approval_mode},
        # T8 (the OS sandbox) was dropped by the owner: commands are not
        # confined, so the honest answer is that nothing is.
        {"writable", "unsandboxed"}
      ]
      |> Enum.reject(fn {_name, value} -> value in [nil, ""] end)
      |> Enum.map_join("\n", fn {name, value} -> "  <#{name}>#{value}</#{name}>" end)

    "<environment>\n" <> elements <> "\n</environment>\n"
  end

  # `branch --show-current` first: `rev-parse --abbrev-ref HEAD` exits 128 in a
  # repository with no commit yet, which is exactly the state a project the user
  # just created is in. `rev-parse` is the fallback for a detached HEAD, where
  # `--show-current` is empty.
  #
  # Both are skipped entirely unless a `.git` is actually there: a prompt is
  # built per agent, and two failing subprocess spawns per agent is a cost a
  # project that is not a repository should not pay at all.
  defp branch(root) do
    if repo?(root) do
      case first_line(SwarmCode.Domain.Git.run(root, ["branch", "--show-current"])) do
        nil -> first_line(SwarmCode.Domain.Git.run(root, ["rev-parse", "--abbrev-ref", "HEAD"]))
        name -> name
      end
    end
  end

  # `.git` is a directory in a checkout and a file in a worktree; both exist.
  # Six levels of ancestors so a project rooted at a package inside a repository
  # still reports the branch, at six `stat` calls and no process.
  defp repo?(root) when is_binary(root) and root != "" do
    root = Elixir.Path.expand(root)

    1..6
    |> Enum.reduce_while({root, false}, fn _level, {dir, _found} ->
      cond do
        File.exists?(Elixir.Path.join(dir, ".git")) -> {:halt, {dir, true}}
        Elixir.Path.dirname(dir) == dir -> {:halt, {dir, false}}
        true -> {:cont, {Elixir.Path.dirname(dir), false}}
      end
    end)
    |> elem(1)
  end

  defp repo?(_root), do: false

  defp first_line({:ok, out}) do
    case out |> String.split("\n", parts: 2) |> List.first() |> String.trim() do
      "" -> nil
      name -> name
    end
  end

  defp first_line({:error, _reason}), do: nil

  defp shell_name do
    case System.get_env("SHELL") do
      path when is_binary(path) and path != "" -> Elixir.Path.basename(path)
      _none -> "sh"
    end
  end

  # One `sw_vers` per VM, not per run.
  defp os_name do
    case :persistent_term.get({__MODULE__, :os_name}, nil) do
      nil ->
        name = detect_os()
        :persistent_term.put({__MODULE__, :os_name}, name)
        name

      name ->
        name
    end
  end

  defp detect_os do
    case :os.type() do
      {:unix, :darwin} -> "macOS " <> product_version()
      {:unix, name} -> to_string(name) <> " " <> kernel_version()
      {:win32, _name} -> "Windows " <> kernel_version()
      other -> inspect(other)
    end
  end

  defp product_version do
    case System.cmd("sw_vers", ["-productVersion"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _error -> kernel_version()
    end
  rescue
    _error -> kernel_version()
  end

  defp kernel_version, do: :os.version() |> Tuple.to_list() |> Enum.join(".")

  # Spec 54 §5 (54c H7): the prompt used to name eight tools by hand, and
  # `Tools.for_agent/5` takes five of them away in plan mode, `start_swarm` on a
  # `/swarm` turn and the swarm modules on `/create-workflow` — so it advertised
  # calls the turn could not make, and then `@plan_mode` had to negate the same
  # list a second time. The names come from the request's own tool set now, and
  # each rule states the behaviour instead of naming the tool that does it.
  defp tool_line(names) when is_list(names) and names != [],
    do: "The tools this turn has: " <> Enum.join(names, ", ") <> ".\n"

  defp tool_line(_names), do: ""

  @worktrees """
  Isolation: each sub-agent runs in its own git worktree on its own branch, so their edits are invisible to you and to each other until you merge them. When a sub-agent finishes it reports its branch and diff stat. Review the work (read_file inside the branch's worktree, or git_diff), then call integrate_agent with that branch name to merge it into the project. Merge every branch you want to keep before your final report; conflicts are reported back to you to resolve.
  """

  def lead(%Project{} = project, max_concurrent, opts \\ []) do
    worktrees = if opts[:worktrees], do: "\n" <> @worktrees, else: ""
    lead_base(project, max_concurrent) <> worktrees <> suffix(opts)
  end

  defp lead_base(%Project{} = project, max_concurrent) do
    """
    You are the Lead of a coding swarm working inside the project "#{project.name}" at #{project.root_path}.
    #{environment_cached(project)}Your job: decompose the user's task into independent sub-tasks, delegate them with the spawn_agent tool, then integrate and verify.
    Rules:
    - First inspect briefly (list_dir, grep, read_file) to understand the layout. Do not do the whole job yourself.
    - Call spawn_agent once per sub-task. Give each sub-agent a short name (max 24 chars), a precise task, the exact files it owns, and the expected output. Call several spawn_agent in the same response when sub-tasks are independent; at most #{max_concurrent} run at once, the rest queue automatically.
    - Never give two sub-agents the same file to edit.
    - When sub-agents report back, verify their work (run_command for tests or compile), fix small issues yourself or delegate follow-ups.
    - When you learn a durable fact about this project or the user's preferences, save it with the remember tool (project scope for repo facts, global for user preferences). Never save secrets or transient details.
    - When a decision is the user's to make (ambiguous task, several valid approaches, destructive choice) call ask_user with 1-4 multiple-choice questions instead of guessing; continue with the answers.
    - You never edit files yourself — you have no edit tools. Decompose the task (a goal is a task) into 2–N independent parts, spawn one sub-agent per part (up to #{max_concurrent} at once), integrate, verify with run_command, report. For a goal: keep spawning follow-up sub-agents until the goal is met.
    - Finish with a final report in Markdown with the sections "## Result", "## Files changed", "## Verification", "## Open issues". Do not call tools in your final message.
    """
  end

  def sub_agent(%Project{} = project, name, opts \\ []) do
    sub_agent_base(project, name) <> suffix(opts)
  end

  defp sub_agent_base(%Project{} = project, name) do
    """
    You are sub-agent "#{name}" in a coding swarm working inside the project "#{project.name}" at #{project.root_path}.
    #{environment_cached(project)}Do exactly the task you are given and nothing else.
    Rules:
    - Inspect before you change; keep edits minimal and correct; verify with run_command when relevant.
    - Only touch the files your task gives you.
    - Do not ask questions; make reasonable assumptions and state them.
    - Finish with a concise report: what you did, files changed, findings, and anything the lead must know. Do not call tools in your final message.
    """
  end

  @capability_notes %{
    read_only:
      "You are read-only: you may read, search and fetch, but you must not change anything.",
    read_write: "You may read and write files in the project, but you cannot run commands.",
    execute: "You may read, write and run commands in the project.",
    all: "You have the full tool set of the project.",
    # Spec 37 §3.1: the judge that must not read the repo.
    none: "You have no tools besides structured_output: judge from the text you were given."
  }

  @doc """
  The system prompt of a workflow worker (spec 09 §4.2): one self-contained
  task, no conversation memory, one final answer.
  """
  def worker(%Project{} = project, name, opts \\ []) do
    capability = opts[:capability] || :read_only

    """
    You are a worker agent named "#{name}" in a host-run workflow of SwarmCode, working inside the project "#{project.name}" at #{project.root_path}.
    #{environment_cached(project)}You get one self-contained task below and no memory of any conversation. Do the task with your tools, then answer with the final result only. Do not ask questions; if something is impossible say so clearly.
    #{Map.get(@capability_notes, capability, @capability_notes.read_only)}
    """ <> suffix(opts)
  end

  @doc "The user message a worker gets: the task, plus optional context."
  def worker_user(task, context) do
    base = "TASK:\n" <> to_string(task)

    if is_binary(context) and String.trim(context) != "",
      do: base <> "\n\nCONTEXT:\n" <> String.trim(context),
      else: base
  end

  @doc "Appended to a worker system prompt when the workflow demands structured output."
  def structured_output_note,
    do:
      "\nFinish by calling structured_output exactly once with your final answer. " <>
        "Do not answer in text.\n"

  def sub_agent_user(task, context) do
    if is_binary(context) and String.trim(context) != "" do
      task <> "\n\nContext from the lead:\n" <> context
    else
      task
    end
  end

  # Only the most recent user messages carry their images; older ones would blow
  # the context window up for no benefit.
  @image_window 6
  # Spec 51 §6.5: and a count alone is not a bound — four 5 MB screenshots in
  # one message are 32 MB of base64, and six such messages 400/413 on every turn
  # for ever. 12 MB raw is 16 MB base64, half the provider's request limit.
  @image_window_bytes 12_000_000

  # spec 66 T17: the summary may be lossy; the user's requests may not. The
  # constant is Codex's `COMPACT_USER_MESSAGE_MAX_TOKENS`.
  @verbatim_user_tokens 20_000
  @verbatim_marker "[Your earlier requests, verbatim — the summary below may have dropped detail from them]"

  def history_to_messages(messages) do
    verbatim_user_messages(messages) ++ do_history_to_messages(messages)
  end

  @doc "The marker above the verbatim block a compaction keeps (spec 66 T17)."
  def verbatim_marker, do: @verbatim_marker

  # Only when the window *starts* at a compaction summary: everything the user
  # asked for before it is behind `compact_floor/1` and would never be sent
  # again. Newest first until the cap, then back into their original order, then
  # the summary itself (which the caller's own list already carries).
  defp verbatim_user_messages([%Message{role: "compact", content: content} = first | _rest])
       when content != "" do
    with id when is_binary(id) <- first.conversation_id,
         position when is_integer(position) <- first.position,
         [_ | _] = rows <-
           SwarmCode.Domain.Conversations.list_user_messages_before(
             id,
             position,
             4 * @verbatim_user_tokens
           ) do
      rows
      |> Enum.reduce_while([], fn m, kept ->
        candidate = [%{role: "user", content: String.trim(m.content)} | kept]

        if SwarmCode.Domain.Engine.Context.estimate_tokens(candidate) > @verbatim_user_tokens,
          do: {:halt, kept},
          else: {:cont, candidate}
      end)
      |> case do
        [] ->
          []

        kept ->
          # `rows` is newest first, so `kept` is already back in transcript order.
          [
            %{
              role: "user",
              content:
                @verbatim_marker <>
                  "\n\n" <> Enum.map_join(kept, "\n\n---\n\n", & &1.content)
            }
          ]
      end
    else
      _none -> []
    end
  end

  defp verbatim_user_messages(_messages), do: []

  defp do_history_to_messages(messages) do
    recent = recent_image_ids(messages)

    Enum.flat_map(messages, fn
      %Message{role: "user"} = m ->
        user_message(m, MapSet.member?(recent, m.id))

      %Message{role: "assistant", content: content} when content != "" ->
        [%{role: "assistant", content: content}]

      %Message{role: "swarm", content: content} when content != "" ->
        [%{role: "user", content: "[Swarm report]\n" <> content}]

      %Message{role: "workflow", content: content} when content != "" ->
        [%{role: "user", content: "[Workflow report]\n" <> content}]

      # Spec 50 §1.2: a compact message *is* the history before it — it is read
      # as one user turn, and `list_history_window/2` never reaches past it.
      %Message{role: "compact", content: content} when content != "" ->
        [%{role: "user", content: "[Summary of the conversation so far]\n" <> content}]

      _ ->
        []
    end)
  end

  defp recent_image_ids(messages) do
    messages
    |> Enum.filter(&(&1.role == "user" and (&1.attachments || []) != []))
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0, 0}, fn m, {ids, count, bytes} ->
      bytes = bytes + SwarmCode.Domain.Attachments.size(m.attachments)

      if count < @image_window and bytes <= @image_window_bytes do
        {:cont, {[m.id | ids], count + 1, bytes}}
      else
        {:halt, {ids, count, bytes}}
      end
    end)
    |> elem(0)
    |> MapSet.new()
  end

  defp user_message(%Message{attachments: attachments} = m, with_images?)
       when attachments != nil and attachments != [] do
    if with_images? do
      [
        %{
          role: "user",
          content: m.content,
          images: SwarmCode.Domain.Attachments.images(attachments)
        }
      ]
    else
      omitted = Enum.map_join(attachments, "\n", &"[image #{&1["name"]} omitted]")
      [%{role: "user", content: String.trim(m.content <> "\n" <> omitted)}]
    end
  end

  defp user_message(%Message{content: content}, _with_images?) when content != "",
    do: [%{role: "user", content: content}]

  defp user_message(_m, _with_images?), do: []
end
