defmodule SwarmCode.Commands do
  @moduledoc "Pure slash-command registry and parser for the CLI. Parsing never executes a command."

  @modes [
    {"build", "Build", "🛠", "the assistant reads, writes and runs", "hero-wrench-screwdriver"},
    {"plan", "Plan", "▤", "read-only tools, a step-by-step plan", "hero-clipboard-document-list"},
    {"goal", "Goal", "◎", "the next message sets a goal to pursue", nil},
    {"ultra", "Ultra", "⧉", "big tasks become workflows", nil},
    {"workflow", "Workflow", "⧉", "the next message authors and launches a workflow", nil},
    {"consensus", "Consensus", "⚖", "a second model judges the plan first", nil}
  ]

  @builtins [
    {"swarm", "<task>", "Start a swarm of agents on a task"},
    {"goal", "<text>", "Set the conversation goal every agent keeps in mind"},
    {"plan", "", "Toggle plan mode — read-only, produces a step-by-step plan"},
    {"review", "", "Review the uncommitted changes and report problems"},
    {"effort", "<low|medium|high|max>", "Reasoning effort of this conversation's chat model"},
    {"swarm_effort", "<low|medium|high|max>",
     "Reasoning effort of this conversation's sub agent model"},
    {"rewind", "", "Restore files to how they were before an earlier turn"},
    {"stop", "", "Stop everything running in this conversation"},
    {"resume", "", "Resume the last stopped run of this conversation"},
    {"workflow", "<name> [key=value…] | pause|resume|stop|save <run>",
     "Launch or control a workflow run"},
    {"workflows", "", "Open the workflow dashboard"},
    {"create-workflow", "[what it should do]", "Author a new workflow with the assistant"},
    {"ultra", "", "Toggle Ultra — the assistant orchestrates big tasks through workflows"},
    {"consensus", "[task]", "Run this turn as a judged plan"},
    {"deep_research", "[id]", "Attach a finished deep research to this message"},
    {"attach", "<image-path>", "Stage an image file for the next message"},
    {"compact", "[focus]", "Summarise the conversation so far and continue from the summary"}
  ]

  @max_text 262_144
  @max_label 256
  @max_entries 1_024
  @efforts %{
    "none" => :none,
    "minimal" => :minimal,
    "low" => :low,
    "medium" => :medium,
    "high" => :high,
    "xhigh" => :xhigh,
    "max" => :max
  }
  @mode_atoms %{
    "build" => :build,
    "plan" => :plan,
    "goal" => :goal,
    "ultra" => :ultra,
    "workflow" => :workflow,
    "consensus" => :consensus
  }
  @controls %{"pause" => :pause, "resume" => :resume, "stop" => :stop}
  @no_args %{
    "review" => :review_changes,
    "rewind" => :select_rewind,
    "stop" => :stop_all,
    "resume" => :resume_last,
    "workflows" => :open_workflows
  }

  @type error :: %{required(:type) => atom()}
  @type command :: %{
          required(:name) => String.t(),
          required(:kind) => atom(),
          required(:action) => atom()
        }

  @doc "The six composer modes in web menu order, with label, glyph, hint and icon."
  def modes, do: @modes
  def mode_values, do: Enum.map(@modes, &elem(&1, 0))

  @doc """
  Ranked command metadata. Options are `:workflows` and `:custom` lists of maps
  (atom or string keys). Invalid entries are omitted. Project definitions beat
  global/user duplicates. Builtins beat workflows, which beat custom commands.
  Names match by prefix, then at a hyphen, underscore or dot boundary.
  """
  def catalogue(query \\ "/", opts \\ []) do
    with true <- valid_text?(query, @max_label + 1),
         true <- valid_options?(opts) do
      rank(registry(opts), query |> String.trim_leading("/") |> String.downcase())
      |> Enum.map(&Map.drop(&1, [:definition]))
    else
      _ -> []
    end
  end

  @doc """
  Parses a slash command into an explicit intent without executing it. Text is
  limited to 262144 bytes and names to 256 bytes. Errors contain only fixed atoms.
  Options accept `:custom`, `:workflows`, and model effort lists `:efforts` and
  `:swarm_efforts`. Dynamic identifiers stay strings; no input becomes an atom.
  """
  @spec parse(term(), keyword()) :: {:ok, command()} | {:error, error()}
  def parse(text, opts \\ []) do
    cond do
      not valid_options?(opts) -> error(:invalid_options)
      not is_binary(text) -> error(:invalid_command)
      byte_size(text) > @max_text -> error(:input_too_large)
      not String.valid?(text) -> error(:invalid_command)
      true -> parse_text(String.trim(text), opts)
    end
  end

  defp parse_text("/" <> rest, opts) do
    {raw, args} = split_first(rest)
    name = String.downcase(raw)

    if valid_name?(name) do
      case Enum.find(registry(opts), &(&1.name == name)) do
        nil -> error(:unknown_command)
        item -> parse_known(item, args, opts)
      end
    else
      error(:invalid_command)
    end
  end

  defp parse_text(_, _), do: error(:invalid_command)

  defp parse_known(%{kind: :custom} = item, args, _opts) do
    custom = item.definition
    body = value(custom, :body)
    mode = value(custom, :mode)
    swarm = value(custom, :swarm)

    cond do
      mode not in [nil, "build", "plan", :build, :plan] ->
        error(:invalid_metadata)

      swarm not in [nil, false, true] ->
        error(:invalid_metadata)

      expanded_size(body, args) > @max_text ->
        error(:expansion_too_large)

      true ->
        ok(item, if(swarm == true, do: :start_swarm, else: :start_turn), %{
          arguments: args,
          prompt: String.trim(String.replace(body, "$ARGUMENTS", args)),
          mode: mode_atom(mode),
          swarm: swarm == true,
          scope: item.scope
        })
    end
  end

  defp parse_known(%{kind: :workflow} = item, args, _opts),
    do: workflow_launch(item, item.name, args)

  defp parse_known(%{name: name} = item, args, opts) when name in ["effort", "swarm_effort"] do
    effort = Map.get(@efforts, String.downcase(args))
    key = if name == "effort", do: :efforts, else: :swarm_efforts
    allowed = Keyword.get(opts, key, [:low, :medium, :high, :max])

    cond do
      args == "" ->
        error(:missing_argument)

      not is_list(allowed) ->
        error(:invalid_options)

      effort == nil ->
        error(:invalid_effort)

      not Enum.any?(allowed, &(effort_atom(&1) == effort)) ->
        error(:invalid_effort)

      true ->
        ok(item, :set_effort, %{
          effort: effort,
          target: if(name == "effort", do: :chat, else: :swarm)
        })
    end
  end

  defp parse_known(%{name: "swarm"}, "", _), do: error(:missing_argument)

  defp parse_known(%{name: "swarm"} = item, args, _) do
    case split_first(args) do
      {"/goal", ""} ->
        error(:missing_argument)

      {"/goal", text} ->
        nested = %{
          name: "goal",
          kind: :builtin,
          action: :pursue_goal,
          mode: :goal,
          text: text,
          execution: :swarm
        }

        ok(item, :pursue_goal, %{
          mode: :goal,
          text: text,
          execution: :swarm,
          task: args,
          nested: nested
        })

      _ ->
        ok(item, :start_swarm, %{task: args})
    end
  end

  defp parse_known(%{name: "goal"} = item, "", _), do: ok(item, :show_goal)

  defp parse_known(%{name: "goal"} = item, text, _),
    do: ok(item, :pursue_goal, %{mode: :goal, text: text, execution: :chat})

  defp parse_known(%{name: "plan"} = item, "", _), do: ok(item, :toggle_mode, %{mode: :plan})
  defp parse_known(%{name: "plan"}, _, _), do: error(:unexpected_argument)

  defp parse_known(%{name: "ultra"} = item, args, _) do
    case String.downcase(args) do
      "" -> ok(item, :toggle_mode, %{mode: :ultra})
      "on" -> ok(item, :set_mode, %{mode: :ultra})
      "off" -> ok(item, :set_mode, %{mode: :build})
      _ -> error(:invalid_argument)
    end
  end

  defp parse_known(%{name: "consensus"} = item, "", _),
    do: ok(item, :set_mode, %{mode: :consensus})

  defp parse_known(%{name: "consensus"} = item, task, _),
    do: ok(item, :start_turn, %{mode: :consensus, task: task})

  defp parse_known(%{name: "create-workflow"} = item, args, _) do
    if String.downcase(args) == "off",
      do: ok(item, :disable_workflow_authoring),
      else: author_workflow(item, args)
  end

  defp parse_known(%{name: "workflow"}, "", _), do: error(:missing_argument)
  defp parse_known(%{name: "workflow"} = item, args, opts), do: workflow_command(item, args, opts)
  defp parse_known(%{name: "deep_research"} = item, "", _), do: ok(item, :select_research)

  defp parse_known(%{name: "deep_research"} = item, id, _) do
    if valid_text?(id, @max_label) and not Regex.match?(~r/\s/, id),
      do: ok(item, :attach_research, %{research: id}),
      else: error(:invalid_argument)
  end

  defp parse_known(%{name: "attach"}, "", _), do: error(:missing_argument)

  defp parse_known(%{name: "attach"} = item, path, _) do
    if valid_text?(path, 4096) and not String.contains?(path, ["\0", "\r", "\n"]),
      do: ok(item, :attach_file, %{path: path}),
      else: error(:invalid_argument)
  end

  defp parse_known(%{name: "compact"} = item, focus, _), do: ok(item, :compact, %{focus: focus})

  defp parse_known(%{name: name} = item, args, _) when is_map_key(@no_args, name) do
    if args == "", do: ok(item, Map.fetch!(@no_args, name)), else: error(:unexpected_argument)
  end

  defp workflow_command(item, args, opts) do
    {head, tail} = split_first(args)

    cond do
      head == "run" ->
        {name, rest} = split_first(tail)

        cond do
          name == "" -> error(:missing_argument)
          workflow_definition(opts, name) == nil -> error(:unknown_workflow)
          true -> workflow_launch(item, name, rest)
        end

      head in ["pause", "resume", "stop"] ->
        workflow_control(item, head, tail)

      head == "save" ->
        workflow_save(item, tail)

      workflow_definition(opts, head) != nil ->
        workflow_launch(item, head, tail)

      true ->
        author_workflow(item, args)
    end
  end

  defp workflow_control(_item, _control, ""), do: error(:missing_argument)

  defp workflow_control(item, "resume", tail) do
    {run, args} = split_first(tail)
    {inputs, rest} = workflow_args(args)

    with true <- valid_text?(run, @max_label),
         true <- rest == "" and Enum.all?(Map.keys(inputs), &(&1 == "budget")),
         {:ok, budget} <- budget(inputs["budget"]) do
      ok(item, :control_workflow, %{control: :resume, run: run, budget: budget})
    else
      {:error, _} = error -> error
      _ -> error(:invalid_argument)
    end
  end

  defp workflow_control(item, control, run) do
    if valid_text?(run, @max_label),
      do: ok(item, :control_workflow, %{control: Map.fetch!(@controls, control), run: run}),
      else: error(:invalid_argument)
  end

  defp workflow_save(item, tail) do
    case Regex.run(~r/^(\S+)\s+as\s+([A-Za-z0-9_.-]+)(?:\s+scope=(project|user))?$/, tail) do
      [_, run, name | scope] ->
        if valid_text?(run, @max_label) and valid_name?(name) do
          scope = if List.first(scope) == "user", do: :user, else: :project
          ok(item, :save_workflow, %{run: run, workflow: name, scope: scope})
        else
          error(:invalid_argument)
        end

      _ ->
        error(:invalid_argument)
    end
  end

  defp workflow_launch(item, name, args) do
    {inputs, input} = workflow_args(args)

    if Enum.all?(Map.keys(inputs), &valid_text?(&1, @max_label)) do
      ok(%{item | kind: :workflow}, :launch_workflow, %{
        workflow: name,
        arguments: args,
        inputs: inputs,
        input: input
      })
    else
      error(:invalid_argument)
    end
  end

  # Web Args.parse grammar: quoted key=value pairs, last duplicate wins, all
  # other tokens become the free-text input. Keys remain strings in the CLI.
  defp workflow_args(text) do
    matches = Regex.scan(~r/([a-zA-Z_][a-zA-Z0-9_-]*)=(?:"([^"]*)"|(\S+))|(\S+)/, text)

    {pairs, rest} =
      Enum.reduce(matches, {%{}, []}, fn match, {pairs, rest} ->
        case match ++ List.duplicate("", 5 - length(match)) do
          [_all, "", "", "", word] -> {pairs, [word | rest]}
          [_all, key, "", value, _] -> {Map.put(pairs, key, value), rest}
          [_all, key, quoted, _, _] -> {Map.put(pairs, key, quoted), rest}
        end
      end)

    {pairs, rest |> Enum.reverse() |> Enum.join(" ")}
  end

  defp budget(nil), do: {:ok, nil}

  defp budget(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> error(:invalid_budget)
    end
  end

  defp author_workflow(item, prompt) do
    prompt =
      if prompt == "",
        do: "I want to create a new workflow. Ask me what it should do.",
        else: prompt

    ok(item, :author_workflow, %{mode: :workflow, prompt: prompt})
  end

  defp registry(opts) do
    builtins =
      Enum.map(@builtins, fn {name, args, desc} ->
        %{name: name, args: args, desc: desc, scope: nil, kind: :builtin}
      end)

    workflows = dynamic(Keyword.get(opts, :workflows, []), :workflow)
    custom = dynamic(Keyword.get(opts, :custom, []), :custom)
    Enum.uniq_by(builtins ++ workflows ++ custom, & &1.name)
  end

  defp workflow_definition(opts, name) do
    Enum.find(dynamic(Keyword.get(opts, :workflows, []), :workflow), &(&1.name == name))
  end

  defp dynamic(entries, kind) do
    entries
    |> Enum.take(@max_entries)
    |> Enum.filter(fn entry ->
      valid_name?(value(entry, :name)) and
        (kind != :custom or valid_text?(value(entry, :body), @max_text))
    end)
    |> Enum.sort_by(fn entry ->
      if value(entry, :scope) in [:project, "project"], do: 0, else: 1
    end)
    |> Enum.uniq_by(&(value(&1, :name) |> String.downcase()))
    |> Enum.map(fn entry ->
      meta = value(entry, :meta)
      desc = value(entry, :description) || value(meta, :description) || ""

      %{
        name: entry |> value(:name) |> String.downcase(),
        kind: kind,
        definition: entry,
        desc: if(valid_text?(desc, @max_label), do: desc, else: ""),
        scope: scope_atom(value(entry, :scope)),
        args: args_hint(entry, kind)
      }
    end)
  end

  defp args_hint(entry, :custom) do
    if String.contains?(value(entry, :body), "$ARGUMENTS"), do: "<args>", else: ""
  end

  defp args_hint(entry, :workflow) do
    explicit = value(entry, :args)
    declared = entry |> value(:meta) |> value(:args)

    cond do
      valid_text?(explicit, @max_label) ->
        explicit

      is_map(declared) ->
        declared
        |> Enum.take(32)
        |> Enum.sort_by(fn {key, _} -> label(key) end)
        |> Enum.map_join(" ", fn {key, spec} ->
          "#{label(key)}=<#{label(value(spec, :type) || :string)}>"
        end)
        |> truncate_label()

      true ->
        ""
    end
  end

  defp valid_options?(opts) do
    Keyword.keyword?(opts) and
      Enum.all?([:workflows, :custom], fn key -> is_list(Keyword.get(opts, key, [])) end)
  end

  defp valid_text?(text, max),
    do: is_binary(text) and byte_size(text) <= max and String.valid?(text)

  defp valid_name?(name),
    do: valid_text?(name, @max_label) and Regex.match?(~r/^[A-Za-z0-9_.-]+$/, name)

  defp value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp value(_, _), do: nil
  defp label(value) when is_atom(value), do: value |> Atom.to_string() |> truncate_label()

  defp label(value) when is_binary(value),
    do: if(String.valid?(value), do: truncate_label(value), else: "")

  defp label(_), do: ""

  defp truncate_label(text) do
    if byte_size(text) <= @max_label,
      do: text,
      else:
        text
        |> String.graphemes()
        |> Enum.reduce_while("", fn char, acc ->
          if byte_size(acc) + byte_size(char) <= @max_label,
            do: {:cont, acc <> char},
            else: {:halt, acc}
        end)
  end

  defp scope_atom(value) when value in [:project, "project"], do: :project
  defp scope_atom(value) when value in [:global, "global"], do: :global
  defp scope_atom(value) when value in [:user, "user"], do: :user
  defp scope_atom(_), do: nil
  defp mode_atom(value) when is_atom(value), do: Map.get(@mode_atoms, Atom.to_string(value))
  defp mode_atom(value), do: Map.get(@mode_atoms, value)
  defp effort_atom(value) when is_atom(value), do: Map.get(@efforts, Atom.to_string(value))
  defp effort_atom(value), do: Map.get(@efforts, value)

  defp expanded_size(body, args) do
    count = length(:binary.matches(body, "$ARGUMENTS"))
    byte_size(body) + count * (byte_size(args) - byte_size("$ARGUMENTS"))
  end

  defp split_first(text) do
    case String.split(String.trim(text), ~r/\s+/, parts: 2, trim: true) do
      [] -> {"", ""}
      [head] -> {head, ""}
      [head, tail] -> {head, String.trim(tail)}
    end
  end

  defp ok(item, action, fields \\ %{}),
    do: {:ok, Map.merge(%{name: item.name, kind: item.kind, action: action}, fields)}

  defp error(type), do: {:error, %{type: type}}
  defp rank(items, ""), do: items

  defp rank(items, query) do
    items
    |> Enum.with_index()
    |> Enum.filter(fn {item, _} -> score(item.name, query) != nil end)
    |> Enum.sort_by(fn {item, index} -> {score(item.name, query), index} end)
    |> Enum.map(&elem(&1, 0))
  end

  defp score(name, query) do
    cond do
      String.starts_with?(name, query) -> 0
      Enum.any?(String.split(name, ["-", "_", "."]), &String.starts_with?(&1, query)) -> 1
      true -> nil
    end
  end
end
