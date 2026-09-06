defmodule SwarmCodeCLI.UI.ArchitectureTest do
  use ExUnit.Case, async: true

  @lib_root Path.expand("../../../lib", __DIR__)
  @mix_file Path.expand("../../../mix.exs", __DIR__)
  @implementation_names ~w(ExRatatui Ratatui Rustler ResourceArc SwarmCodeDaemon FoundationGate DatabasePath Exqlite SQLite3 DBPath)
  @source_patterns [
    "swarm_code_daemon",
    "daemon[_ -]?ipc",
    "(^|[\\/.])database([\\/.]|$)",
    "(?:^|[^[:alnum:]_])(?:module\\.concat|code\\.(?:load|ensure_loaded)|:code\\.)",
    "ecto\\.repo",
    "exqlite",
    "database_path",
    "databasepath",
    "db_path"
  ]

  test "CLI library remains renderer, daemon, repo, and database neutral" do
    violations =
      @lib_root
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.reject(&exempt?/1)
      |> Enum.flat_map(&violations/1)

    assert violations == []
    assert @mix_file |> File.read!() |> scan_mix_dependencies() == []
    refute scan_mix_dependencies("defp deps, do: [{:rustler, \"0.1\"}]") == []
    refute scan_mix_dependencies("defp deps, do: [{:swarm_code_daemon, in_umbrella: true}]") == []
  end

  test "the exemption is an exact conditional adapter directory, not a sibling file" do
    assert exempt?(Path.join(@lib_root, "swarm_code_cli/ui/renderer/ex_ratatui_013/adapter.ex"))
    refute exempt?(Path.join(@lib_root, "swarm_code_cli/ui/renderer/ex_ratatui_013.ex"))
    refute exempt?(Path.join(@lib_root, "swarm_code_cli/ui/renderer/ex_ratatui_013_adapter.ex"))
    refute exempt?(Path.join(@lib_root, "other/ui/renderer/ex_ratatui_013/evil.ex"))
  end

  test "adversarial implementation coupling forms are rejected while comments are ignored" do
    forbidden = [
      "ExRatatui.draw(scene)",
      "&Ratatui.draw/1",
      "apply(Rustler, :call, [])",
      "Module.concat([\"Ex\", \"Rata\", \"tui\"])",
      "apply(module, :draw, [scene])",
      ":code.add_path(path)",
      ":code.load_file(:resource_arc)",
      "Code.ensure_loaded(FoundationGate)",
      "use Ecto.Repo",
      "{:swarm_code_daemon, path: \"priv/database/state.db\"}",
      "DaemonIPC.call(:status)"
    ]

    assert Enum.all?(forbidden, &(scan_source(&1, "fixture.ex") != []))

    assert scan_source(
             "defp apply_delivery(state, delivery), do: {state, delivery}",
             "fixture.ex"
           ) == []

    assert scan_source(":database_path", "fixture.ex") != []
    assert scan_source("DatabasePath.resolve()", "fixture.ex") != []
    assert scan_source("Exqlite.Sqlite3.open(\"x\")", "fixture.ex") != []
    assert scan_source("# ExRatatui.draw(scene)\n:ok", "fixture.ex") == []
  end

  defp scan_mix_dependencies(source), do: scan_source(source, @mix_file)

  test "the neutral editor apply API is a definition, not dynamic module dispatch" do
    assert scan_source(
             "def apply(editor, operation), do: operate(editor, operation)",
             "fixture.ex"
           ) == []

    assert scan_source("@spec apply(t(), Operation.t()) :: {:ok, t()}", "fixture.ex") == []

    assert scan_source("@spec apply(t, Operation.t()) :: {:ok, t} when t: term()", "fixture.ex") ==
             []

    assert scan_source(
             "def apply(editor, operation), do: apply(module, :run, [editor, operation])",
             "fixture.ex"
           ) != []

    assert scan_source(
             "def apply(editor, operation), do: Kernel.apply(fun, [operation])",
             "fixture.ex"
           ) != []

    assert scan_source("(&Kernel.apply/3).(module, :run, [])", "fixture.ex") != []
    assert scan_source("(&:erlang.apply/3).(module, :run, [])", "fixture.ex") != []
    assert scan_source("(&Kernel.apply/2).(fun, [])", "fixture.ex") != []
  end

  defp exempt?(path) do
    root = Path.expand("swarm_code_cli/ui/renderer/ex_ratatui_013", @lib_root)
    expanded = Path.expand(path)
    expanded == root or String.starts_with?(expanded, root <> "/")
  end

  defp violations(path) do
    source = File.read!(path)
    scan_source(source, path)
  end

  defp scan_source(source, path) do
    code = strip_comments(source)

    source_violations =
      for source <- @source_patterns,
          pattern = Regex.compile!(source, "i"),
          Regex.match?(pattern, code),
          do: {path, :source, source}

    ast_violations =
      case Code.string_to_quoted(source, file: path) do
        {:ok, ast} -> ast_violations(ast, path)
        {:error, reason} -> [{path, :parse_error, reason}]
      end

    source_violations ++ ast_violations
  end

  defp strip_comments(source) do
    source
    |> String.split("\n")
    |> Enum.map_join("\n", fn line ->
      case String.split(line, "#", parts: 2) do
        [code | _] -> code
      end
    end)
  end

  defp ast_violations(ast, path) do
    # An API named apply/2 is not Kernel's dynamic apply. Strip only the name
    # from definition/spec heads; argument defaults, guards and bodies still
    # undergo the same scan, including all actual apply invocations.
    ast =
      Macro.prewalk(ast, fn
        {kind, meta, [head | body]} when kind in [:def, :defp] ->
          {kind, meta, [neutral_definition_head(head) | body]}

        {:@, meta, [{:spec, spec_meta, [spec]}]} ->
          {:@, meta, [{:spec, spec_meta, [neutral_spec_head(spec)]}]}

        node ->
          node
      end)

    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, [:Module]}, :concat]}, _, _} = node, acc ->
          {node, [{path, :dynamic_module_lookup, "Module.concat"} | acc]}

        {:apply, _, _} = node, acc ->
          {node, [{path, :dynamic_module_lookup, "apply/3"} | acc]}

        {{:., _, [{:__aliases__, _, [:Kernel]}, :apply]}, _, args} = node, acc
        when length(args) in [2, 3] ->
          {node, [{path, :dynamic_module_lookup, "Kernel.apply"} | acc]}

        {{:., _, [:erlang, :apply]}, _, args} = node, acc when length(args) in [2, 3] ->
          {node, [{path, :dynamic_module_lookup, ":erlang.apply"} | acc]}

        {{:., _, [:code, function]}, _, _} = node, acc ->
          {node, [{path, :code_path_load, Atom.to_string(function)} | acc]}

        {{:., _, [{:__aliases__, _, [:Code]}, function]}, _, _} = node, acc
        when function in [
               :ensure_loaded,
               :ensure_loaded?,
               :load_file,
               :require_file,
               :prepend_path,
               :append_path
             ] ->
          {node, [{path, :code_path_load, Atom.to_string(function)} | acc]}

        {:&, _, [{:/, _, [{{:., _, [{:__aliases__, _, [:Kernel]}, :apply]}, _, _}, arity]}]} =
            node,
        acc
        when arity in [2, 3] ->
          {node, [{path, :dynamic_module_lookup, "captured Kernel.apply"} | acc]}

        {:&, _, [{:/, _, [{{:., _, [:erlang, :apply]}, _, _}, arity]}]} = node, acc
        when arity in [2, 3] ->
          {node, [{path, :dynamic_module_lookup, "captured :erlang.apply"} | acc]}

        {:&, _, [captured]} = node, acc ->
          rendered = Macro.to_string(captured)
          {node, maybe_forbidden(rendered, path, :capture, acc)}

        {:__aliases__, _, parts} = node, acc ->
          name = Enum.map_join(parts, ".", &to_string/1)
          {node, maybe_forbidden(name, path, :alias, acc)}

        atom, acc when is_atom(atom) ->
          {atom, maybe_forbidden(Atom.to_string(atom), path, :atom, acc)}

        binary, acc when is_binary(binary) ->
          {binary, maybe_forbidden(binary, path, :literal, acc)}

        node, acc ->
          {node, acc}
      end)

    Enum.uniq(found)
  end

  defp neutral_definition_head({:when, meta, [head | guards]}),
    do: {:when, meta, [neutral_definition_head(head) | guards]}

  defp neutral_definition_head({:apply, meta, args}), do: {:declared_apply, meta, args}
  defp neutral_definition_head(head), do: head

  defp neutral_spec_head({:when, meta, [spec | constraints]}),
    do: {:when, meta, [neutral_spec_head(spec) | constraints]}

  defp neutral_spec_head({:"::", meta, [head, result]}),
    do: {:"::", meta, [neutral_definition_head(head), result]}

  defp neutral_spec_head(spec), do: spec

  defp maybe_forbidden(name, path, kind, acc) do
    compact = String.replace(name, ["_", "."], "")

    denied? =
      Enum.any?(@implementation_names, fn denied ->
        String.contains?(
          String.downcase(compact),
          String.downcase(String.replace(denied, ".", ""))
        )
      end) or String.contains?(name, "Ecto.Repo")

    if denied?, do: [{path, kind, name} | acc], else: acc
  end
end
