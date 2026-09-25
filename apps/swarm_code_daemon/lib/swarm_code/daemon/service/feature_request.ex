defmodule SwarmCode.Daemon.Service.FeatureRequest do
  @moduledoc "Scoped wire access to feature queries and mutations on an already admitted Repo."
  alias SwarmCode.Domain.{Conversations, FeatureCatalog, MCP, Memory, Projects}
  alias SwarmCode.Protocol.ServiceRequest

  def execute(request, scope, request_id, revision) do
    case ServiceRequest.encode(request, scope) do
      {:ok, _} -> execute_valid(request, scope, request_id, revision)
      _ -> failure(request, request_id, :invalid_request)
    end
  rescue
    _ -> failure(request, request_id, :source_unavailable)
  catch
    :exit, _ -> failure(request, request_id, :source_unavailable)
  end

  defp execute_valid(%{operation: :feature_query, params: p}, scope, id, revision) do
    case FeatureCatalog.query(p["feature"], scope,
           id: p["id"],
           cursor: p["cursor"],
           limit: p["page_size"],
           byte_limit: p["byte_limit"]
         ) do
      {:ok, page} ->
        items =
          Enum.map(page.items, fn item ->
            %{
              "id" => to_string(item.id),
              "title" => clip(item.title, 256),
              "subtitle" => clip(item.subtitle, 256),
              "status" => clip(item.status, 128),
              "detail" => clip(item.detail, 65_536),
              "actions" => Enum.map(item.actions, &Atom.to_string/1),
              "form" => item[:form]
            }
          end)

        body = %{
          "feature" => p["feature"],
          "title" => clip(page.title, 256),
          "description" => clip(page.description, 2048),
          "items" => items,
          "state" => "idle",
          "before_cursor" => nil,
          "after_cursor" => page.next_cursor,
          "request_id" => id,
          "error" => nil,
          "presence" => "covered",
          "covered_ids" => Enum.map(items, & &1["id"]),
          "through_sequence" => revision
        }

        if byte_size(Jason.encode!(body)) <= p["byte_limit"],
          do: result("library_snapshot", body),
          else: wire_error(:capacity_exceeded)

      _ ->
        wire_error(:source_unavailable)
    end
  end

  defp execute_valid(%{operation: :feature_command, params: p}, scope, id, _revision) do
    with {:ok, ctx} <- context(scope),
         :ok <- authorize(p, scope),
         {:ok, value} <- mutate(p["feature"], p["action"], p["id"], p["attributes"], ctx) do
      ids =
        Enum.flat_map([:run_id, :id], fn key ->
          case value[key] do
            value when is_binary(value) or is_integer(value) -> [to_string(value)]
            _ -> []
          end
        end)
        |> Enum.uniq()

      outcome(id, "accepted", ids, nil)
    else
      {:error, :not_allowed} -> outcome(id, "rejected", [], error(:not_allowed))
      _ -> outcome(id, "rejected", [], error(:invalid_request))
    end
  end

  defp execute_valid(_, _, id, _), do: outcome(id, "rejected", [], error(:invalid_request))

  # Query through the same scope before resolving a mutable row. A raw row id
  # alone never grants access to another project's research, schedule or run.
  defp authorize(%{"feature" => "settings", "action" => "update"}, %{kind: kind})
       when kind in [:global, :project],
       do: :ok

  defp authorize(%{"feature" => "memory", "action" => action}, _scope)
       when action in ["update", "clear"],
       do: :ok

  defp authorize(%{"feature" => f, "action" => a, "id" => nil}, _)
       when {f, a} in [{"research", "start"}, {"schedules", "save"}, {"mcp", "save"}],
       do: :ok

  defp authorize(%{"feature" => f, "id" => id}, scope) do
    case FeatureCatalog.query(f, scope, id: id, limit: 1, byte_limit: 65_536) do
      {:ok, %{items: [item]}} ->
        if to_string(item.id) == id, do: :ok, else: {:error, :not_allowed}

      _ ->
        {:error, :not_allowed}
    end
  end

  defp mutate("settings", "update", _, attrs, _), do: FeatureCatalog.update_settings(attrs)

  defp mutate("memory", "update", id, %{"content" => content} = attrs, ctx)
       when map_size(attrs) == 1 do
    with {:ok, scope, root} <- memory_target(id, ctx),
         true <- is_binary(content) and byte_size(content) <= 16_384 and String.valid?(content),
         :ok <- Memory.write(scope, root, content) do
      {:ok, %{id: id}}
    else
      {:error, :not_allowed} -> {:error, :not_allowed}
      _ -> {:error, :invalid_request}
    end
  end

  defp mutate("memory", "clear", id, ctx_attrs, ctx) when map_size(ctx_attrs) == 0 do
    with {:ok, scope, root} <- memory_target(id, ctx),
         :ok <- Memory.write(scope, root, "") do
      {:ok, %{id: id}}
    else
      _ -> {:error, :not_allowed}
    end
  end

  defp mutate("mcp", "save", id, attrs, ctx) do
    with {:ok, attrs} <- bind_project(attrs, ctx.project_id),
         {:ok, attrs} <- mcp_attrs(attrs),
         {:ok, server} <- mcp_row(id),
         result <- if(server, do: MCP.update(server, attrs), else: MCP.create(attrs)) do
      case result do
        {:ok, updated} -> {:ok, %{id: updated.id}}
        other -> other
      end
    end
  end

  defp mutate("mcp", "toggle", id, attrs, _) when map_size(attrs) == 0 do
    with %{} = server <- MCP.get(id), do: MCP.toggle(server)
  end

  defp mutate("mcp", "delete", id, attrs, _) when map_size(attrs) == 0 do
    with %{} = server <- MCP.get(id), do: MCP.delete(server)
  end

  defp mutate("research", "start", _, attrs, ctx) do
    with {:ok, attrs} <- bind_project(attrs, ctx.project_id),
         do: FeatureCatalog.start_research(attrs)
  end

  defp mutate("research", action, id, attrs, _) when map_size(attrs) == 0,
    do: FeatureCatalog.control_research(id, action_atom(action))

  defp mutate("schedules", "save", id, attrs, ctx) do
    with true <- is_binary(ctx.project_id),
         {:ok, attrs} <- bind_project(attrs, ctx.project_id),
         true <- not Map.has_key?(attrs, "id") or attrs["id"] == id do
      attrs = if id, do: Map.put(attrs, "id", id), else: attrs
      FeatureCatalog.save_schedule(attrs)
    else
      _ -> {:error, :not_allowed}
    end
  end

  defp mutate("schedules", "toggle", id, attrs, _) when map_size(attrs) == 0,
    do: FeatureCatalog.toggle_schedule(id)

  defp mutate("schedules", "run_now", id, attrs, _) when map_size(attrs) == 0,
    do: FeatureCatalog.run_schedule_now(id)

  defp mutate("schedules", "delete", id, attrs, _) when map_size(attrs) == 0,
    do: FeatureCatalog.delete_schedule(id)

  defp mutate("workflows", "start", id, attrs, %{conversation_id: c}) when is_binary(c) do
    if Enum.all?(Map.keys(attrs), &(&1 in ~w(args budget max_live model))),
      do:
        FeatureCatalog.start_workflow(Map.merge(attrs, %{"conversation_id" => c, "name" => id})),
      else: {:error, :invalid_request}
  end

  defp mutate("workflows", action, id, attrs, _) when map_size(attrs) == 0,
    do: FeatureCatalog.control_workflow(id, action_atom(action))

  defp mutate("checkpoints", "restore", id, attrs, %{conversation_id: c})
       when is_binary(c) and map_size(attrs) == 0,
       do: FeatureCatalog.restore_checkpoint(c, id)

  defp mutate(_, _, _, _, _), do: {:error, :invalid_request}

  defp mcp_row(nil), do: {:ok, nil}
  defp mcp_row(id), do: {:ok, MCP.get(id)}

  defp mcp_attrs(attrs) do
    allowed = Map.take(attrs, ~w(name transport command args url enabled project_id))

    {:ok,
     Map.update(allowed, "args", [], &if(is_binary(&1), do: MCP.Server.parse_args(&1), else: &1))}
  end

  defp bind_project(attrs, project_id) do
    if Map.has_key?(attrs, "project_id") and attrs["project_id"] != project_id,
      do: {:error, :not_allowed},
      else: {:ok, Map.put(attrs, "project_id", project_id)}
  end

  defp memory_target("global", _ctx), do: {:ok, :global, nil}

  defp memory_target(id, %{project_id: project_id})
       when is_binary(id) and is_binary(project_id) and id == project_id do
    case Projects.get(project_id) do
      %{root_path: root} -> {:ok, :project, root}
      _ -> {:error, :not_allowed}
    end
  end

  defp memory_target(_, _), do: {:error, :not_allowed}

  defp context(%{kind: :global}), do: {:ok, %{project_id: nil, conversation_id: nil}}

  defp context(%{kind: :project, id: id}) do
    if Projects.get(id),
      do: {:ok, %{project_id: id, conversation_id: nil}},
      else: {:error, :not_allowed}
  end

  defp context(%{kind: :conversation, id: id}) do
    case Conversations.get(id) do
      %{project_id: project} -> {:ok, %{project_id: project, conversation_id: id}}
      _ -> {:error, :not_allowed}
    end
  end

  defp context(_), do: {:error, :not_allowed}

  defp action_atom("pause"), do: :pause
  defp action_atom("resume"), do: :resume
  defp action_atom("stop"), do: :stop
  defp action_atom("retry"), do: :retry
  defp action_atom("report"), do: :report
  defp action_atom("pin"), do: :pin
  defp action_atom(_), do: :invalid
  defp clip(nil, _), do: ""
  defp clip(text, bytes), do: utf8(binary_part(text, 0, min(byte_size(text), bytes)))

  defp utf8(text),
    do: if(String.valid?(text), do: text, else: utf8(binary_part(text, 0, byte_size(text) - 1)))

  defp failure(%{operation: :feature_command}, id, code),
    do: outcome(id, "rejected", [], error(code))

  defp failure(_, _, code), do: wire_error(code)
  defp error(code), do: %{"code" => Atom.to_string(code), "message" => message(code)}

  # pass74 S1-11 (R1): the client decodes an error only with the canonical
  # message of its code (`AdmissionError.new/1`); a test keeps both tables equal.
  @canonical_messages %{
    not_allowed: "request is not allowed",
    invalid_request: "invalid data source request",
    capacity_exceeded: "data source admission capacity exceeded",
    source_unavailable: "data source is unavailable"
  }

  @doc "The canonical error message of each code this module answers (R1)."
  @spec canonical_messages() :: %{atom() => String.t()}
  def canonical_messages, do: @canonical_messages

  defp message(code), do: Map.fetch!(@canonical_messages, code)
  defp wire_error(code), do: {:error, Map.put(error(code), "op", "error")}

  defp result(kind, body),
    do: {:ok, %{"op" => "result", "response_kind" => kind, "value" => body}}

  defp outcome(id, status, ids, error),
    do:
      result("outcome", %{
        "status" => status,
        "request_id" => id,
        "identifiers" => ids,
        "interaction" => nil,
        "error" => error,
        "corrective_action" => "none"
      })
end
