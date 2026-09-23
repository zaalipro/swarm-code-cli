defmodule SwarmCode.Domain.Workflows.Smoke do
  @moduledoc """
  The smoke check of spec 09 §4.4 and spec 11 §7.2: parse, cast the args, lint
  for non-determinism and forbidden file-system calls, and run the one path the
  args select against a canned Runner.

  With `root:` the read-only host helpers run **against the real project tree**
  (agents stay canned), so a shard discovery that finds nothing is caught before
  the workflow is ever saved: a path that completes without spawning a single
  agent is not `ok?`. Without `root:` — the Library shape preview — host calls
  answer with fixed sample values, as before.
  """

  alias SwarmCode.Domain.Workflows
  alias SwarmCode.Domain.Workflows.{API, Canned, Definition, Runner}

  defstruct ok?: false,
            ended: :error,
            error: nil,
            phases: [],
            agents_total: 0,
            max_panel: 0,
            gates: 0,
            warnings: [],
            trace: []

  @type t :: %__MODULE__{}

  @timeout 5_000

  # Spec 11 §7.1: touching the file system from a definition is an error, not a
  # warning — the host helpers are the only blessed way in.
  @forbidden_modules [File]

  @forbidden [
    {System, :cmd},
    {System, :shell},
    {:os, :cmd},
    {Path, :expand},
    {Path, :absname},
    {Path, :wildcard}
  ]

  @fs_message "use host(:list_dir | :subdirs | :files | :read_file | …) — " <>
                "scripts must not touch the filesystem directly"

  @nondeterministic [
    {DateTime, :utc_now},
    {DateTime, :now},
    {DateTime, :now!},
    {Date, :utc_today},
    {NaiveDateTime, :utc_now},
    {NaiveDateTime, :local_now},
    {System, :monotonic_time},
    {System, :os_time},
    {System, :system_time},
    {System, :unique_integer},
    {Enum, :random},
    {Enum, :shuffle},
    {Enum, :take_random},
    {Process, :sleep},
    {:rand, :uniform},
    {:rand, :uniform_real},
    {:os, :timestamp}
  ]

  # ------------------------------------------------------- the allow-list
  #
  # Sakana task 4: workflow source is model-authored, so validation is a closed
  # allow-list rather than a blacklist of remote calls — `apply/3`, a capture of
  # a forbidden module or `mod.fun(...)` through a variable all used to slip
  # past. Everything here is pure: no filesystem, no shell, no process, no code
  # loading, no VM control. Extend it only when a benign call in a real
  # definition is refused.

  @denied "is not allowed in a workflow"

  # Whole modules that only compute.
  @allowed_modules [
    Enum,
    Map,
    MapSet,
    List,
    String,
    Regex,
    Integer,
    Float,
    Jason,
    DateTime,
    Date,
    Access
  ]

  # `Path` is allowed only for the pure name arithmetic; `expand`, `absname`
  # and `wildcard` stay forbidden above.
  @allowed_path ~w(join basename dirname extname relative_to split rootname type)a

  @allowed_kernel ~w(
    + - * / == != === !== < > <= >= and or not && || ! ++ -- <> in
    abs div rem elem tuple_size length hd tl max min round trunc ceil floor
    inspect to_string to_charlist byte_size bit_size map_size get_in put_in
    is_atom is_binary is_bitstring is_boolean is_exception is_float is_function
    is_integer is_list is_map is_map_key is_nil is_number is_pid is_port
    is_reference is_struct is_tuple
  )a

  # Operators, special forms and comprehensions. `.` and `__aliases__` show up
  # as nodes of calls their parent already validated.
  @allowed_forms ~w(
    . __aliases__ __block__ = -> <- when fn & % %{} {} <<>> :: | .. ..//
    + - * / ++ -- <> == != === !== < > <= >= && || ! and or not in |>
    if unless case cond for with raise reraise throw try
    abs div rem elem tuple_size length hd tl max min round trunc ceil floor
    inspect to_string to_charlist byte_size bit_size map_size get_in put_in
    is_atom is_binary is_bitstring is_boolean is_exception is_float is_function
    is_integer is_list is_map is_map_key is_nil is_number is_pid is_port
    is_reference is_struct is_tuple
    sigil_r sigil_R sigil_s sigil_S sigil_c sigil_C sigil_w sigil_W
    sigil_D sigil_T sigil_U sigil_N
  )a

  # spec 60 T32: the runner's own plumbing is public on `API` (the smoke Task and
  # the panel slots call it) but is not script surface — `put_context/1` would
  # re-root every later host call.
  @api_internal ~w(context put_context bound_heap heap_error)a

  # spec 60 T34: `String`/`List` are allowed modules, but interning model text
  # as atoms is not — the atom table never shrinks.
  @atom_forming [{String, :to_atom}, {List, :to_atom}]

  # Everything `Runner.eval/2` imports — the documented workflow DSL.
  @api_functions SwarmCode.Domain.Workflows.API.__info__(:functions)
                 |> Enum.reject(fn {name, _} -> name in @api_internal end)

  @doc """
  Runs the check against a definition or a raw source. `opts[:root]` makes the
  read-only host helpers run against that project tree (spec 11 §7.2).
  """
  @spec check(Definition.t() | String.t(), map(), keyword()) ::
          {:ok, t()} | {:error, [String.t()]}
  def check(definition_or_source, args \\ %{}, opts \\ [])

  def check(source, args, opts) when is_binary(source) do
    case Workflows.parse(source, "adhoc", nil) do
      {:ok, definition} -> check(definition, args, opts)
      {:error, problems} -> {:error, problems}
    end
  end

  def check(%Definition{problems: problems}, _args, _opts) when problems != [],
    do: {:error, problems}

  def check(%Definition{} = definition, args, opts) do
    case errors(definition) do
      [] -> cast_and_run(definition, args, opts)
      problems -> {:error, problems}
    end
  end

  defp cast_and_run(definition, args, opts) do
    case Workflows.cast_args(definition.meta, fill_required(definition, args)) do
      {:error, problems} ->
        {:error, problems}

      {:ok, cast} ->
        # spec 68 T30: lint/1 removed (always returned [])
        warnings = []
        {:ok, run_canned(definition, cast, warnings, opts)}
    end
  end

  # A shape preview has to work before anyone types an argument: required args
  # with no default get a canned value (§4.4 step 4 uses the same `Schema`
  # sample rules). `launch/1` stays strict — it is the launch form's job to ask.
  defp fill_required(%Definition{} = definition, args) do
    definition
    |> Definition.arg_specs()
    |> Enum.reduce(args, fn {key, spec}, acc ->
      cond do
        Map.has_key?(acc, key) or Map.has_key?(acc, to_string(key)) -> acc
        !spec[:required] -> acc
        Map.has_key?(spec, :default) -> acc
        true -> Map.put(acc, to_string(key), sample_for(spec))
      end
    end)
  end

  defp sample_for(spec) do
    case spec[:type] || :string do
      :integer -> 1
      :number -> 1
      :boolean -> true
      :list -> "sample"
      :enum -> to_string(List.first(spec[:values] || ["sample"]))
      :path -> "lib/sample.ex"
      _other -> "sample"
    end
  end

  defp run_canned(definition, args, warnings, opts) do
    budget = definition.meta[:budget] || 128
    root = opts[:root]
    {:ok, canned} = Canned.start_link(budget: budget, root: root)

    ctx = %{
      run_id: "smoke",
      runner: canned,
      root: root || File.cwd!(),
      display_name: "smoke",
      panel: nil,
      calls: 0,
      agent_called?: false
    }

    task =
      Task.Supervisor.async_nolink(SwarmCode.Domain.TaskSupervisor, fn ->
        API.bound_heap()
        API.put_context(ctx)
        Runner.eval(definition.ast, args: args, meta: definition.meta)
      end)

    outcome =
      case Task.yield(task, @timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, value} -> value
        # Spec 51 §7.7 (M8): `bound_heap/0` killed the Task at 512 MB.
        {:exit, :killed} -> {:failed, API.heap_error()}
        _ -> {:failed, "the workflow did not finish within #{div(@timeout, 1000)} seconds"}
      end

    state = Canned.result(canned)
    GenServer.stop(canned)

    {ended, error} = classify(outcome)

    phases = shape_phases(definition, state.phases)
    agents = Enum.sum(Enum.map(phases, & &1.agents))

    # A path that spends no agent at all is not a workflow — it is a work-list
    # that came out empty against this project (spec 11 §7.2).
    {ended, error} =
      if root && ended == :complete && agents == 0,
        do:
          {:no_agents,
           "this workflow completes without spawning any agent for this project — " <>
             "the work-list is empty"},
        else: {ended, error}

    %__MODULE__{
      ok?: ended in [:complete, :pause, :await_user],
      ended: ended,
      error: error,
      phases: phases,
      agents_total: agents,
      max_panel: phases |> Enum.flat_map(& &1.panels) |> Enum.max(fn -> 0 end),
      gates: state.gates,
      warnings: warnings ++ phase_warnings(definition, state.phases),
      trace: state.trace
    }
  end

  # Phases the definition promised but never marked still show in the preview,
  # and every phase carries the authored detail (spec 11 §R.1).
  defp shape_phases(definition, seen) do
    declared = Definition.phase_titles(definition)
    details = Definition.phase_details(definition)
    titles = Enum.map(seen, & &1.title)

    declared
    |> Enum.reject(&(&1 in titles))
    |> Enum.map(&%{title: &1, agents: 0, panels: []})
    |> then(&(seen ++ &1))
    |> Enum.map(&Map.put(&1, :detail, Map.get(details, &1.title)))
  end

  defp classify({:complete, _value}), do: {:complete, nil}
  defp classify({:pause, "budget", message}), do: {:budget, message}
  defp classify({:pause, _kind, message}), do: {:pause, message}
  defp classify({:await_user, question, _options, _seq, _slot}), do: {:await_user, question}
  defp classify({:failed, message}), do: {:error, message}
  defp classify(other), do: {:error, inspect(other)}

  # ------------------------------------------------------------------ lint

  @doc """
  Error-level lint (spec 11 §7.1 and sakana task 4): a definition may not touch
  the file system, shell out or expand paths itself, and — since the source is
  model-authored and therefore untrusted — may only call the workflow API and an
  explicit allow-list of pure standard-library functions. The list is closed:
  anything not on it, including dynamic dispatch through a variable, is an
  error with its source line.
  """
  @spec errors(Definition.t()) :: [String.t()]
  def errors(%Definition{ast: nil}), do: []

  def errors(%Definition{ast: ast}), do: validate_ast(ast)

  @doc "The allow-list walk on its own; `:ok` or every problem, in source order."
  @spec validate_ast(Macro.t()) :: [String.t()]
  def validate_ast(nil), do: []

  def validate_ast(ast) do
    {_ast, problems} = Macro.prewalk(ast, [], &check_node/2)
    problems |> Enum.reverse() |> Enum.uniq()
  end

  # spec 60 T34: `Jason.decode(_, keys: :atoms)` interns every key of model output.
  defp check_node({{:., _, [{:__aliases__, _, [:Jason]}, name]}, meta, args} = node, acc)
       when name in [:decode, :decode!] and is_list(args) do
    atoms? =
      Enum.any?(args, fn arg ->
        is_list(arg) and Keyword.keyword?(arg) and Keyword.get(arg, :keys) in [:atoms, :atoms!]
      end)

    if atoms? do
      {node,
       [
         "line #{line(meta)}: Jason.#{name} with keys: :atoms creates atoms from text — " <>
           @denied
         | acc
       ]}
    else
      {node, remote(Jason, name, length(args), line(meta), acc)}
    end
  end

  # A remote call on a literal alias: `Enum.map(...)`, `Jason.encode!(...)`.
  defp check_node({{:., _, [{:__aliases__, _, mods}, name]}, meta, args} = node, acc)
       when is_atom(name) and is_list(args) do
    {node, remote(Module.concat(mods), name, length(args), line(meta), acc)}
  end

  # A remote call on an Erlang module: `:erlang.halt()`, `:os.cmd(...)`.
  defp check_node({{:., _, [module, name]}, meta, args} = node, acc)
       when is_atom(module) and is_atom(name) and is_list(args) do
    {node, remote(module, name, length(args), line(meta), acc)}
  end

  # `f.(x)` — calling an anonymous function held in a variable is fine.
  defp check_node({{:., _, [_single]}, _meta, args} = node, acc) when is_list(args) do
    {node, acc}
  end

  # `value.key` — plain map/struct field access, which the parser marks
  # `no_parens`. Agent results are maps, so this is everywhere.
  defp check_node({{:., _, [_target, name]}, meta, []} = node, acc) when is_atom(name) do
    if Keyword.get(meta, :no_parens, false) do
      {node, acc}
    else
      {node, [dynamic_problem(name, 0, line(meta)) | acc]}
    end
  end

  # `mod.fun(...)` where `mod` is a variable: dynamic dispatch, the hole the
  # direct-call blacklist never saw.
  defp check_node({{:., _, [_target, name]}, meta, args} = node, acc)
       when is_atom(name) and is_list(args) do
    {node, [dynamic_problem(name, length(args), line(meta)) | acc]}
  end

  defp check_node({name, meta, args} = node, acc) when is_atom(name) and is_list(args) do
    cond do
      # spec 60 T32
      name in @api_internal ->
        {node, ["line #{line(meta)}: #{name}/#{length(args)} is internal to the runner" | acc]}

      name in @allowed_forms ->
        {node, acc}

      {name, length(args)} in @api_functions ->
        {node, acc}

      true ->
        {node, ["line #{line(meta)}: #{name}/#{length(args)} " <> @denied | acc]}
    end
  end

  defp check_node(node, acc), do: {node, acc}

  defp remote(module, fun, arity, line, acc) do
    cond do
      # spec 60 T32
      module == SwarmCode.Domain.Workflows.API and fun in @api_internal ->
        ["line #{line}: #{fun}/#{arity} is internal to the runner" | acc]

      # spec 60 T34
      {module, fun} in @atom_forming ->
        [
          "line #{line}: #{inspect(module)}.#{fun}/#{arity} creates atoms from text — " <>
            @denied
          | acc
        ]

      module in @forbidden_modules or Enum.any?(@forbidden, &(&1 == {module, fun})) ->
        ["line #{line}: #{inspect(module)}.#{fun} — " <> @fs_message | acc]

      # Spec 51 §5.13: a replayed run would take a different path — an error
      # at save time, not a warning nobody reads.
      {module, fun} in @nondeterministic ->
        [
          "line #{line}: #{inspect(module)}.#{fun}/#{arity} is not deterministic — " <>
            "use host(:now) (a replayed run would take a different path)"
          | acc
        ]

      allowed_remote?(module, fun) ->
        acc

      true ->
        ["line #{line}: #{inspect(module)}.#{fun}/#{arity} " <> @denied | acc]
    end
  end

  defp allowed_remote?(module, fun) do
    cond do
      module in @allowed_modules -> true
      module == Path -> fun in @allowed_path
      module == Kernel -> fun in @allowed_kernel
      module == IO -> fun == :inspect
      true -> false
    end
  end

  defp dynamic_problem(name, arity, line) do
    "line #{line}: dynamic invocation #{name}/#{arity} #{@denied}"
  end

  defp line(meta), do: Keyword.get(meta, :line, 0)

  # spec 68 T30: lint/1, caught_by_errors?/2 and walk/2 removed — lint always
  # returned [] because caught_by_errors? checked the same @nondeterministic
  # list the guard already passed. Zero callers remain.

  defp phase_warnings(definition, seen) do
    declared = Definition.phase_titles(definition)
    marked = Enum.map(seen, & &1.title)

    missing = Enum.reject(declared, &(&1 in marked))
    extra = Enum.reject(marked, &(&1 in declared or &1 == "Run"))

    []
    |> then(fn acc ->
      if missing == [],
        do: acc,
        else: acc ++ ["phases in meta (#{Enum.join(missing, ", ")}) never marked in the body"]
    end)
    |> then(fn acc ->
      acc ++ Enum.map(extra, &"phase \"#{&1}\" marked but not listed in meta.phases")
    end)
  end
end
