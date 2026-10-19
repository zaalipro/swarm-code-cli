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

  # `~w(...)a` interns every word as an atom.
  @atom_sigils [:sigil_w, :sigil_W]

  # Everything `Runner.eval/2` imports — the documented workflow DSL. Spec 74
  # ARCHITECTURE-5: read at runtime and memoised, not at compile time — a
  # compile-time `API.__info__/1` made this file recompile on any lib/ edit.
  defp api_functions do
    key = {__MODULE__, :api_functions}

    case :persistent_term.get(key, nil) do
      nil ->
        functions =
          SwarmCode.Domain.Workflows.API.__info__(:functions)
          |> Enum.reject(fn {name, _} -> name in @api_internal end)
          |> MapSet.new()

        :persistent_term.put(key, functions)
        functions

      functions ->
        functions
    end
  end

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
    with :ok <- validate_data(args),
         [] <- errors(definition) do
      cast_and_run(definition, args, opts)
    else
      {:error, problem} -> {:error, [problem]}
      problems when is_list(problems) -> {:error, problems}
    end
  end

  defp cast_and_run(definition, args, opts) do
    case Workflows.cast_args(definition.meta, fill_required(definition, args)) do
      {:error, problems} ->
        {:error, problems}

      {:ok, cast} ->
        case validate_data(cast) do
          :ok ->
            # spec 68 T30: lint/1 removed (always returned [])
            warnings = []
            {:ok, run_canned(definition, cast, warnings, opts)}

          {:error, _problem} ->
            {:error, [unsafe_value_problem(binding_line(definition))]}
        end
    end
  end

  defp binding_line(%Definition{source: source}) when is_binary(source) do
    case Code.string_to_quoted(source) do
      {:ok, {:__block__, _, [first | _]}} -> expression_line(first)
      {:ok, first} -> expression_line(first)
      _ -> 0
    end
  end

  defp binding_line(_definition), do: 0
  defp expression_line({_form, meta, _args}) when is_list(meta), do: line(meta)
  defp expression_line(_expression), do: 0

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
      :map -> %{}
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
  def errors(%Definition{} = definition) do
    binding_problems =
      if safe_data?(definition.meta),
        do: [],
        else: [unsafe_value_problem(binding_line(definition))]

    binding_problems ++ validate_ast(definition.ast)
  end

  @doc "The allow-list walk on its own; `:ok` or every problem, in source order."
  @spec validate_ast(Macro.t()) :: [String.t()]
  def validate_ast(nil), do: []

  def validate_ast(ast) do
    {_ast, {problems, _parents}} =
      Macro.traverse(
        ast,
        {[], []},
        fn node, {acc, parents} ->
          {node, {check_context(node, parents, acc), [node | parents]}}
        end,
        fn node, {_acc, [_parent | parents]} = state -> {node, put_elem(state, 1, parents)} end
      )

    problems |> Enum.reverse() |> Enum.uniq()
  end

  defp check_context(node, parents, acc) do
    {_node, acc} = check_node(node, acc)
    context_problem(node, parents, acc)
  end

  defp context_problem({:|>, meta, [left, right]}, _parents, acc) do
    case safe_pipe(left, right) do
      {:ok, piped} ->
        call_problem(piped, acc)

      :error ->
        case validate_ast(right) do
          [] -> [unsafe_value_problem(line(meta)) | acc]
          problems -> Enum.reverse(problems) ++ acc
        end
    end
  end

  defp context_problem({{:., _, [_module, _name]}, _, _args} = node, parents, acc) do
    {_, _, [receiver, name]} = elem(node, 0)

    cond do
      module_name(receiver) == Jason and name in [:decode, :decode!] and
          Enum.any?(parents, &match?({:&, _, _}, &1)) ->
        [json_problem(line(elem(node, 1))) | acc]

      match?([{:|>, _, [_left, ^node]} | _], parents) ->
        acc

      true ->
        call_problem(node, acc)
    end
  end

  defp context_problem({:%{}, meta, pairs}, _parents, acc) do
    if Enum.any?(pairs, fn
         {key, _value} when key in [:__struct__, "__struct__"] -> true
         _ -> false
       end) do
      [unsafe_value_problem(line(meta)) | acc]
    else
      acc
    end
  end

  defp context_problem({:%, meta, _parts}, _parents, acc),
    do: [unsafe_value_problem(line(meta)) | acc]

  defp context_problem({:__aliases__, meta, _parts} = node, parents, acc) do
    # Aliases are valid only as the statically checked receiver of a remote
    # call. Everywhere else they are module values, not workflow data.
    receiver? =
      case parents do
        [{:., _, [^node, _name]} | _] -> true
        _ -> false
      end

    if receiver?, do: acc, else: [unsafe_value_problem(line(meta)) | acc]
  end

  defp context_problem({:&, meta, [{:/, _, [call, _arity]}]}, _parents, acc) do
    case call do
      {{:., _, [module, name]}, _, _} ->
        cond do
          module_name(module) == Jason and name in [:decode, :decode!] ->
            [json_problem(line(meta)) | acc]

          admission_sensitive_call?(call) ->
            [unsafe_value_problem(line(meta)) | acc]

          true ->
            acc
        end

      {sigil, _, context} when sigil in @atom_sigils and is_atom(context) ->
        [unsafe_value_problem(line(meta)) | acc]

      _ ->
        acc
    end
  end

  # pass76 fix-m2-workflow-admission: `~w(__struct__ Elixir.File.Stream)a`
  # builds the forbidden key and module with no atom literal in the AST.
  # pass76 fix-m2-sigil-forms: every spelling funnels into `call_problem/2`,
  # which owns the rule. A piped sigil call is checked once, normalised, by its
  # `|>` parent.
  defp context_problem({sigil, _meta, args} = node, parents, acc)
       when sigil in @atom_sigils and is_list(args) do
    case parents do
      [{:|>, _, [_left, ^node]} | _] -> acc
      _ -> call_problem(node, acc)
    end
  end

  # `for ..., into: target` dispatches `Collectable` exactly like `Enum.into/2`.
  defp context_problem({:for, meta, [_ | _] = args}, _parents, acc) do
    case List.last(args) do
      options when is_list(options) ->
        case Keyword.fetch(options, :into) do
          {:ok, target} ->
            if literal_collectable?(target) or target == "",
              do: acc,
              else: [unsafe_value_problem(line(meta)) | acc]

          :error ->
            acc
        end

      _ ->
        acc
    end
  end

  defp context_problem(node, parents, acc) when is_atom(node) do
    receiver? =
      case parents do
        [{:., _, [^node, _name]} | _] -> true
        _ -> false
      end

    if node == :__struct__ or (module_atom?(node) and not receiver?),
      do: [unsafe_value_problem(parent_line(parents)) | acc],
      else: acc
  end

  defp context_problem(_node, _parents, acc), do: acc

  defp safe_pipe(left, right) do
    {:ok, Macro.pipe(left, right, 0)}
  rescue
    ArgumentError -> :error
  end

  defp call_problem({{:., _, [receiver, name]}, meta, args}, acc) do
    module = module_name(receiver)

    cond do
      module == Enum and name == :into ->
        if length(args) in [2, 3] and literal_collectable?(Enum.at(args, 1)),
          do: acc,
          else: [unsafe_value_problem(line(meta)) | acc]

      module == Jason and name in [:decode, :decode!] ->
        if length(args) == 1 or
             (length(args) == 2 and json_options?(Enum.at(args, 1))),
           do: acc,
           else: [json_problem(line(meta)) | acc]

      module == Kernel and name in @atom_sigils ->
        atom_sigil_problem(args, meta, acc)

      module in [String, List] and name in [:to_atom, :to_existing_atom] ->
        [unsafe_value_problem(line(meta)) | acc]

      true ->
        acc
    end
  end

  defp call_problem({sigil, meta, args}, acc) when sigil in @atom_sigils and is_list(args),
    do: atom_sigil_problem(args, meta, acc)

  defp call_problem(_call, acc), do: acc

  # Only a literal modifier list/string without `a` is provably atom-free; a
  # missing, computed or malformed modifier argument is refused.
  defp atom_sigil_problem([_string, modifiers], meta, acc) do
    safe? =
      cond do
        is_list(modifiers) -> Enum.all?(modifiers, &is_integer/1) and ?a not in modifiers
        is_binary(modifiers) -> not String.contains?(modifiers, "a")
        true -> false
      end

    if safe?, do: acc, else: [unsafe_value_problem(line(meta)) | acc]
  end

  defp atom_sigil_problem(_args, meta, acc), do: [unsafe_value_problem(line(meta)) | acc]

  defp literal_collectable?([]), do: true

  defp literal_collectable?({:%{}, _, pairs}) do
    Enum.all?(pairs, fn
      {key, _value} when key in [:__struct__, "__struct__"] -> false
      {key, _value} -> literal_key?(key)
      _ -> false
    end)
  end

  defp literal_collectable?(_value), do: false

  # pass76 fix-m2-workflow-admission: a computed key could evaluate to
  # `:__struct__`, turning the collectable into a forged struct.
  defp literal_key?(key), do: is_atom(key) or is_binary(key) or is_number(key)

  defp parent_line([{_name, meta, _args} | _]) when is_list(meta), do: line(meta)
  defp parent_line([_parent | parents]), do: parent_line(parents)
  defp parent_line([]), do: 0

  defp admission_sensitive_call?({{:., _, [module, name]}, _, _args}) do
    (module_name(module) == Enum and name == :into) or
      (module_name(module) == Kernel and name in @atom_sigils)
  end

  defp admission_sensitive_call?(_call), do: false

  defp module_name({:__aliases__, _, parts}), do: Module.concat(parts)
  defp module_name(module) when is_atom(module), do: module
  defp module_name(_module), do: nil

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

      MapSet.member?(api_functions(), {name, length(args)}) ->
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

  defp json_options?([]), do: true

  defp json_options?([{:keys, :strings}]), do: true

  defp json_options?(_options), do: false

  defp json_problem(line),
    do: "line #{line}: Jason decode options must be literal string-key options — #{@denied}"

  defp unsafe_value_problem(line),
    do: "line #{line}: unsafe workflow data #{@denied}"

  defp validate_data(value) do
    if safe_data?(value), do: :ok, else: {:error, "unsafe workflow data #{@denied}"}
  end

  defp safe_data?(value)
       when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value),
       do: true

  defp safe_data?(value) when is_atom(value) do
    value != :__struct__ and not module_atom?(value)
  end

  defp safe_data?([]), do: true

  defp safe_data?([head | tail]), do: safe_data?(head) and safe_list?(tail)

  defp safe_data?(value) when is_tuple(value), do: value |> Tuple.to_list() |> safe_list?()

  defp safe_data?(value) when is_map(value) do
    not Map.has_key?(value, :__struct__) and not Map.has_key?(value, "__struct__") and
      Enum.all?(value, fn {key, item} -> safe_data?(key) and safe_data?(item) end)
  end

  defp safe_data?(_value), do: false

  defp safe_list?([]), do: true
  defp safe_list?([head | tail]), do: safe_data?(head) and safe_list?(tail)
  defp safe_list?(_tail), do: false

  defp module_atom?(value),
    do: String.starts_with?(Atom.to_string(value), "Elixir.")

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
