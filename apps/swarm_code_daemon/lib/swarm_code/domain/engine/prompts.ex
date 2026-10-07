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

  # Spec 75 (pass 71): Ultra is Factory-style missions. The orchestrator answers
  # small requests itself and runs multi-feature work as a mission; it no longer
  # authors workflows (/workflow and /create-workflow still do).
  @ultra """
  ULTRA MODE — MISSIONS: you are the orchestrator. Answer questions, explanations and small changes (one file, one clear fix) yourself, inline. Multi-feature work — several features, a multi-file change, a refactor across modules, anything that needs more than one worker — runs as a mission:
  1. Investigate first: read the code, the tests and the project instructions; learn how the project builds and tests.
  2. Ask what you cannot find out (ask_user, 1-4 multiple-choice questions): scope, behaviour the user cares about, constraints. Skip this when the request is unambiguous.
  3. Write the validation contract BEFORE the features: behavioural assertions with ids VAL-<AREA>-NNN (AREA 2-8 capital letters, NNN three digits), each observable, each with a method (test | command | read) and the evidence a validator must capture. Cover the user's intent, not the implementation.
  4. Split the work into features — each one self-contained for a fresh worker that has never seen this conversation: what to build, which files, which tests to add first, how to run them. Every feature claims the assertions it satisfies; every assertion is claimed; one assertion belongs to one milestone.
  5. Group features into milestones (M1, M2, …, at most 6) in dependency order. Features inside one milestone run in parallel, so they must not edit the same files; put dependent work in a later milestone.
  6. Write the guidelines (conventions, the exact test and build commands, files never to touch) and the knowledge (key files, APIs, gotchas you found).
  7. Call mission_start with all of it. The user approves the plan and picks the worker and validator models in the approval card — do not ask for approval yourself. Say in one or two sentences what the mission will do, then stop.
  8. When the mission reports back, read its summary: tell the user what passed, what failed and why, and what you suggest next. If the user asked to revise the plan, revise it and call mission_start again.
  Never write the features yourself while a mission runs; you may answer the user's questions about it.
  """

  # Spec 12 §5: `/create-workflow` is enforced, not suggested — the turn has no
  # `start_swarm` tool at all, and the prompt says so.
  @create_workflow_command """
  The user invoked /create-workflow: you MUST author and launch a workflow. Never start a swarm or do the work yourself in this turn, even if the text says "agents" or "subagents".
  """

  def assistant(%Project{} = project, opts \\ []) do
    # Spec 75: Ultra plans missions; only /create-workflow (and an explicit
    # `authoring:` caller) get the workflow-authoring procedure.
    create_workflow? = opts[:command] == :create_workflow
    authoring? = opts[:authoring] || create_workflow?

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
    You are ncode, an expert coding assistant working inside the project "#{project.name}" at #{project.root_path}.
    #{environment_cached(project)}#{tool_line(tools)}Rules:
    - Paths are relative to the project root unless absolute and inside it.
    - Inspect before you change: read the relevant files first, then keep the edit as small as the change needs.
    - Run commands (tests, compilers, formatters) to verify your changes when the task involves code changes.
    - If a tool returns "Error: ...", adapt instead of repeating the same call.
    - A durable fact about this project or the user's preferences is worth saving to memory — project scope for repository facts, global for the user's own preferences. Never save secrets or transient details.
    - When a decision is the user's to make (an ambiguous request, several valid approaches, a destructive choice), put it to them as 1-4 multiple-choice questions rather than asking in prose, then continue with the answers.
    - A workflow is the user's call, not yours: author or launch one only when the user used /create-workflow or /workflow. In Ultra mode, multi-feature work is a mission (mission_start), never an ad-hoc workflow.
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

  # spec 74 EFFICIENCY-39: the branch is read from `HEAD` itself — a file read,
  # not a subprocess (35 ms median → well under 1 ms, and this runs on every
  # think step of every agent). `ref: refs/heads/<name>` is exactly what
  # `git branch --show-current` prints, an unborn branch included. Only a HEAD
  # that names no branch (detached) or cannot be read goes to git as before:
  #
  # `branch --show-current` first: `rev-parse --abbrev-ref HEAD` exits 128 in a
  # repository with no commit yet, which is exactly the state a project the user
  # just created is in. `rev-parse` is the fallback for a detached HEAD, where
  # `--show-current` is empty.
  #
  # Nothing runs unless a `.git` is actually there: a prompt is built per
  # agent, and two failing subprocess spawns per agent is a cost a project that
  # is not a repository should not pay at all.
  defp branch(root) do
    case dot_git(root) do
      nil ->
        nil

      dot_git ->
        case head_branch(dot_git) do
          {:ok, name} -> name
          :git -> git_branch(root)
        end
    end
  end

  defp git_branch(root) do
    case first_line(SwarmCode.Domain.Git.run(root, ["branch", "--show-current"])) do
      nil -> first_line(SwarmCode.Domain.Git.run(root, ["rev-parse", "--abbrev-ref", "HEAD"]))
      name -> name
    end
  end

  # `.git` is a directory in a checkout and a file in a worktree or a
  # submodule (`gitdir: <path>`, relative to the file's own directory).
  defp head_branch(dot_git) do
    with {:ok, git_dir} <- git_dir(dot_git),
         {:ok, head} <- File.read(Elixir.Path.join(git_dir, "HEAD")),
         true <- String.valid?(head),
         "ref: refs/heads/" <> name when name != "" <- first_line_of(head) do
      {:ok, name}
    else
      _detached_or_unreadable -> :git
    end
  end

  defp git_dir(dot_git) do
    if File.dir?(dot_git) do
      {:ok, dot_git}
    else
      with {:ok, text} <- File.read(dot_git),
           true <- String.valid?(text),
           "gitdir:" <> path <- first_line_of(text),
           path when path != "" <- String.trim(path) do
        {:ok, Elixir.Path.expand(path, Elixir.Path.dirname(dot_git))}
      else
        _other -> :error
      end
    end
  end

  defp first_line_of(text), do: text |> String.split("\n", parts: 2) |> hd() |> String.trim()

  # The nearest `.git` of the root or one of its ancestors, six levels up, so a
  # project rooted at a package inside a repository still reports the branch,
  # at six `stat` calls and no process.
  defp dot_git(root) when is_binary(root) and root != "" do
    1..6
    |> Enum.reduce_while({Elixir.Path.expand(root), nil}, fn _level, {dir, nil} ->
      dot_git = Elixir.Path.join(dir, ".git")

      cond do
        File.exists?(dot_git) -> {:halt, {dir, dot_git}}
        Elixir.Path.dirname(dir) == dir -> {:halt, {dir, nil}}
        true -> {:cont, {Elixir.Path.dirname(dir), nil}}
      end
    end)
    |> elem(1)
  end

  defp dot_git(_root), do: nil

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
    # Spec 75: the mission's user-testing validator.
    verify:
      "You may read and run commands (tests, scripts, the app) but you must not change files. You report; you never fix.",
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
    You are a worker agent named "#{name}" in a host-run workflow of ncode, working inside the project "#{project.name}" at #{project.root_path}.
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
        m |> user_message(recent) |> mark_research(m.research_ids)

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

  # spec 74 BUGS-31: the byte window is counted per image, not per message.
  # A message whose images together passed 12 MB (three 4.5 MB screenshots)
  # used to lose all of them — on this turn and every later one. Newest message
  # first, its images one at a time in order, then older messages the same way,
  # until the next image would pass the cap; everything older than that is
  # omitted, so the window only ever shrinks from its oldest end. One image
  # always fits (6 MB is under 12 MB). The keys are `{message_id,
  # attachment_id}` pairs.
  defp recent_image_ids(messages) do
    messages
    |> Enum.filter(&(&1.role == "user" and (&1.attachments || []) != []))
    |> Enum.reverse()
    |> Enum.take(@image_window)
    |> Enum.flat_map(fn m -> Enum.map(m.attachments, &{m.id, &1}) end)
    |> Enum.reduce_while({MapSet.new(), 0}, fn {message_id, a}, {ids, bytes} ->
      bytes = bytes + SwarmCode.Domain.Attachments.size([a])

      if bytes <= @image_window_bytes,
        do: {:cont, {MapSet.put(ids, {message_id, a["id"]}), bytes}},
        else: {:halt, {ids, bytes}}
    end)
    |> elem(0)
  end

  defp user_message(%Message{attachments: attachments} = m, recent)
       when attachments != nil and attachments != [] do
    {sent, left_out} = Enum.split_with(attachments, &MapSet.member?(recent, {m.id, &1["id"]}))

    content =
      case left_out do
        [] ->
          m.content

        _some ->
          omitted = Enum.map_join(left_out, "\n", &"[image #{&1["name"]} omitted]")
          String.trim(m.content <> "\n" <> omitted)
      end

    if sent == [],
      do: [%{role: "user", content: content}],
      else: [%{role: "user", content: content, images: SwarmCode.Domain.Attachments.images(sent)}]
  end

  defp user_message(%Message{content: content}, _recent) when content != "",
    do: [%{role: "user", content: content}]

  defp user_message(_m, _recent), do: []

  # spec 74 BUGS-76: the reports a message attached stay in every later
  # turn's context. The mark is expanded by the agent that receives the
  # history (`Engine.ResearchContext.expand/1`), off the caller's process.
  defp mark_research([message], [_ | _] = ids), do: [Map.put(message, :research_ids, ids)]
  defp mark_research(converted, _ids), do: converted

  @omitted_line ~r/\A\[image .* omitted\]\z/

  @doc """
  spec 74 BUGS-31: `text` followed by the `[image … omitted]` lines
  `history_to_messages/1` appended to `converted` — the Engine replaces the
  newest user message's content with the turn's prompt, and the model must
  still be told which of its images were left out.
  """
  @spec keep_omitted(String.t(), String.t()) :: String.t()
  def keep_omitted(text, converted) when is_binary(converted) do
    converted
    |> String.split("\n")
    |> Enum.reverse()
    |> Enum.take_while(&Regex.match?(@omitted_line, &1))
    |> case do
      [] -> text
      lines -> text <> "\n" <> (lines |> Enum.reverse() |> Enum.join("\n"))
    end
  end

  def keep_omitted(text, _converted), do: text
end
