defmodule SwarmCodeCLI.UI.ArchitectureTest do
  use ExUnit.Case, async: true

  @lib_root Path.expand("../../../lib", __DIR__)
  @implementation_names ~w(ExRatatui Ratatui Rustler ResourceArc SwarmCodeDaemon FoundationGate)
  @source_patterns [
    "swarm_code_daemon",
    "daemon[_ -]?ipc",
    "(^|[\\/.])database([\\/.]|$)",
    "(?:^|[^[:alnum:]_])(?:apply|module\\.concat|code\\.(?:load|ensure_loaded)|:code\\.)",
    "ecto\\.repo"
  ]

  test "CLI library remains renderer, daemon, repo, and database neutral" do
    violations =
      @lib_root
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.reject(&exempt?/1)
      |> Enum.flat_map(&violations/1)

    assert violations == []
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
    assert scan_source("# ExRatatui.draw(scene)\n:ok", "fixture.ex") == []
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
    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, [:Module]}, :concat]}, _, _} = node, acc ->
          {node, [{path, :dynamic_module_lookup, "Module.concat"} | acc]}

        {:apply, _, _} = node, acc ->
          {node, [{path, :dynamic_module_lookup, "apply/3"} | acc]}

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
