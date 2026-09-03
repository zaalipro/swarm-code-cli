defmodule SwarmCodeCLI.UI.ArchitectureTest do
  use ExUnit.Case, async: true

  @lib_root Path.expand("../../../lib", __DIR__)
  @implementation_names ~w(ExRatatui Ratatui Rustler ResourceArc SwarmCodeDaemon FoundationGate)
  @source_patterns ["swarm_code_daemon", "daemon[_ -]?ipc", "(^|[\\/.])database([\\/.]|$)"]

  test "CLI library remains renderer, daemon, repo, and database neutral" do
    violations =
      @lib_root
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.reject(&String.contains?(&1, "/ui/renderer/ex_ratatui_013/"))
      |> Enum.flat_map(&violations/1)

    assert violations == []
  end

  test "the exemption is an exact conditional adapter directory, not a sibling file" do
    assert exempt?(Path.join(@lib_root, "swarm_code_cli/ui/renderer/ex_ratatui_013/adapter.ex"))
    refute exempt?(Path.join(@lib_root, "swarm_code_cli/ui/renderer/ex_ratatui_013.ex"))
    refute exempt?(Path.join(@lib_root, "swarm_code_cli/ui/renderer/ex_ratatui_013_adapter.ex"))
  end

  defp exempt?(path), do: String.contains?(path, "/ui/renderer/ex_ratatui_013/")

  defp violations(path) do
    source = File.read!(path)
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
