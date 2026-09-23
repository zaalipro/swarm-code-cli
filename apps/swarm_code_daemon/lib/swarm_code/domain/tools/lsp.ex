# spec 70 B5
defmodule SwarmCode.Domain.Tools.Lsp do
  @moduledoc "Semantic code navigation via Language Server Protocol."
  @behaviour SwarmCode.Domain.Tools.Tool

  alias SwarmCode.Domain.Tools.Path, as: ToolsPath

  @operations ~w(goToDefinition findReferences hover documentSymbol workspaceSymbol goToImplementation)

  # Results from location-based operations: max items returned to the model.
  @max_results 50
  # Hover content cap in bytes.
  @max_hover 8_192
  # Characters of source context shown per location result.
  @context_chars 200

  @impl true
  def name, do: "lsp"

  @impl true
  def description do
    "Semantic code navigation via a language server. Operations: " <>
      "goToDefinition (jump to where a symbol is defined), " <>
      "findReferences (every use of a symbol), " <>
      "hover (type/doc info at a position), " <>
      "documentSymbol (outline of a file), " <>
      "workspaceSymbol (find symbols by name across the project), " <>
      "goToImplementation (concrete implementations of an interface/protocol). " <>
      "Requires a running language server for the file's language."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "operation" => %{
          "type" => "string",
          "enum" => @operations,
          "description" => "The LSP operation to perform"
        },
        "path" => %{
          "type" => "string",
          "description" => "File path (relative to project root)"
        },
        "line" => %{
          "type" => "integer",
          "description" => "1-based line number"
        },
        "character" => %{
          "type" => "integer",
          "description" => "1-based character offset"
        },
        "query" => %{
          "type" => "string",
          "description" => "Search query for workspaceSymbol (empty = all)"
        }
      },
      "required" => ["operation", "path"]
    }
  end

  @impl true
  def permission(_args), do: :read

  @impl true
  def title(args) do
    op = args["operation"] || "lsp"
    path = args["path"] || ""

    case op do
      "workspaceSymbol" -> "lsp workspaceSymbol #{args["query"] || ""}"
      "documentSymbol" -> "lsp documentSymbol #{path}"
      _ -> "lsp #{op} #{path}:#{args["line"] || "?"}:#{args["character"] || "?"}"
    end
  end

  @impl true
  def run(args, ctx, progress) do
    op = to_string(args["operation"] || "")

    if op not in @operations do
      {:error, "unknown operation: #{op}; valid: #{Enum.join(@operations, ", ")}"}
    else
      with {:ok, abs} <- ToolsPath.resolve(ctx.project_root, args["path"]) do
        progress.(nil, "lsp #{op}")

        lsp_opts = [
          lsp_servers: Map.get(ctx.settings || %{}, :lsp_servers, %{}),
          timeout: SwarmCode.Domain.Tools.timeout(ctx)
        ]

        {method, params} = build_request(op, abs, args)

        case SwarmCode.Domain.LSP.request(ctx.project_root, abs, method, params, lsp_opts) do
          {:ok, result} ->
            progress.(100, "done")
            {:ok, format_result(op, result, ctx.project_root)}

          {:error, reason} ->
            {:error, to_string(reason)}
        end
      end
    end
  end

  ## ----------------------------------------------------------------- private

  defp build_request(op, abs_path, args) do
    uri = file_uri(abs_path)
    line = (args["line"] || 1) - 1
    character = (args["character"] || 1) - 1
    position = %{"line" => line, "character" => character}
    text_doc = %{"textDocument" => %{"uri" => uri}}

    case op do
      "goToDefinition" ->
        {"textDocument/definition", Map.put(text_doc, "position", position)}

      "findReferences" ->
        params =
          text_doc
          |> Map.put("position", position)
          |> Map.put("context", %{"includeDeclaration" => true})

        {"textDocument/references", params}

      "hover" ->
        {"textDocument/hover", Map.put(text_doc, "position", position)}

      "documentSymbol" ->
        {"textDocument/documentSymbol", text_doc}

      "workspaceSymbol" ->
        {"workspace/symbol", %{"query" => args["query"] || ""}}

      "goToImplementation" ->
        {"textDocument/implementation", Map.put(text_doc, "position", position)}
    end
  end

  defp format_result(_op, nil, _root), do: "no results"
  defp format_result(_op, [], _root), do: "no results"

  defp format_result(op, result, root)
       when op in ~w(goToDefinition findReferences goToImplementation) do
    locations = if is_list(result), do: result, else: [result]

    locations
    |> Enum.take(@max_results)
    |> Enum.map(&format_location(&1, root))
    |> Enum.join("\n")
    |> case do
      "" -> "no results"
      text -> text
    end
  end

  defp format_result("hover", result, _root) do
    content =
      case result do
        %{"contents" => %{"value" => value}} ->
          value

        %{"contents" => contents} when is_binary(contents) ->
          contents

        %{"contents" => contents} when is_list(contents) ->
          Enum.map_join(contents, "\n", fn
            %{"value" => v} -> v
            s when is_binary(s) -> s
            _ -> ""
          end)

        _ ->
          "no results"
      end

    if byte_size(content) > @max_hover do
      binary_part(content, 0, @max_hover) <> "\n… (truncated)"
    else
      content
    end
  end

  defp format_result("documentSymbol", result, _root) when is_list(result) do
    result
    |> List.flatten()
    |> Enum.map(&format_doc_symbol/1)
    |> Enum.join("\n")
    |> case do
      "" -> "no results"
      text -> text
    end
  end

  defp format_result("workspaceSymbol", result, root) when is_list(result) do
    result
    |> Enum.take(@max_results)
    |> Enum.map(&format_ws_symbol(&1, root))
    |> Enum.join("\n")
    |> case do
      "" -> "no results"
      text -> text
    end
  end

  defp format_result(_op, _result, _root), do: "no results"

  defp format_location(%{"uri" => uri, "range" => %{"start" => %{"line" => line}}}, root) do
    path = uri_to_path(uri)
    rel = Path.relative_to(path, root)
    # line is 0-based in LSP.
    display_line = line + 1
    snippet = read_line_snippet(path, line)
    "#{rel}:#{display_line}: #{snippet}"
  end

  defp format_location(
         %{"targetUri" => uri, "targetRange" => %{"start" => %{"line" => line}}},
         root
       ) do
    # LocationLink format.
    format_location(%{"uri" => uri, "range" => %{"start" => %{"line" => line}}}, root)
  end

  defp format_location(_, _root), do: ""

  defp format_doc_symbol(%{"name" => name, "kind" => kind, "range" => range}) do
    line = get_in(range, ["start", "line"]) || 0
    col = get_in(range, ["start", "character"]) || 0
    "#{symbol_kind(kind)} #{name} #{line + 1}:#{col + 1}"
  end

  defp format_doc_symbol(%{"name" => name, "kind" => kind, "selectionRange" => range}) do
    line = get_in(range, ["start", "line"]) || 0
    col = get_in(range, ["start", "character"]) || 0
    "#{symbol_kind(kind)} #{name} #{line + 1}:#{col + 1}"
  end

  defp format_doc_symbol(_), do: ""

  defp format_ws_symbol(
         %{"name" => name, "kind" => kind, "location" => %{"uri" => uri, "range" => range}},
         root
       ) do
    path = uri_to_path(uri)
    rel = Path.relative_to(path, root)
    line = get_in(range, ["start", "line"]) || 0
    "#{rel}:#{line + 1} #{symbol_kind(kind)} #{name}"
  end

  defp format_ws_symbol(_, _root), do: ""

  # spec 73 T21: one encoding pair for the tool and the client.
  defp file_uri(path), do: SwarmCode.Domain.LSP.Language.file_uri(path)
  defp uri_to_path(uri), do: SwarmCode.Domain.LSP.Language.uri_to_path(uri)

  # LSP SymbolKind integer to readable name.
  @symbol_kinds %{
    1 => "File",
    2 => "Module",
    3 => "Namespace",
    4 => "Package",
    5 => "Class",
    6 => "Method",
    7 => "Property",
    8 => "Field",
    9 => "Constructor",
    10 => "Enum",
    11 => "Interface",
    12 => "Function",
    13 => "Variable",
    14 => "Constant",
    15 => "String",
    16 => "Number",
    17 => "Boolean",
    18 => "Array",
    19 => "Object",
    20 => "Key",
    21 => "Null",
    22 => "EnumMember",
    23 => "Struct",
    24 => "Event",
    25 => "Operator",
    26 => "TypeParameter"
  }

  defp symbol_kind(n), do: Map.get(@symbol_kinds, n, "Unknown")

  defp read_line_snippet(path, line_0) do
    case File.open(path, [:read, :utf8]) do
      {:ok, device} ->
        try do
          result =
            Enum.reduce_while(0..line_0, nil, fn i, _acc ->
              case IO.read(device, :line) do
                :eof -> {:halt, nil}
                {:error, _} -> {:halt, nil}
                data when i == line_0 -> {:halt, data}
                _ -> {:cont, nil}
              end
            end)

          case result do
            nil -> ""
            line -> line |> String.trim() |> String.slice(0, @context_chars)
          end
        after
          File.close(device)
        end

      {:error, _} ->
        ""
    end
  end
end
