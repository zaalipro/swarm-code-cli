defmodule SwarmCodeCLI.UI.DataSource.Daemon.Codec do
  @moduledoc "Pure translation between typed client requests and the closed daemon wire protocol."
  alias SwarmCode.Protocol.{Frame, Message, ServiceRequest}
  alias SwarmCodeCLI.UI.DataSource.{AdmissionError, Delivery, DTO, Request}

  @responses %{
    "outcome" => {:outcome, DTO.Outcome},
    "shell_snapshot" => {:shell_snapshot, DTO.ShellSnapshot},
    "workspace_snapshot" => {:workspace_snapshot, DTO.WorkspaceSnapshot},
    "transcript_window" => {:transcript_window, DTO.TranscriptWindow},
    "activity_snapshot" => {:activity_snapshot, DTO.ActivitySnapshot},
    "run_detail_snapshot" => {:run_detail_snapshot, DTO.RunDetailSnapshot},
    "pending_interactions" => {:pending_interactions, DTO.PendingInteractionWindow},
    "detail_window" => {:detail_window, DTO.DetailWindow}
  }

  def request(request, wire_id, nonce, now) do
    with {:ok, request} <- Request.validate(request),
         true <- is_integer(now),
         :ok <- not_expired(request.deadline, now),
         {:ok, body} <- request_body(request.kind),
         body = Map.put(body, "timeout_ms", min(request.deadline - now, 600_000)),
         {:ok, _} <- ServiceRequest.decode(body, request.scope),
         message = %Message{
           version: 1,
           type: :request,
           request_id: wire_id,
           nonce: nonce,
           scope: request.scope,
           sequence: nil,
           occurred_at: nil,
           body: body
         },
         {:ok, _} <- Frame.encode(message) do
      {:ok, message}
    else
      {:error, %AdmissionError{}} = error -> error
      _ -> invalid()
    end
  end

  def response(message, request, wire_id, nonce) do
    with {:ok, request} <- Request.validate(request),
         {:ok, _} <- Frame.encode(message),
         true <- message.request_id == wire_id and message.nonce == nonce,
         true <- message.scope == request.scope do
      response_body(message, request)
    else
      _ -> invalid()
    end
  end

  defp request_body({:query, slot, cursor, direction, size, bytes}) do
    {:ok,
     %{
       "op" => "query",
       "slot" => Atom.to_string(slot),
       "cursor" => cursor,
       "direction" => Atom.to_string(direction),
       "page_size" => size,
       "byte_limit" => bytes
     }}
  end

  defp request_body({:query_detail, ref, offset, bytes}),
    do: {:ok, %{"op" => "detail", "detail_ref" => ref, "offset" => offset, "bytes" => bytes}}

  defp request_body({:resync_watch, ref}), do: {:ok, %{"op" => "resync", "watch_ref" => ref}}

  defp request_body({:dispatch, :send, text, :main, []}),
    do:
      {:ok,
       %{
         "op" => "dispatch",
         "action" => "send",
         "text" => text,
         "target" => %{"kind" => "main", "id" => nil},
         "attachment_refs" => []
       }}

  defp request_body({:run_control, action, run}) when action in [:pause, :continue, :stop],
    do: {:ok, %{"op" => "run.control", "action" => Atom.to_string(action), "run_id" => run}}

  defp request_body({:steer, run, node, text, []}),
    do:
      {:ok,
       %{
         "op" => "run.steer",
         "run_id" => run,
         "node_id" => node,
         "text" => text,
         "attachment_refs" => []
       }}

  defp request_body({:resolve_approval, run, node, interaction, revision, decision})
       when decision in [:approve, :deny],
       do:
         {:ok,
          %{
            "op" => "approval.resolve",
            "run_id" => run,
            "node_id" => node,
            "interaction_id" => interaction,
            "expected_revision" => revision,
            "decision" => Atom.to_string(decision)
          }}

  defp request_body(_), do: {:error, AdmissionError.new(:not_allowed)}

  defp response_body(%Message{type: :error, body: %{"op" => "error"} = body}, _request)
       when map_size(body) == 3 do
    case AdmissionError.decode(Map.delete(body, "op")) do
      {:ok, error} -> {:error, error}
      _ -> invalid()
    end
  end

  defp response_body(
         %Message{
           type: :response,
           body: %{"op" => "result", "response_kind" => kind, "value" => value} = body
         } = message,
         request
       )
       when map_size(body) == 3 do
    with {expected, module} <- Map.get(@responses, kind),
         true <- expected == request.expected_response,
         {:ok, dto} <- module.decode(value),
         true <- exact_wire_shape?(dto, value),
         :ok <- body_identity(dto, message.request_id),
         true <- scoped_body?(request.scope, dto),
         true <- response_matches?(request, dto),
         {:ok, dto} <- restore_identities(dto, message.request_id, request.request_id),
         delivery = %Delivery{
           kind: :response,
           request_id: request.request_id,
           watch_ref: nil,
           scope: request.scope,
           generation: request.generation,
           revision: nil,
           sequence: nil,
           body: dto
         },
         {:ok, delivery} <- Delivery.validate(delivery) do
      {:ok, delivery}
    else
      _ -> invalid()
    end
  end

  defp response_body(_, _), do: invalid()
  defp body_identity(%{request_id: id}, id), do: :ok
  defp body_identity(%{request_id: _}, _), do: :error
  defp body_identity(_, _), do: :ok
  # Fixture DTO decoders retain legacy defaults. The v1 service wire requires
  # every field explicitly, including nested nullable fields.
  defp exact_wire_shape?(%{__struct__: _} = dto, wire) when is_map(wire) do
    fields = Map.from_struct(dto)

    map_size(fields) == map_size(wire) and
      Enum.all?(fields, fn {key, value} ->
        case Map.fetch(wire, Atom.to_string(key)) do
          {:ok, raw} -> exact_wire_shape?(value, raw)
          :error -> false
        end
      end)
  end

  defp exact_wire_shape?(values, wires) when is_list(values) and is_list(wires),
    do:
      length(values) == length(wires) and
        Enum.all?(Enum.zip(values, wires), fn {a, b} -> exact_wire_shape?(a, b) end)

  defp exact_wire_shape?(_, _), do: true

  defp restore_identities(%{__struct__: _} = dto, wire, local) do
    Enum.reduce_while(Map.from_struct(dto), {:ok, dto}, fn {key, value}, {:ok, acc} ->
      result =
        if key == :request_id do
          cond do
            value == nil -> {:ok, nil}
            value == wire -> {:ok, local}
            true -> :error
          end
        else
          restore_identities(value, wire, local)
        end

      case result do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        _ -> {:halt, :error}
      end
    end)
  end

  defp restore_identities(values, wire, local) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case restore_identities(value, wire, local) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      _ -> :error
    end
  end

  defp restore_identities(value, _, _), do: {:ok, value}

  defp scoped_body?(scope, %DTO.WorkspaceSnapshot{} = page) do
    page.conversation_id == if(scope.kind == :conversation, do: scope.id, else: nil) and
      Enum.all?(page.runs ++ page.interactions ++ page.transcript.items, &scoped_item?(scope, &1))
  end

  defp scoped_body?(scope, %DTO.ShellSnapshot{} = page),
    do: Enum.all?(page.runs, &scoped_item?(scope, &1))

  defp scoped_body?(scope, %DTO.RunDetailSnapshot{} = page),
    do:
      (is_nil(page.run) or scoped_item?(scope, page.run)) and
        Enum.all?(page.agents ++ page.transcript.items, &scoped_item?(scope, &1))

  defp scoped_body?(scope, %{items: items}), do: Enum.all?(items, &scoped_item?(scope, &1))
  defp scoped_body?(_, _), do: true
  defp scoped_item?(%{kind: :global}, _), do: true

  defp scoped_item?(%{kind: :conversation, id: id}, item),
    do: Map.get(item, :conversation_id) == id

  defp scoped_item?(%{kind: :run, id: id}, item), do: Map.get(item, :run_id, item.id) == id
  defp scoped_item?(_, _), do: false

  defp response_matches?(%Request{kind: {:query_detail, id, offset, bytes}}, body),
    do:
      body.offset == offset and byte_size(body.text) <= bytes and
        (body.state == :error or body.detail_ref.id == id)

  defp response_matches?(_, _), do: true
  defp not_expired(deadline, now) when deadline > now, do: :ok
  defp not_expired(_, _), do: {:error, AdmissionError.new(:deadline_expired)}
  defp invalid, do: {:error, AdmissionError.new(:invalid_request)}
end
