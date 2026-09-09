defmodule SwarmCode.Domain.Tools do
  @moduledoc """
  Tool registry, argument validation and dispatch.

  A tool is a `SwarmCode.Domain.Tools.Ref`: either a builtin module or an MCP tool. The
  builtin list is static; MCP tools come from `SwarmCode.Domain.MCP` and depend on the
  project the agent runs in.
  """

  alias SwarmCode.Domain.Tools.Ref

  @modules [
    SwarmCode.Domain.Tools.ReadFile,
    SwarmCode.Domain.Tools.ListDir,
    SwarmCode.Domain.Tools.WriteFile,
    SwarmCode.Domain.Tools.EditFile,
    SwarmCode.Domain.Tools.Grep,
    SwarmCode.Domain.Tools.RunCommand,
    SwarmCode.Domain.Tools.WebSearch,
    SwarmCode.Domain.Tools.WebFetch,
    SwarmCode.Domain.Tools.GitStatus,
    SwarmCode.Domain.Tools.GitDiff,
    SwarmCode.Domain.Tools.GitLog,
    SwarmCode.Domain.Tools.GitCommit,
    SwarmCode.Domain.Tools.Remember,
    SwarmCode.Domain.Tools.IntegrateAgent,
    SwarmCode.Domain.Tools.SpawnAgent
  ]

  # Interview mode: the assistant and the lead may ask, sub-agents and workers
  # may not (spec 10 §1).
  @ask_modules [SwarmCode.Domain.Tools.AskUser]

  # Spec 37: only a consensus-mode assistant gets this. Spec 45 §6.2:
  # `write_spec` only when the run has an implementer.
  @consensus_modules [SwarmCode.Domain.Tools.SubmitPlan, SwarmCode.Domain.Tools.WriteSpec]

  # The assistant's own fan-out: a swarm, never a workflow (spec 12 §1).
  @swarm_modules [SwarmCode.Domain.Tools.StartSwarm]

  # Only the root assistant gets these (spec 09 §5.7).
  @workflow_modules [
    SwarmCode.Domain.Tools.WorkflowList,
    SwarmCode.Domain.Tools.WorkflowSmokeCheck,
    SwarmCode.Domain.Tools.WorkflowSave,
    SwarmCode.Domain.Tools.WorkflowRun,
    SwarmCode.Domain.Tools.WorkflowControl
  ]

  @max_output 100_000

  @read_only ~w(read_file list_dir grep web_search web_fetch git_status git_diff git_log ask_user
                submit_plan)
  # Sakana task 19: `workflow_control` left this list — it mutates live runs, so
  # a plan-mode assistant must not be offered it. Spec 50 §6.3:
  # `workflow_smoke_check` leaves it too. It is read-only, but the only reason a
  # plan-mode agent reaches for it is that something told it to author a
  # workflow — and half a workflow toolkit is exactly what produced note 6
  # ("workflow_smoke_check" ran, then "unknown tool workflow_save"). Plan mode
  # plans; `workflow_list` stays, because "which workflows exist" is a fact a
  # plan may legitimately want to state.
  @workflow_read_only ~w(workflow_list)

  def max_output, do: @max_output

  @doc "Every builtin tool as a `Ref`."
  @spec builtins() :: [Ref.t()]
  def builtins do
    Enum.map(@modules, &builtin_ref/1)
  end

  @doc false
  def builtin_ref(mod) do
    %Ref{
      name: mod.name(),
      description: mod.description(),
      parameters: mod.parameters(),
      kind: :builtin,
      module: mod,
      read_only?: mod.name() in @read_only,
      permission: mod.permission(%{})
    }
  end

  @spec get(String.t()) :: {:ok, Ref.t()} | :error
  def get(name) do
    case Enum.find(
           @modules ++ @workflow_modules ++ @swarm_modules ++ @ask_modules ++ @consensus_modules,
           &(&1.name() == name)
         ) do
      nil -> mcp_lookup(name)
      mod -> {:ok, builtin_ref(mod)}
    end
  end

  # Spec 43 §1.7: `SwarmCode.Domain.MCP` is a fixed child of the application — no
  # runtime lookup, no `apply/3`.
  defp mcp_lookup(name), do: SwarmCode.Domain.MCP.lookup(name)

  @spec specs([Ref.t()]) :: [map()]
  def specs(refs) do
    Enum.map(refs, &%{name: &1.name, description: &1.description, parameters: &1.parameters})
  end

  @doc """
  The tools this agent may call. In plan mode only read-only tools are offered.

  `opts` accepts `:project_id`, used to pick up the MCP tools of that project
  (plus the global ones), and `:command` (`:create_workflow | :swarm | nil`,
  spec 12 §5): the command the user invoked is *enforced*, not suggested — a
  `/create-workflow` turn cannot start a swarm, and a `/swarm` turn (which is
  already a swarm) gets neither `start_swarm` nor the workflow tools.
  """
  @spec for_agent(String.t(), non_neg_integer(), non_neg_integer(), String.t(), keyword()) ::
          [Ref.t()]
  def for_agent(role, depth, max_depth, mode \\ "build", opts \\ []) do
    command = opts[:command]

    root_extra =
      cond do
        role != "assistant" or depth != 0 -> []
        command == :create_workflow -> @workflow_modules
        command == :swarm -> []
        true -> @workflow_modules ++ @swarm_modules
      end

    workflow_refs = Enum.map(root_extra, &builtin_ref/1)

    ask_refs =
      if role in ["assistant", "lead"], do: Enum.map(@ask_modules, &builtin_ref/1), else: []

    refs = builtins() ++ workflow_refs ++ ask_refs ++ mcp_tools(opts[:project_id])

    refs =
      if mode == "plan" do
        # Plan mode never writes. The lead keeps spawn_agent so it can still fan
        # exploration out to sub-agents (which are read-only themselves).
        read_only = Enum.filter(refs, &(&1.read_only? or &1.name in @workflow_read_only))
        if role == "lead", do: read_only ++ [named(refs, "spawn_agent")], else: read_only
      else
        refs
      end

    refs
    |> Enum.reject(&is_nil/1)
    |> reject_when(role == "assistant" or depth >= max_depth, "spawn_agent")
    |> reject_when(role == "assistant", "integrate_agent")
    # The Lead delegates: it has no edit tools at all, so it cannot quietly do
    # the whole job itself (spec 10 §7.4).
    |> reject_when(role == "lead", "write_file")
    |> reject_when(role == "lead", "edit_file")
  end

  defp named(refs, name), do: Enum.find(refs, &(&1.name == name))

  defp reject_when(refs, true, name), do: Enum.reject(refs, &(&1.name == name))
  defp reject_when(refs, false, _name), do: refs

  defp mcp_tools(project_id), do: SwarmCode.Domain.MCP.tools_for(project_id)

  @doc """
  The tools a workflow worker gets for its capability (spec 09 §3.3). It never
  gets `spawn_agent`, `integrate_agent`, `remember` or the workflow tools.
  """
  @spec for_worker(atom(), String.t() | nil) :: [Ref.t()]
  def for_worker(capability \\ :read_only, project_id \\ nil)

  # Spec 37 §3: a judge that must not read the repo gets nothing but its verdict tool.
  def for_worker(:none, _project_id), do: []

  def for_worker(capability, project_id) do
    mcp = mcp_tools(project_id)

    extra =
      case capability do
        :read_only -> []
        :read_write -> ~w(write_file edit_file)
        :execute -> ~w(write_file edit_file run_command)
        :all -> ~w(write_file edit_file run_command)
        _ -> []
      end

    allowed = @read_only ++ extra

    builtins =
      builtins()
      |> Enum.reject(&(&1.name in ~w(spawn_agent integrate_agent remember)))
      |> Enum.filter(&(capability == :all or &1.name in allowed))

    mcp = if capability in [:all, :execute], do: mcp, else: Enum.filter(mcp, & &1.read_only?)

    builtins ++ mcp
  end

  @doc "The `structured_output` tool that ends an agent with a validated object."
  @spec structured_output_ref(map()) :: Ref.t()
  def structured_output_ref(schema) do
    %Ref{
      name: "structured_output",
      description:
        "Return your final answer as a structured object. Call this exactly once, with your " <>
          "complete final answer; do not answer in text.",
      parameters: SwarmCode.Domain.Workflows.Schema.to_json_schema(schema),
      kind: :structured,
      read_only?: true,
      permission: :read,
      schema: schema
    }
  end

  @doc "The read-only builtin tool names offered in plan mode."
  def read_only, do: @read_only

  def determinate?("mcp"), do: false

  def determinate?(op_type),
    do: op_type in ~w(read_file list_dir grep write_file edit_file web_fetch)

  @doc """
  The timeout non-shell tools use, in milliseconds (spec 07 §10).

  `settings.tool_timeout_ms` (Settings → Limits → Tool timeout) covers web
  fetch, web search and MCP calls; shell commands have their own
  `command_timeout_ms`.
  """
  @spec timeout(map()) :: pos_integer()
  def timeout(ctx) do
    ((is_map(ctx) and Map.get(ctx, :settings)) && Map.get(ctx.settings, :tool_timeout_ms)) ||
      120_000
  end

  @doc "Runs a tool by name (looks the ref up first)."
  def run(name, args, ctx, progress) when is_binary(name) do
    case get(name) do
      :error -> {:error, "unknown tool " <> name}
      {:ok, ref} -> run(ref, args, ctx, progress)
    end
  end

  def run(%Ref{} = ref, args, ctx, progress) do
    args = alias_args(ref, args)
    required = (ref.parameters || %{})["required"] || []

    case Enum.find(required, fn k -> is_nil(args[k]) end) do
      nil ->
        result =
          try do
            do_run(ref, args, ctx, progress)
          rescue
            e -> {:error, "crashed: " <> Exception.message(e)}
          catch
            # spec 36 §A4: a shutdown is not a tool failure. `run_command` traps
            # its supervisor's exit, kills the port and re-raises with
            # `exit(reason)`; turning that into `{:error, "crashed: …"}` is what
            # rewrote a stopped operation as `failed · crashed: {:exit,
            # :shutdown}`. Spec 51 §7.6 (R19) added the matching clause to
            # `Engine.Operation.run/5`, which used to catch this exit again one
            # frame up; the pair of them is what makes a stopped op stay
            # stopped (§A4 blocker in `.specs/36_bug_sweep_spec.md`, closed).
            :exit, reason -> exit(reason)
            kind, v -> {:error, "crashed: #{inspect({kind, v})}"}
          end

        truncate(result)

      key ->
        {:error, "missing required argument \"#{key}\" for #{ref.name}#{received(args)}"}
    end
  end

  # A model that calls `write_file` with `file_path` instead of `path` gets
  # "missing required argument" and no way to tell which name was wrong, so it
  # resends the same call (spec 20 review, 2026-08-23). Naming the keys it did
  # send makes the next call correct.
  defp received(args) when is_map(args) and map_size(args) > 0,
    do:
      " (received: " <>
        (args |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort() |> Enum.join(", ")) <> ")"

  defp received(_args), do: " (received no arguments)"

  # The synonyms models reach for most often. A synonym is only moved onto a
  # declared property that is *missing*, and only when the synonym is not itself
  # declared by the tool — so a schema that means both keys is never rewritten.
  @arg_aliases %{
    "path" => ~w(file_path filepath filename file_name file target_file),
    "content" => ~w(contents text body file_text new_content),
    "old_string" => ~w(old_str old_text old),
    "new_string" => ~w(new_str new_text new),
    "command" => ~w(cmd shell_command shell),
    "pattern" => ~w(regex regexp search_pattern),
    "query" => ~w(q search_query)
  }

  @doc false
  def alias_args(%Ref{} = ref, args) when is_map(args) do
    properties = (ref.parameters || %{})["properties"] || %{}
    declared = properties |> Map.keys() |> Enum.map(&to_string/1)

    Enum.reduce(declared, args, fn key, acc ->
      with true <- is_nil(acc[key]),
           candidates = Map.get(@arg_aliases, key, []),
           found when is_binary(found) <-
             Enum.find(candidates, fn c -> not is_nil(acc[c]) and c not in declared end) do
        acc |> Map.put(key, acc[found]) |> Map.delete(found)
      else
        _other -> acc
      end
    end)
  end

  def alias_args(_ref, args), do: args

  defp do_run(%Ref{kind: :builtin, module: mod}, args, ctx, progress),
    do: mod.run(args, ctx, progress)

  # Schema-correction retries are free: an invalid object comes back to the model
  # as a tool error, a valid one becomes the agent's result (spec 09 §3.2).
  defp do_run(%Ref{kind: :structured, schema: schema}, args, _ctx, _progress) do
    case SwarmCode.Domain.Workflows.Schema.validate(schema, args) do
      :ok -> {:ok, Jason.encode!(args)}
      {:error, messages} -> {:error, Enum.join(messages, "; ")}
    end
  end

  defp do_run(%Ref{kind: :mcp} = ref, args, ctx, progress) do
    progress.(nil, "calling " <> ref.tool_name)

    case SwarmCode.Domain.MCP.call(ref.server_id, ref.tool_name, args, timeout: timeout(ctx)) do
      {:ok, text} ->
        progress.(100, "done")
        {:ok, text}

      {:error, reason} ->
        {:error, with_limit_hint(to_string(reason), timeout(ctx))}
    end
  end

  # A timeout has to say which limit stopped it and where to change it (§10).
  defp with_limit_hint(reason, timeout) do
    if String.contains?(reason, "timed out") do
      reason <> " — raise Settings → Limits → Tool timeout (now #{timeout} ms)"
    else
      reason
    end
  end

  @doc false
  def truncate({:ok, s}) when is_binary(s) do
    if String.length(s) > max_output() do
      {:ok, String.slice(s, 0, max_output()) <> "\n…[truncated]"}
    else
      {:ok, s}
    end
  end

  # spec 60 T6: an MCP `isError` body or a crash message is capped like a result.
  def truncate({:error, s}) when is_binary(s) do
    if String.length(s) > max_output(),
      do: {:error, String.slice(s, 0, max_output()) <> "\n…[truncated]"},
      else: {:error, s}
  end

  def truncate(other), do: other
end
